# Wacom Tablet Driver — Distribution Paths

## Current: Userspace Driver (CGEventPost)

**Branch**: `userspace-driver`
**Status**: Working, shipping now
**App Store**: No — CGEventPost is blocked by App Sandbox
**Distribution**: Direct (Developer ID + notarized), via website/GitHub

### How it works
- IOHIDManager reads raw HID reports from Wacom tablet (Usage Page 0xFF0D)
- Decodes INTUOSHT2 protocol (10-byte reports, Report ID 0x10)
- Posts CGEvent tablet events with pressure via CGEventPost
- Requires: Accessibility + Input Monitoring permissions (runtime, not entitlements)

### Limitations
- Cannot be sandboxed (CGEventPost requires Accessibility, which escapes sandbox)
- Cannot go on Mac App Store (sandbox is mandatory)
- Requires user to grant two permissions manually

### Build & ship
```bash
cd WacomTablet
xcodegen generate
xcodebuild -scheme WacomTabletApp -configuration Release CODE_SIGNING_ALLOWED=NO CONFIGURATION_BUILD_DIR=build
codesign --force --options runtime --sign "Developer ID Application: Mahmoud Lababidi (V29E8BPY35)" --entitlements WacomTabletApp/WacomTabletApp.entitlements --timestamp build/WacomTabletApp.app
ditto -c -k --keepParent build/WacomTabletApp.app build/WacomTabletApp.zip
xcrun notarytool submit build/WacomTabletApp.zip --apple-id lababidi@gmail.com --password gkec-sqyp-uohr-jjqr --team-id V29E8BPY35 --wait
xcrun stapler staple build/WacomTabletApp.app
```

---

## Path 2: DriverKit System Extension

**Branch**: `main`
**Status**: Compiles, signed, notarized — blocked on Apple entitlement approval
**App Store**: Yes (once approved)
**Distribution**: App Store or Developer ID

### How it works
- DriverKit extension (DEXT) subclasses IOUserHIDEventService
- Matches Wacom devices via IOKitPersonalities (VID/PID/UsagePage)
- Decodes INTUOSHT2 in handleReport(), dispatches via dispatchDigitizerStylusEvent()
- Container SwiftUI app handles system extension installation via OSSystemExtensionRequest

### What's blocking
- Developer ID provisioning profile for DEXT lacks DriverKit entitlements
- DriverKit entitlements are "managed capabilities" requiring Apple approval
- Request form: https://developer.apple.com/contact/request/system-extension/
- Portal "Capability Requests" tab was giving 500 errors

### Entitlements needed (for DEXT)
- `com.apple.developer.driverkit`
- `com.apple.developer.driverkit.family.hid.eventservice`
- `com.apple.developer.driverkit.transport.hid`

### To unblock
1. Submit request at https://developer.apple.com/contact/request/system-extension/
   - Vendor ID: 0x056A (Wacom)
   - Hardware: CTL-490, CTH-490, CTL-690, CTH-690 (Intuos 2nd gen)
   - Entitlement group: driverkit + transport.hid + family.hid.eventservice
2. Wait for Apple approval (days to weeks)
3. Enable capabilities on App ID `com.wacomopensource.tablet.driver`
4. Recreate Developer ID provisioning profile — it will now include DriverKit entitlements
5. Rebuild, embed profile, sign, notarize, deploy

### Alternative: SIP disabled for development
```bash
# From Recovery Mode:
csrutil disable
# Then in Terminal:
systemextensionsctl developer on
```
Build with Automatic signing + "Apple Development" identity — dev profiles already have DriverKit entitlements.

---

## Path 3: CoreHID Virtual Device (Potential App Store Path)

**Branch**: Not yet created
**Status**: Not implemented
**App Store**: Potentially yes
**Distribution**: App Store or Developer ID

### How it works
- IOHIDManager reads raw HID reports from Wacom (same as userspace driver)
- Decodes INTUOSHT2 protocol (same code)
- Instead of CGEventPost, creates a **HIDVirtualDevice** (CoreHID framework) with a tablet/digitizer HID descriptor
- Dispatches decoded pen data as HID reports to the virtual device
- macOS sees the virtual device as a real tablet — no Accessibility permission needed

### Key API: CoreHID (macOS 15+)
```swift
import CoreHID

// Create virtual device with digitizer descriptor
let properties = HIDVirtualDevice.Properties(descriptor: digitizerDescriptor)
let virtualDevice = try HIDVirtualDevice(properties: properties)

// Activate
try await virtualDevice.activate()

// Send reports
try await virtualDevice.dispatchInputReport(reportData)
```

### Entitlement required
- `com.apple.developer.hid.virtual.device` (managed capability — requires Apple approval)
- Request via Certificates, Identifiers & Profiles → App ID → Capability Requests tab

### Advantages over CGEventPost
- No Accessibility permission needed (no CGEventPost)
- Potentially sandbox-compatible (no escaping sandbox)
- Virtual device appears as real hardware to all apps
- More reliable pressure/tilt support (native HID path)

### Advantages over DriverKit
- No system extension installation (no OSSystemExtensionRequest, no user approval in System Settings)
- Simpler architecture (single app, no DEXT)
- Likely easier App Store review

### Open questions
- Does `com.apple.developer.hid.virtual.device` work in sandboxed apps? (Likely yes, but unconfirmed)
- What's the approval timeline for this entitlement?
- Does IOHIDManager reading work in sandbox? (May need `com.apple.security.device.usb` or similar)
- macOS 15+ requirement — excludes older systems

### HID Descriptor for virtual tablet
Need to define a USB HID descriptor for a digitizer/stylus device:
- Usage Page: Digitizers (0x0D)
- Usage: Pen (0x02)
- Reports: In Range, Tip Switch, Barrel Switch, Eraser, Invert, X, Y, Tip Pressure
- Logical maximums matching tablet dimensions (15200x9500 for S, 21600x13500 for M)

### Implementation plan
1. Create branch `corehid-virtual-device`
2. Keep IOHIDManager reading code from userspace driver
3. Replace CGEventPost with HIDVirtualDevice
4. Define proper digitizer HID descriptor
5. Request `com.apple.developer.hid.virtual.device` entitlement from Apple
6. Test with Krita for pressure sensitivity
7. If sandbox-compatible, submit to App Store

---

## Supported Devices (All Paths)

| Model | PID | Max X | Max Y | Max Pressure | Touch |
|-------|-----|-------|-------|-------------|-------|
| CTL-490 (Intuos S) | 0x033B | 15200 | 9500 | 2047 | No |
| CTH-490 (Intuos S Touch) | 0x033C | 15200 | 9500 | 2047 | Yes |
| CTL-690 (Intuos M) | 0x033D | 21600 | 13500 | 2047 | No |
| CTH-690 (Intuos M Touch) | 0x033E | 21600 | 13500 | 2047 | Yes |

All use INTUOSHT2 protocol, VID 0x056A, Usage Page 0xFF0D.

## Signing Credentials

- Apple ID: lababidi@gmail.com
- Team ID: V29E8BPY35
- Developer ID: "Developer ID Application: Mahmoud Lababidi (V29E8BPY35)"
- App-specific password (notarization): gkec-sqyp-uohr-jjqr
