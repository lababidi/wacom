/*
 * WacomTabletDriver.cpp
 *
 * DriverKit HID event service for Wacom Intuos S/M 2nd generation tablets.
 * Decodes the proprietary INTUOSHT2 protocol and dispatches standard
 * macOS digitizer stylus events.
 *
 * Protocol reverse-engineered from Linux kernel drivers/hid/wacom_wac.c
 * (wacom_intuos_general / wacom_bpt_irq for INTUOSHT2 device type).
 *
 * Supported devices (all share the same report protocol):
 *   CTL-490  (0x033B) — Intuos S 2,    15200 x  9500
 *   CTH-490  (0x033C) — Intuos PT S 2, 15200 x  9500, touch
 *   CTL-690  (0x033D) — Intuos M 2,    21600 x 13500
 *   CTH-690  (0x033E) — Intuos PT M 2, 21600 x 13500, touch
 */

#include <DriverKit/IOLib.h>
#include <DriverKit/IOService.h>
#include <DriverKit/OSDictionary.h>
#include <DriverKit/OSBoolean.h>
#include <DriverKit/OSNumber.h>
#include <HIDDriverKit/HIDDriverKit.h>

#include "WacomTabletDriver.h"

// ── Report constants ────────────────────────────────────────────────
static constexpr uint32_t kReportID_Pen       = 0x10;
static constexpr uint32_t kMinReportLength    = 10;

// ── Tablet parameters per model ─────────────────────────────────────
// From Linux kernel wacom_wac.c wacom_features_0x33B..0x33E
struct WacomModel {
    uint32_t productID;
    uint32_t xMax;
    uint32_t yMax;
    uint32_t pressureMax;
    uint32_t distanceMax;
};

static constexpr WacomModel kModels[] = {
    { 0x033B, 15200,  9500, 2047, 63 },  // CTL-490
    { 0x033C, 15200,  9500, 2047, 63 },  // CTH-490
    { 0x033D, 21600, 13500, 2047, 63 },  // CTL-690
    { 0x033E, 21600, 13500, 2047, 63 },  // CTH-690
};

static constexpr uint32_t kPressureThreshold = 10;

// ── Logging (DriverKit only provides IOLog, not os_log_info etc.) ───
#define LOG_INFO(fmt, ...)  IOLog("WacomTabletDriver: " fmt "\n", ##__VA_ARGS__)
#define LOG_ERROR(fmt, ...) IOLog("WacomTabletDriver: ERROR " fmt "\n", ##__VA_ARGS__)
#define LOG_DEBUG(fmt, ...) IOLog("WacomTabletDriver: " fmt "\n", ##__VA_ARGS__)

// ── Helper: float to IOFixed (16.16 fixed-point) ────────────────────
static inline IOFixed floatToFixed(float v)
{
    return static_cast<IOFixed>(v * 65536.0f);
}

// ── Per-instance state ──────────────────────────────────────────────
struct WacomTabletDriver_IVars {
    uint32_t xMax;
    uint32_t yMax;
    uint32_t pressureMax;
    uint32_t distanceMax;

    // Previous state for *Changed flags
    bool     lastInRange;
    bool     lastTip;
    uint32_t lastX;
    uint32_t lastY;
};

// ── Lifecycle ───────────────────────────────────────────────────────

bool WacomTabletDriver::init()
{
    if (!super::init()) {
        return false;
    }

    ivars = IONewZero(WacomTabletDriver_IVars, 1);
    if (!ivars) {
        return false;
    }

    // Default to CTL-490 dimensions; will be refined in handleStart
    ivars->xMax        = 15200;
    ivars->yMax        = 9500;
    ivars->pressureMax = 2047;
    ivars->distanceMax = 63;
    ivars->lastInRange = false;
    ivars->lastTip     = false;
    ivars->lastX       = 0;
    ivars->lastY       = 0;

    return true;
}

void WacomTabletDriver::free()
{
    IOSafeDeleteNULL(ivars, WacomTabletDriver_IVars, 1);
    super::free();
}

kern_return_t IMPL(WacomTabletDriver, Start)
{
    LOG_INFO("Start called");

    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        LOG_ERROR("super::Start failed: 0x%x", ret);
        return ret;
    }

    LOG_INFO("Driver started successfully");
    return kIOReturnSuccess;
}

kern_return_t IMPL(WacomTabletDriver, Stop)
{
    LOG_INFO("Stop called");
    return Stop(provider, SUPERDISPATCH);
}

// ── handleStart: configure for raw report access ────────────────────

bool WacomTabletDriver::handleStart(IOService * provider)
{
    LOG_INFO("handleStart");

    if (!super::handleStart(provider)) {
        LOG_ERROR("super::handleStart failed");
        return false;
    }

    // Request raw report delivery (before element processing)
    OSDictionary * props = OSDictionary::withCapacity(1);
    if (props) {
        props->setObject("IOHIDEventDriverHandlesReport", kOSBooleanTrue);
        SetProperties(props);
        props->release();
    }

    // Try to determine the specific model from the provider's ProductID
    // This lets us use the correct X/Y max for medium-sized tablets
    OSDictionary * providerProps = nullptr;
    if (provider->CopyProperties(&providerProps) == kIOReturnSuccess && providerProps) {
        OSNumber * pidNum = OSDynamicCast(OSNumber,
            providerProps->getObject("ProductID"));
        if (pidNum) {
            uint32_t pid = pidNum->unsigned32BitValue();
            for (const auto & model : kModels) {
                if (model.productID == pid) {
                    ivars->xMax        = model.xMax;
                    ivars->yMax        = model.yMax;
                    ivars->pressureMax = model.pressureMax;
                    ivars->distanceMax = model.distanceMax;
                    LOG_INFO("Matched model PID 0x%x: %u x %u, pressure %u",
                             pid, model.xMax, model.yMax, model.pressureMax);
                    break;
                }
            }
        }
        providerProps->release();
    }

    LOG_INFO("handleStart complete — ready for reports");
    return true;
}

// ── handleReport: decode INTUOSHT2 protocol and dispatch ────────────

void WacomTabletDriver::handleReport(uint64_t      timestamp,
                                     uint8_t     * report,
                                     uint32_t      reportLength,
                                     IOHIDReportType type,
                                     uint32_t      reportID)
{
    // Only process pen input reports with the correct ID and length
    if (type != kIOHIDReportTypeInput ||
        reportID != kReportID_Pen ||
        reportLength < kMinReportLength)
    {
        return;
    }

    // ── Decode status byte ──────────────────────────────────────
    uint8_t status = report[1];

    bool inRange = (status & 0x80) != 0;
    bool near    = (status & 0x40) != 0;
    bool rdy     = (status & 0x20) != 0;
    bool eraser  = (status & 0x08) != 0;
    bool btn2    = (status & 0x04) != 0;   // Side button 2
    bool btn1    = (status & 0x02) != 0;   // Side button 1

    // ── Decode coordinates (17-bit each) ────────────────────────
    //   X = (be16(data[2:3]) << 1) | ((data[9] >> 1) & 1)
    //   Y = (be16(data[4:5]) << 1) | (data[9] & 1)
    uint32_t rawX = 0, rawY = 0;
    if (near || inRange) {
        uint16_t xHigh = (static_cast<uint16_t>(report[2]) << 8) | report[3];
        uint16_t yHigh = (static_cast<uint16_t>(report[4]) << 8) | report[5];
        rawX = (static_cast<uint32_t>(xHigh) << 1) | ((report[9] >> 1) & 1);
        rawY = (static_cast<uint32_t>(yHigh) << 1) | (report[9] & 1);
    }

    // ── Decode pressure (11-bit) ────────────────────────────────
    //   P = (data[6] << 3) | ((data[7] & 0xC0) >> 5) | (data[1] & 1)
    uint32_t rawPressure = 0;
    if (rdy) {
        rawPressure = (static_cast<uint32_t>(report[6]) << 3)
                    | ((report[7] & 0xC0) >> 5)
                    | (status & 0x01);
    }

    bool tip = rawPressure > kPressureThreshold;

    // ── Normalize to 0.0–1.0 range (IOFixed 16.16) ─────────────
    float normX = (ivars->xMax > 0)
        ? static_cast<float>(rawX) / static_cast<float>(ivars->xMax)
        : 0.0f;
    float normY = (ivars->yMax > 0)
        ? static_cast<float>(rawY) / static_cast<float>(ivars->yMax)
        : 0.0f;
    float normP = (ivars->pressureMax > 0)
        ? static_cast<float>(rawPressure) / static_cast<float>(ivars->pressureMax)
        : 0.0f;

    // Clamp
    if (normX > 1.0f) normX = 1.0f;
    if (normY > 1.0f) normY = 1.0f;
    if (normP > 1.0f) normP = 1.0f;

    // ── Build stylus event ──────────────────────────────────────
    IOHIDDigitizerStylusData stylusData = {};

    stylusData.identifier    = 1;
    stylusData.x             = floatToFixed(normX);
    stylusData.y             = floatToFixed(normY);
    stylusData.tipPressure   = floatToFixed(normP);
    stylusData.barrelPressure = 0;
    stylusData.tiltX         = 0;   // CTL-490 has no tilt
    stylusData.tiltY         = 0;
    stylusData.twist         = 0;
    stylusData.pointerType   = eraser ? 3 : 1;  // 1=pen, 3=eraser
    stylusData.effect        = 0;
    stylusData.uniqueID      = 0;

    // Flags
    stylusData.inRange       = inRange ? 1 : 0;
    stylusData.tip           = tip ? 1 : 0;
    stylusData.barrelSwitch  = btn1 ? 1 : 0;
    stylusData.invert        = eraser ? 1 : 0;
    stylusData.eraser        = (eraser && tip) ? 1 : 0;

    // Changed flags (compare to previous state)
    stylusData.rangeChanged    = (inRange != ivars->lastInRange) ? 1 : 0;
    stylusData.tipChanged      = (tip != ivars->lastTip) ? 1 : 0;
    stylusData.positionChanged = (rawX != ivars->lastX || rawY != ivars->lastY) ? 1 : 0;

    // Save state for next report
    ivars->lastInRange = inRange;
    ivars->lastTip     = tip;
    ivars->lastX       = rawX;
    ivars->lastY       = rawY;

    // ── Dispatch ────────────────────────────────────────────────
    kern_return_t ret = dispatchDigitizerStylusEvent(timestamp, &stylusData);
    if (ret != kIOReturnSuccess) {
        LOG_DEBUG("dispatchDigitizerStylusEvent returned 0x%x", ret);
    }
}
