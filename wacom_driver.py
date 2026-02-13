#!/usr/bin/env python3
"""
Wacom CTL-490 (Intuos S 2) userspace driver for macOS.

Reads HID reports from the tablet and generates macOS tablet events
with pressure sensitivity, compatible with Krita and other drawing apps.

Protocol reverse-engineered from the Linux kernel wacom driver (wacom_wac.c)
for INTUOSHT2 devices.
"""

import hid
import time
import signal
import sys
import os
from Quartz import (
    CGEventCreateMouseEvent,
    CGEventPost,
    CGEventSetIntegerValueField,
    CGEventSetDoubleValueField,
    CGEventSetType,
    CGEventCreate,
    CGMainDisplayID,
    CGDisplayPixelsWide,
    CGDisplayPixelsHigh,
    kCGEventMouseMoved,
    kCGEventLeftMouseDown,
    kCGEventLeftMouseUp,
    kCGEventLeftMouseDragged,
    kCGEventRightMouseDown,
    kCGEventRightMouseUp,
    kCGEventRightMouseDragged,
    kCGEventOtherMouseDown,
    kCGEventOtherMouseUp,
    kCGEventOtherMouseDragged,
    kCGEventTabletPointer,
    kCGHIDEventTap,
    kCGMouseButtonLeft,
    kCGMouseButtonRight,
    kCGMouseButtonCenter,
    kCGMouseEventSubtype,
    kCGTabletEventPointX,
    kCGTabletEventPointY,
    kCGTabletEventPointZ,
    kCGTabletEventPointPressure,
    kCGTabletEventPointButtons,
    kCGTabletEventDeviceID,
    kCGEventTabletProximity,
    kCGTabletProximityEventVendorID,
    kCGTabletProximityEventTabletID,
    kCGTabletProximityEventPointerID,
    kCGTabletProximityEventDeviceID,
    kCGTabletProximityEventSystemTabletID,
    kCGTabletProximityEventVendorPointerType,
    kCGTabletProximityEventVendorPointerSerialNumber,
    kCGTabletProximityEventVendorUniqueID,
    kCGTabletProximityEventCapabilityMask,
    kCGTabletProximityEventPointerType,
    kCGTabletProximityEventEnterProximity,
)

# ── Device constants ──────────────────────────────────────────────
VENDOR_ID  = 0x056A
PRODUCT_ID = 0x033B
USAGE_PAGE = 0xFF0D  # Wacom proprietary digitizer

# ── Tablet specs (from Linux kernel wacom_wac.c) ─────────────────
X_MAX = 15200
Y_MAX = 9500
PRESSURE_MAX = 2047
DISTANCE_MAX = 63
PRESSURE_THRESHOLD = 10  # Linux driver uses >10 as "touching"

# ── Report constants ──────────────────────────────────────────────
REPORT_PENABLED = 0x10  # WACOM_REPORT_INTUOS_PEN for this device

# ── CGEvent subtypes ─────────────────────────────────────────────
kCGEventMouseSubtypeDefault = 0
kCGEventMouseSubtypeTabletPoint = 1
kCGEventMouseSubtypeTabletProximity = 2


class PenState:
    """Current state of the pen."""
    __slots__ = ('x', 'y', 'pressure', 'distance', 'in_range', 'near',
                 'touching', 'btn1', 'btn2', 'eraser', 'screen_x', 'screen_y')

    def __init__(self):
        self.x = 0
        self.y = 0
        self.pressure = 0
        self.distance = DISTANCE_MAX
        self.in_range = False
        self.near = False
        self.touching = False
        self.btn1 = False
        self.btn2 = False
        self.eraser = False
        self.screen_x = 0.0
        self.screen_y = 0.0


def find_wacom_device():
    """Find and return the HID path for the Wacom digitizer interface."""
    for dev in hid.enumerate(VENDOR_ID, PRODUCT_ID):
        if dev['usage_page'] == USAGE_PAGE:
            return dev['path']
    return None


def decode_report(data):
    """
    Decode a 10-byte INTUOSHT2 pen report.

    Protocol (from Linux kernel drivers/hid/wacom_wac.c, wacom_intuos_general):
      data[0]:    Report ID (0x10)
      data[1]:    Status/flags
                    bit 7: in range
                    bit 6: near surface
                    bit 5: ready (data valid)
                    bit 3: eraser tool
                    bit 2: side button 2
                    bit 1: side button 1
                    bit 0: pressure LSB
      data[2:3]:  X high bits (big-endian)
      data[4:5]:  Y high bits (big-endian)
      data[6]:    Pressure high byte
      data[7]:    Pressure bits [7:6] used, rest is tilt (not on this model)
      data[8]:    Unused on INTUOSHT2
      data[9]:    bit 1: X LSB, bit 0: Y LSB, bits [7:2]: distance
    """
    if len(data) < 10 or data[0] != REPORT_PENABLED:
        return None

    state = PenState()

    status = data[1]
    state.in_range = bool(status & 0x80)
    state.near = bool(status & 0x40)
    rdy = bool(status & 0x20)
    state.eraser = bool(status & 0x08)
    state.btn2 = bool(status & 0x04)
    state.btn1 = bool(status & 0x02)

    if state.near or state.in_range:
        # X = (big-endian(data[2:3]) << 1) | ((data[9] >> 1) & 1)
        x_high = (data[2] << 8) | data[3]
        state.x = (x_high << 1) | ((data[9] >> 1) & 1)

        # Y = (big-endian(data[4:5]) << 1) | (data[9] & 1)
        y_high = (data[4] << 8) | data[5]
        state.y = (y_high << 1) | (data[9] & 1)

    if rdy:
        # Pressure = (data[6] << 3) | ((data[7] & 0xC0) >> 5) | (data[1] & 1)
        state.pressure = (data[6] << 3) | ((data[7] & 0xC0) >> 5) | (status & 1)

    # Distance: for INTUOSHT2, distance = max - raw
    if state.in_range:
        raw_distance = data[9] >> 2
        state.distance = max(0, DISTANCE_MAX - raw_distance)
    else:
        state.distance = DISTANCE_MAX

    state.touching = state.pressure > PRESSURE_THRESHOLD

    return state


class WacomDriver:
    """Userspace driver for Wacom CTL-490."""

    def __init__(self, screen_margin=0):
        self.device = None
        self.running = False
        self.prev_state = PenState()
        self.was_touching = False
        self.was_btn1 = False
        self.was_btn2 = False
        self.was_in_range = False

        # Screen dimensions
        display_id = CGMainDisplayID()
        self.screen_w = CGDisplayPixelsWide(display_id)
        self.screen_h = CGDisplayPixelsHigh(display_id)
        self.margin = screen_margin

        print(f"Screen: {self.screen_w}x{self.screen_h}")

    def map_to_screen(self, state):
        """Map tablet coordinates to screen coordinates."""
        # Normalize to 0.0-1.0
        nx = max(0.0, min(1.0, state.x / X_MAX))
        ny = max(0.0, min(1.0, state.y / Y_MAX))

        # Map to screen with optional margin
        m = self.margin
        state.screen_x = m + nx * (self.screen_w - 2 * m)
        state.screen_y = m + ny * (self.screen_h - 2 * m)

    def post_tablet_event(self, event_type, state, button=kCGMouseButtonLeft):
        """Create and post a CGEvent with tablet pressure data."""
        point = (state.screen_x, state.screen_y)
        event = CGEventCreateMouseEvent(None, event_type, point, button)

        if event is None:
            return

        # Mark this as a tablet point event
        CGEventSetIntegerValueField(event, kCGMouseEventSubtype,
                                    kCGEventMouseSubtypeTabletPoint)

        # Set pressure as float 0.0 - 1.0
        pressure_norm = min(1.0, state.pressure / PRESSURE_MAX)
        CGEventSetDoubleValueField(event, kCGTabletEventPointPressure,
                                   pressure_norm)

        # Set tablet coordinates
        CGEventSetIntegerValueField(event, kCGTabletEventPointX, state.x)
        CGEventSetIntegerValueField(event, kCGTabletEventPointY, state.y)

        # Set button mask
        btn_mask = 0
        if state.touching:
            btn_mask |= 1
        if state.btn1:
            btn_mask |= 2
        if state.btn2:
            btn_mask |= 4
        CGEventSetIntegerValueField(event, kCGTabletEventPointButtons, btn_mask)

        # Device ID
        CGEventSetIntegerValueField(event, kCGTabletEventDeviceID, 1)

        CGEventPost(kCGHIDEventTap, event)

    def post_proximity_event(self, entering):
        """Post a tablet proximity event (pen entering/leaving range)."""
        event = CGEventCreate(None)
        if event is None:
            return

        CGEventSetType(event, kCGEventTabletProximity)

        # Vendor/device identification
        CGEventSetIntegerValueField(event, kCGTabletProximityEventVendorID, VENDOR_ID)
        CGEventSetIntegerValueField(event, kCGTabletProximityEventTabletID, 1)
        CGEventSetIntegerValueField(event, kCGTabletProximityEventPointerID, 1)
        CGEventSetIntegerValueField(event, kCGTabletProximityEventDeviceID, 1)
        CGEventSetIntegerValueField(event, kCGTabletProximityEventSystemTabletID, 1)
        CGEventSetIntegerValueField(event, kCGTabletProximityEventVendorPointerType, 1)
        CGEventSetIntegerValueField(event, kCGTabletProximityEventVendorPointerSerialNumber, 1)
        CGEventSetIntegerValueField(event, kCGTabletProximityEventVendorUniqueID, PRODUCT_ID)

        # Capabilities: pressure, tilt X, tilt Y
        CGEventSetIntegerValueField(event, kCGTabletProximityEventCapabilityMask, 0x0001)

        # Pointer type: 1 = pen, 3 = eraser
        CGEventSetIntegerValueField(event, kCGTabletProximityEventPointerType, 1)

        # Enter/leave
        CGEventSetIntegerValueField(event, kCGTabletProximityEventEnterProximity,
                                    1 if entering else 0)

        CGEventPost(kCGHIDEventTap, event)

    def handle_report(self, state):
        """Process a decoded pen state and generate appropriate events."""
        if not state.in_range and not state.near:
            # Pen left proximity
            if self.was_touching:
                self.post_tablet_event(kCGEventLeftMouseUp, self.prev_state)
                self.was_touching = False
            if self.was_btn1:
                self.post_tablet_event(kCGEventRightMouseUp, self.prev_state,
                                       kCGMouseButtonRight)
                self.was_btn1 = False
            if self.was_in_range:
                self.post_proximity_event(False)
            self.was_in_range = False
            return

        # Pen entered proximity
        if not self.was_in_range:
            self.post_proximity_event(True)

        self.map_to_screen(state)
        self.was_in_range = True

        # ── Button 1 (side button → right click) ────────────
        if state.btn1 and not self.was_btn1:
            self.post_tablet_event(kCGEventRightMouseDown, state,
                                   kCGMouseButtonRight)
            self.was_btn1 = True
        elif not state.btn1 and self.was_btn1:
            self.post_tablet_event(kCGEventRightMouseUp, state,
                                   kCGMouseButtonRight)
            self.was_btn1 = False

        # ── Pen tip (touch → left click + drag) ─────────────
        if state.touching and not self.was_touching:
            # Pen down
            self.post_tablet_event(kCGEventLeftMouseDown, state)
            self.was_touching = True
        elif not state.touching and self.was_touching:
            # Pen up
            self.post_tablet_event(kCGEventLeftMouseUp, state)
            self.was_touching = False
        elif state.touching:
            # Dragging with pressure
            self.post_tablet_event(kCGEventLeftMouseDragged, state)
        else:
            # Hovering (moving without touching)
            self.post_tablet_event(kCGEventMouseMoved, state)

        self.prev_state = state

    def connect(self):
        """Connect to the Wacom device."""
        path = find_wacom_device()
        if path is None:
            print("ERROR: Wacom CTL-490 not found!")
            print("Make sure the tablet is plugged in via USB.")
            return False

        self.device = hid.device()
        self.device.open_path(path)
        self.device.set_nonblocking(False)

        product = self.device.get_product_string()
        mfg = self.device.get_manufacturer_string()
        print(f"Connected: {mfg} {product}")

        # Switch to tablet mode (Feature Report 0x02)
        try:
            self.device.send_feature_report([0x02, 0x02])
        except Exception:
            pass  # Some devices don't need this

        # Read back device info from feature reports
        try:
            feat = self.device.get_feature_report(0x08, 10)
            if feat and len(feat) >= 9:
                serial = ''.join(f'{b:02x}' for b in feat[1:7])
                print(f"Device serial: {serial}")
        except Exception:
            pass

        return True

    def run(self):
        """Main driver loop."""
        self.running = True
        print()
        print("Driver active! Use your pen on the tablet.")
        print("  - Pen tip → Left click + pressure")
        print("  - Side button 1 → Right click")
        print("  - Side button 2 → Middle click")
        print("  - Pressure → Sent to drawing apps (Krita, etc.)")
        print()
        print("Press Ctrl+C to stop.")
        print()

        report_count = 0
        last_status_print = time.time()

        while self.running:
            try:
                data = self.device.read(64, 100)  # 100ms timeout
                if not data:
                    continue

                state = decode_report(data)
                if state is None:
                    continue

                self.handle_report(state)
                report_count += 1

                # Periodic status
                now = time.time()
                if now - last_status_print > 2.0 and state.in_range:
                    p_pct = (state.pressure / PRESSURE_MAX) * 100
                    print(f"\r  X={state.x:5d}/{X_MAX}  "
                          f"Y={state.y:5d}/{Y_MAX}  "
                          f"P={state.pressure:4d}/{PRESSURE_MAX} ({p_pct:5.1f}%)  "
                          f"D={state.distance:2d}  "
                          f"{'TOUCH' if state.touching else 'hover':5s}  "
                          f"{'B1' if state.btn1 else '  '} "
                          f"{'B2' if state.btn2 else '  '} "
                          f"{'ERASER' if state.eraser else '      '}",
                          end='', flush=True)
                    last_status_print = now

            except KeyboardInterrupt:
                break
            except Exception as e:
                print(f"\nError: {e}")
                time.sleep(0.1)

        print(f"\n\nStopped. Total reports processed: {report_count}")

    def stop(self):
        """Stop the driver."""
        self.running = False

    def disconnect(self):
        """Disconnect from the device."""
        if self.device:
            try:
                self.device.close()
            except Exception:
                pass
            self.device = None


def check_accessibility():
    """Check if we have Accessibility permissions for CGEvent posting."""
    from ApplicationServices import AXIsProcessTrusted
    if not AXIsProcessTrusted():
        print("WARNING: Accessibility permission not granted!")
        print("The driver needs Accessibility access to move the cursor.")
        print()
        print("To grant access:")
        print("  1. Open System Settings → Privacy & Security → Accessibility")
        print("  2. Click '+' and add your Terminal app (or Python)")
        print("  3. Restart this driver")
        print()
        # Try to trigger the permission prompt
        from ApplicationServices import AXIsProcessTrustedWithOptions
        from Foundation import NSDictionary
        options = NSDictionary.dictionaryWithObject_forKey_(
            True, "AXTrustedCheckOptionPrompt")
        AXIsProcessTrustedWithOptions(options)
        return False
    return True


def main():
    print("=" * 60)
    print("  Wacom CTL-490 (Intuos S 2) macOS Driver")
    print("  Reverse-engineered from Linux kernel wacom_wac.c")
    print("=" * 60)
    print()

    if not check_accessibility():
        print("Continuing anyway (cursor movement may not work)...")
        print()

    driver = WacomDriver()

    if not driver.connect():
        sys.exit(1)

    # Handle Ctrl+C gracefully
    def sigint_handler(sig, frame):
        driver.stop()
    signal.signal(signal.SIGINT, sigint_handler)

    try:
        driver.run()
    finally:
        driver.disconnect()
        print("Device disconnected.")


def test_mode():
    """Diagnostic mode: show decoded pen data without posting events."""
    print("=" * 60)
    print("  Wacom CTL-490 — Diagnostic Mode")
    print("=" * 60)
    print()

    path = find_wacom_device()
    if not path:
        print("ERROR: Device not found!")
        sys.exit(1)

    h = hid.device()
    h.open_path(path)
    h.set_nonblocking(False)
    h.send_feature_report([0x02, 0x02])
    print(f"Connected: {h.get_manufacturer_string()} {h.get_product_string()}")
    print()
    print("Move the pen over the tablet. Press Ctrl+C to stop.")
    print()
    print(f"{'X':>6}/{X_MAX}  {'Y':>6}/{Y_MAX}  {'P':>5}/{PRESSURE_MAX}  "
          f"{'D':>3}/63  Touch  Btn1  Btn2  Eraser")
    print("-" * 75)

    prev_sig = None
    try:
        while True:
            data = h.read(64, 100)
            if not data:
                continue
            state = decode_report(data)
            if state is None:
                continue
            sig = (state.x >> 3, state.y >> 3, state.pressure >> 2,
                   state.touching, state.btn1, state.btn2, state.in_range)
            if sig != prev_sig:
                if not state.in_range:
                    print("  (pen out of range)")
                else:
                    p_pct = state.pressure / PRESSURE_MAX * 100
                    print(f"{state.x:6d}       {state.y:6d}       "
                          f"{state.pressure:5d}       {state.distance:3d}    "
                          f"{'YES' if state.touching else '---':>5}  "
                          f"{'YES' if state.btn1 else '---':>4}  "
                          f"{'YES' if state.btn2 else '---':>4}  "
                          f"{'YES' if state.eraser else '---':>6}")
                prev_sig = sig
    except KeyboardInterrupt:
        pass
    finally:
        h.close()
    print("\nDone.")


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] in ('--test', '-t', 'test'):
        test_mode()
    else:
        main()
