import Foundation
import AppKit
import IOKit.hid
import CoreGraphics
import ApplicationServices

// MARK: - Device Constants

private let wacomVendorID: Int = 0x056A
private let wacomUsagePage: Int = 0xFF0D // Wacom proprietary digitizer

private let supportedDevices: [(pid: Int, maxX: Int, maxY: Int, name: String)] = [
    (0x033B, 15200,  9500, "Intuos S (CTL-490)"),
    (0x033C, 15200,  9500, "Intuos S Touch (CTH-490)"),
    (0x033D, 21600, 13500, "Intuos M (CTL-690)"),
    (0x033E, 21600, 13500, "Intuos M Touch (CTH-690)"),
]

private let pressureMax = 2047
private let distanceMax = 63
private let pressureThreshold = 10
private let reportPenabled: UInt8 = 0x10

// MARK: - Pen State

struct PenState {
    var x: Int = 0
    var y: Int = 0
    var pressure: Int = 0
    var distance: Int = 63
    var inRange: Bool = false
    var near: Bool = false
    var touching: Bool = false
    var btn1: Bool = false
    var btn2: Bool = false
    var eraser: Bool = false
    var screenX: Double = 0
    var screenY: Double = 0
}

// MARK: - WacomManager

class WacomManager: ObservableObject {

    @Published var status: String = "Stopped"
    @Published var isRunning: Bool = false
    @Published var deviceName: String = ""
    @Published var penState: PenState = PenState()
    @Published var hasAccessibility: Bool = false
    @Published var hasInputMonitoring: Bool = false
    @Published var reportCount: Int = 0

    private var manager: IOHIDManager?
    private var reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var maxX: Int = 15200
    private var maxY: Int = 9500
    private var screenW: Double = 0
    private var screenH: Double = 0

    // Previous state for edge detection
    private var wasTouching = false
    private var wasBtn1 = false
    private var wasBtn2 = false
    private var wasInRange = false

    init() {
        let displayID = CGMainDisplayID()
        screenW = Double(CGDisplayPixelsWide(displayID))
        screenH = Double(CGDisplayPixelsHigh(displayID))
        checkPermissions()
        // Auto-start on launch
        DispatchQueue.main.async { [weak self] in
            self?.start()
        }
    }

    deinit {
        reportBuffer.deallocate()
    }

    // MARK: - Permissions

    func checkPermissions() {
        hasAccessibility = AXIsProcessTrusted()
        // Input monitoring is only reliably known after IOHIDManager open attempt.
        // Don't overwrite if we already determined it from a successful open.
        if !isRunning {
            // Before starting, probe with a temporary manager
            let probe = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatching(probe, nil)
            IOHIDManagerScheduleWithRunLoop(probe, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            let result = IOHIDManagerOpen(probe, IOOptionBits(kIOHIDOptionsTypeNone))
            hasInputMonitoring = (result == kIOReturnSuccess)
            IOHIDManagerClose(probe, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(probe, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        // Poll a few times since the permission isn't instant
        for delay in [1.0, 2.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.hasAccessibility = AXIsProcessTrusted()
            }
        }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    // MARK: - Start / Stop

    func start() {
        guard manager == nil else { return }

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Build matching array for all supported PIDs on the Wacom vendor-specific usage page
        var matchingArray: [[String: Any]] = []
        for device in supportedDevices {
            matchingArray.append([
                kIOHIDVendorIDKey as String: wacomVendorID,
                kIOHIDProductIDKey as String: device.pid,
                kIOHIDPrimaryUsagePageKey as String: wacomUsagePage,
            ])
        }
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matchingArray as CFArray)

        // Register callbacks
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, hidDeviceAdded, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, hidDeviceRemoved, ctx)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let result = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnSuccess {
            manager = mgr
            isRunning = true
            status = "Waiting for tablet..."
            hasInputMonitoring = true
        } else if result == kIOReturnNotPermitted {
            status = "Input Monitoring permission required"
            hasInputMonitoring = false
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        } else {
            status = "Failed to open HID manager (\(result))"
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    func stop() {
        if let mgr = manager {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        isRunning = false
        deviceName = ""
        status = "Stopped"
        wasTouching = false
        wasBtn1 = false
        wasBtn2 = false
        wasInRange = false
        reportCount = 0
    }

    // MARK: - HID Callbacks

    fileprivate func onDeviceAdded(_ device: IOHIDDevice) {
        // Identify which model
        let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        if let info = supportedDevices.first(where: { $0.pid == pid }) {
            maxX = info.maxX
            maxY = info.maxY
            deviceName = info.name
            status = "Connected: \(info.name)"
        } else {
            deviceName = "Unknown Wacom"
            status = "Connected: Unknown model (PID \(String(format: "0x%04X", pid)))"
        }

        // Switch to tablet mode (Feature Report 0x02)
        var featureReport: [UInt8] = [0x02, 0x02]
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0x02, &featureReport, featureReport.count)

        // Register raw report callback
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 64, hidReportReceived, ctx)
    }

    fileprivate func onDeviceRemoved(_ device: IOHIDDevice) {
        // Release any held buttons
        if wasTouching {
            postTabletEvent(.leftMouseUp, penState)
            wasTouching = false
        }
        if wasBtn1 {
            postTabletEvent(.rightMouseUp, penState, button: .right)
            wasBtn1 = false
        }
        if wasInRange {
            postProximityEvent(entering: false)
            wasInRange = false
        }
        deviceName = ""
        status = "Tablet disconnected"
    }

    fileprivate func onReport(_ report: UnsafeMutablePointer<UInt8>, length: Int) {
        guard length >= 10, report[0] == reportPenabled else { return }

        let state = decodeReport(report)
        reportCount += 1

        DispatchQueue.main.async { [weak self] in
            self?.penState = state
        }

        handleReport(state)
    }

    // MARK: - INTUOSHT2 Protocol Decode

    private func decodeReport(_ data: UnsafeMutablePointer<UInt8>) -> PenState {
        var s = PenState()

        let status = data[1]
        s.inRange = (status & 0x80) != 0
        s.near    = (status & 0x40) != 0
        let ready = (status & 0x20) != 0
        s.eraser  = (status & 0x08) != 0
        s.btn2    = (status & 0x04) != 0
        s.btn1    = (status & 0x02) != 0

        if s.near || s.inRange {
            // X = (big-endian(data[2:3]) << 1) | ((data[9] >> 1) & 1)
            let xHigh = (Int(data[2]) << 8) | Int(data[3])
            s.x = (xHigh << 1) | ((Int(data[9]) >> 1) & 1)

            // Y = (big-endian(data[4:5]) << 1) | (data[9] & 1)
            let yHigh = (Int(data[4]) << 8) | Int(data[5])
            s.y = (yHigh << 1) | (Int(data[9]) & 1)
        }

        if ready {
            // P = (data[6] << 3) | ((data[7] & 0xC0) >> 5) | (status & 1)
            s.pressure = (Int(data[6]) << 3) | ((Int(data[7]) & 0xC0) >> 5) | (Int(status) & 1)
        }

        if s.inRange {
            let rawDist = Int(data[9]) >> 2
            s.distance = max(0, distanceMax - rawDist)
        } else {
            s.distance = distanceMax
        }

        s.touching = s.pressure > pressureThreshold

        // Map to screen
        let nx = max(0.0, min(1.0, Double(s.x) / Double(maxX)))
        let ny = max(0.0, min(1.0, Double(s.y) / Double(maxY)))
        s.screenX = nx * screenW
        s.screenY = ny * screenH

        return s
    }

    // MARK: - Event Dispatch (State Machine)

    private func handleReport(_ state: PenState) {
        if !state.inRange && !state.near {
            // Pen left proximity
            if wasTouching {
                postTabletEvent(.leftMouseUp, penState)
                wasTouching = false
            }
            if wasBtn1 {
                postTabletEvent(.rightMouseUp, penState, button: .right)
                wasBtn1 = false
            }
            if wasInRange {
                postProximityEvent(entering: false)
            }
            wasInRange = false
            return
        }

        // Pen entered proximity
        if !wasInRange {
            postProximityEvent(entering: true, eraser: state.eraser)
        }
        wasInRange = true

        // Button 1 (side button → right click)
        if state.btn1 && !wasBtn1 {
            postTabletEvent(.rightMouseDown, state, button: .right)
            wasBtn1 = true
        } else if !state.btn1 && wasBtn1 {
            postTabletEvent(.rightMouseUp, state, button: .right)
            wasBtn1 = false
        }

        // Pen tip (touch → left click + drag with pressure)
        if state.touching && !wasTouching {
            postTabletEvent(.leftMouseDown, state)
            wasTouching = true
        } else if !state.touching && wasTouching {
            postTabletEvent(.leftMouseUp, state)
            wasTouching = false
        } else if state.touching {
            postTabletEvent(.leftMouseDragged, state)
        } else {
            postTabletEvent(.mouseMoved, state)
        }
    }

    // MARK: - CGEvent Posting

    private func postTabletEvent(_ eventType: CGEventType, _ state: PenState, button: CGMouseButton = .left) {
        let point = CGPoint(x: state.screenX, y: state.screenY)
        guard let event = CGEvent(mouseEventSource: nil, mouseType: eventType, mouseCursorPosition: point, mouseButton: button) else { return }

        // Mark as tablet point event
        event.setIntegerValueField(.mouseEventSubtype, value: 1) // kCGEventMouseSubtypeTabletPoint

        // Pressure (0.0 – 1.0)
        let pressureNorm = min(1.0, Double(state.pressure) / Double(pressureMax))
        event.setDoubleValueField(.tabletEventPointPressure, value: pressureNorm)

        // Tablet coordinates
        event.setIntegerValueField(.tabletEventPointX, value: Int64(state.x))
        event.setIntegerValueField(.tabletEventPointY, value: Int64(state.y))

        // Button mask
        var btnMask: Int64 = 0
        if state.touching { btnMask |= 1 }
        if state.btn1 { btnMask |= 2 }
        if state.btn2 { btnMask |= 4 }
        event.setIntegerValueField(.tabletEventPointButtons, value: btnMask)

        // Device ID
        event.setIntegerValueField(.tabletEventDeviceID, value: 1)

        event.post(tap: .cghidEventTap)
    }

    private func postProximityEvent(entering: Bool, eraser: Bool = false) {
        guard let event = CGEvent(source: nil) else { return }

        event.type = .tabletProximity

        event.setIntegerValueField(.tabletProximityEventVendorID, value: Int64(wacomVendorID))
        event.setIntegerValueField(.tabletProximityEventTabletID, value: 1)
        event.setIntegerValueField(.tabletProximityEventPointerID, value: 1)
        event.setIntegerValueField(.tabletProximityEventDeviceID, value: 1)
        event.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 1)
        event.setIntegerValueField(.tabletProximityEventVendorPointerType, value: 1)
        event.setIntegerValueField(.tabletProximityEventVendorPointerSerialNumber, value: 1)
        event.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: Int64(0x033B))
        event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x0001) // pressure
        event.setIntegerValueField(.tabletProximityEventPointerType, value: eraser ? 3 : 1) // 1=pen, 3=eraser
        event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)

        event.post(tap: .cghidEventTap)
    }
}

// MARK: - C Callback Functions

private func hidDeviceAdded(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context = context else { return }
    let mgr = Unmanaged<WacomManager>.fromOpaque(context).takeUnretainedValue()
    mgr.onDeviceAdded(device)
}

private func hidDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context = context else { return }
    let mgr = Unmanaged<WacomManager>.fromOpaque(context).takeUnretainedValue()
    mgr.onDeviceRemoved(device)
}

private func hidReportReceived(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context = context else { return }
    let mgr = Unmanaged<WacomManager>.fromOpaque(context).takeUnretainedValue()
    mgr.onReport(report, length: reportLength)
}
