import Foundation
import SystemExtensions
import os.log

class ExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {

    static let dextIdentifier = "com.wacomopensource.tablet.driver"

    private let logger = Logger(
        subsystem: "com.wacomopensource.tablet",
        category: "ExtensionManager"
    )

    @Published var status: String = "Not installed"
    @Published var isInstalled: Bool = false
    @Published var isBusy: Bool = false
    @Published var debugInfo: String = ""

    override init() {
        super.init()
        gatherDebugInfo()
    }

    private func gatherDebugInfo() {
        var lines: [String] = []

        let appBundle = Bundle.main
        lines.append("=== App ===")
        lines.append("Bundle path: \(appBundle.bundlePath)")
        lines.append("Bundle ID: \(appBundle.bundleIdentifier ?? "nil")")
        lines.append("Executable: \(appBundle.executablePath ?? "nil")")

        // Resolve any symlinks
        let resolvedPath = (appBundle.bundlePath as NSString).resolvingSymlinksInPath
        lines.append("Resolved path: \(resolvedPath)")
        lines.append("In /Applications: \(resolvedPath.hasPrefix("/Applications/"))")

        // Process info
        let procPath = ProcessInfo.processInfo.arguments.first ?? "unknown"
        lines.append("Process path: \(procPath)")
        lines.append("PID: \(ProcessInfo.processInfo.processIdentifier)")

        // SystemExtensions directory
        let sextDir = appBundle.bundlePath + "/Contents/Library/SystemExtensions"
        let fm = FileManager.default
        lines.append("")
        lines.append("=== SystemExtensions dir ===")
        lines.append("Path: \(sextDir)")
        lines.append("Exists: \(fm.fileExists(atPath: sextDir))")

        var isDir: ObjCBool = false
        fm.fileExists(atPath: sextDir, isDirectory: &isDir)
        lines.append("Is directory: \(isDir.boolValue)")

        if let contents = try? fm.contentsOfDirectory(atPath: sextDir) {
            lines.append("Contents: \(contents)")
            for item in contents {
                let itemPath = sextDir + "/" + item
                lines.append("")
                lines.append("--- \(item) ---")

                // Try loading as a Bundle
                if let extBundle = Bundle(path: itemPath) {
                    lines.append("  Bundle ID: \(extBundle.bundleIdentifier ?? "nil")")
                    lines.append("  Executable: \(extBundle.executablePath ?? "nil")")
                    let execExists = fm.fileExists(atPath: extBundle.executablePath ?? "")
                    lines.append("  Executable exists: \(execExists)")

                    // Check Info.plist keys
                    let pkgType = extBundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String ?? "nil"
                    let dkMin = extBundle.object(forInfoDictionaryKey: "OSMinimumDriverKitVersion") as? String ?? "nil"
                    let personalities = extBundle.object(forInfoDictionaryKey: "IOKitPersonalities") as? [String: Any]
                    lines.append("  Package type: \(pkgType)")
                    lines.append("  Min DriverKit: \(dkMin)")
                    lines.append("  Personalities: \(personalities?.keys.sorted().joined(separator: ", ") ?? "nil")")
                } else {
                    lines.append("  FAILED to load as Bundle!")
                    // Try reading Info.plist directly
                    let plistPath = itemPath + "/Info.plist"
                    lines.append("  Info.plist exists: \(fm.fileExists(atPath: plistPath))")
                }

                // Check code signature
                let pipe = Pipe()
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                proc.arguments = ["-dvv", itemPath]
                proc.standardOutput = pipe
                proc.standardError = pipe
                try? proc.run()
                proc.waitUntilExit()
                let csOutput = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let csLines = csOutput.components(separatedBy: "\n").filter {
                    $0.contains("TeamIdentifier") || $0.contains("Authority=") || $0.contains("Identifier=") || $0.contains("Format=")
                }
                for csLine in csLines {
                    lines.append("  \(csLine.trimmingCharacters(in: .whitespaces))")
                }
            }
        } else {
            lines.append("CANNOT read directory contents!")
        }

        lines.append("")
        lines.append("=== Request config ===")
        lines.append("Requesting ID: \(Self.dextIdentifier)")
        lines.append("ID match: \(Self.dextIdentifier == "com.wacomopensource.tablet.driver")")

        // Check systemextensionsctl list
        lines.append("")
        lines.append("=== Installed extensions ===")
        let sePipe = Pipe()
        let seProc = Process()
        seProc.executableURL = URL(fileURLWithPath: "/usr/bin/systemextensionsctl")
        seProc.arguments = ["list"]
        seProc.standardOutput = sePipe
        seProc.standardError = sePipe
        try? seProc.run()
        seProc.waitUntilExit()
        let seOutput = String(data: sePipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        lines.append(seOutput.trimmingCharacters(in: .whitespacesAndNewlines))

        debugInfo = lines.joined(separator: "\n")
        logger.info("\(self.debugInfo)")
    }

    func activate() {
        isBusy = true
        status = "Requesting activation..."
        logger.info("Submitting activation request for \(Self.dextIdentifier) from \(Bundle.main.bundlePath)")

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.dextIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func deactivate() {
        isBusy = true
        status = "Requesting deactivation..."
        logger.info("Submitting deactivation request for \(Self.dextIdentifier)")

        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.dextIdentifier,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: - OSSystemExtensionRequestDelegate

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        logger.info("Replacing v\(existing.bundleShortVersion) with v\(ext.bundleShortVersion)")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        logger.info("User approval required — check System Settings > Privacy & Security")
        status = "Waiting for approval in System Settings..."
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        isBusy = false
        switch result {
        case .completed:
            logger.info("Extension request completed successfully")
            if request.responds(to: NSSelectorFromString("isDeactivationRequest")) {
                status = "Driver uninstalled"
                isInstalled = false
            } else {
                status = "Driver installed and active"
                isInstalled = true
            }
        case .willCompleteAfterReboot:
            logger.info("Will complete after reboot")
            status = "Reboot required to complete"
        @unknown default:
            logger.info("Finished with result: \(result.rawValue)")
            status = "Completed (result \(result.rawValue))"
        }
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: Error
    ) {
        isBusy = false
        let nsError = error as NSError
        logger.error("Request failed: \(error.localizedDescription) (code \(nsError.code), domain: \(nsError.domain))")

        var lines: [String] = []
        lines.append("ERROR code \(nsError.code): \(error.localizedDescription)")

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            lines.append("Underlying: \(underlying.domain) code \(underlying.code)")
        }
        for (key, value) in nsError.userInfo where key != NSUnderlyingErrorKey {
            lines.append("  \(key): \(value)")
        }

        lines.append("")
        lines.append("=== Diagnosis ===")

        // 1. App location
        let appPath = Bundle.main.bundlePath
        let inApps = appPath.hasPrefix("/Applications/")
        lines.append(inApps ? "✓ App is in /Applications" : "✗ App NOT in /Applications: \(appPath)")

        // 2. Extension present
        let sextDir = appPath + "/Contents/Library/SystemExtensions"
        let dextPath = sextDir + "/WacomTabletDriver.systemextension"
        let fm = FileManager.default
        let dextExists = fm.fileExists(atPath: dextPath)
        lines.append(dextExists ? "✓ DEXT bundle exists" : "✗ DEXT bundle MISSING at \(dextPath)")

        // 3. Extension bundle ID
        if let extBundle = Bundle(path: dextPath) {
            let extID = extBundle.bundleIdentifier ?? "nil"
            let matches = extID == Self.dextIdentifier
            lines.append(matches ? "✓ Bundle ID matches: \(extID)" : "✗ Bundle ID MISMATCH: \(extID) != \(Self.dextIdentifier)")
        } else {
            lines.append("✗ Cannot load DEXT as Bundle")
        }

        // 4. DEXT executable
        let dextExec = dextPath + "/WacomTabletDriver"
        let execExists = fm.fileExists(atPath: dextExec)
        lines.append(execExists ? "✓ DEXT executable exists" : "✗ DEXT executable MISSING")

        // 5. Code signature — app
        lines.append("")
        lines.append("=== Code Signing ===")
        let appCS = runProcess("/usr/bin/codesign", args: ["-dvv", appPath])
        let appAuthority = appCS.components(separatedBy: "\n").first(where: { $0.contains("Authority=") }) ?? "unknown"
        let isDevID = appAuthority.contains("Developer ID")
        let isDev = appAuthority.contains("Apple Development")
        lines.append("App signed: \(appAuthority.trimmingCharacters(in: .whitespaces))")
        lines.append(isDevID ? "✓ App uses Developer ID" : isDev ? "⚠ App uses Development cert (needs Developer ID or developer mode)" : "✗ Unknown signing")

        // 6. Code signature — dext
        let dextCS = runProcess("/usr/bin/codesign", args: ["-dvv", dextPath])
        let dextAuthority = dextCS.components(separatedBy: "\n").first(where: { $0.contains("Authority=") }) ?? "unknown"
        let dextIsDevID = dextAuthority.contains("Developer ID")
        lines.append("DEXT signed: \(dextAuthority.trimmingCharacters(in: .whitespaces))")
        lines.append(dextIsDevID ? "✓ DEXT uses Developer ID" : "⚠ DEXT NOT Developer ID signed")

        // 7. Team ID match
        let appTeam = appCS.components(separatedBy: "\n").first(where: { $0.contains("TeamIdentifier=") })?.replacingOccurrences(of: "TeamIdentifier=", with: "").trimmingCharacters(in: .whitespaces) ?? "?"
        let dextTeam = dextCS.components(separatedBy: "\n").first(where: { $0.contains("TeamIdentifier=") })?.replacingOccurrences(of: "TeamIdentifier=", with: "").trimmingCharacters(in: .whitespaces) ?? "?"
        let teamsMatch = appTeam == dextTeam && appTeam != "?"
        lines.append(teamsMatch ? "✓ Team IDs match: \(appTeam)" : "✗ Team ID MISMATCH: app=\(appTeam) dext=\(dextTeam)")

        // 8. Provisioning profiles
        lines.append("")
        lines.append("=== Provisioning ===")
        let appProfile = appPath + "/Contents/embedded.provisionprofile"
        let dextProfile = dextPath + "/embedded.provisionprofile"
        lines.append(fm.fileExists(atPath: appProfile) ? "App has embedded.provisionprofile" : "App has NO provisioning profile")
        lines.append(fm.fileExists(atPath: dextProfile) ? "DEXT has embedded.provisionprofile" : "DEXT has NO provisioning profile")

        // Check DEXT profile entitlements if present
        if fm.fileExists(atPath: dextProfile) {
            let profileInfo = runProcess("/usr/bin/security", args: ["cms", "-D", "-i", dextProfile])
            let hasDriverKit = profileInfo.contains("com.apple.developer.driverkit")
            let hasHIDEvent = profileInfo.contains("driverkit.family.hid.eventservice")
            let hasHIDTransport = profileInfo.contains("driverkit.transport.hid")
            lines.append(hasDriverKit ? "  ✓ Profile grants: driverkit" : "  ✗ Profile MISSING: driverkit")
            lines.append(hasHIDEvent ? "  ✓ Profile grants: hid.eventservice" : "  ✗ Profile MISSING: hid.eventservice")
            lines.append(hasHIDTransport ? "  ✓ Profile grants: transport.hid" : "  ✗ Profile MISSING: transport.hid")
        }

        // Check DEXT entitlements vs profile
        let dextEnts = runProcess("/usr/bin/codesign", args: ["-d", "--entitlements", "-", dextPath])
        let claimsDriverKit = dextEnts.contains("com.apple.developer.driverkit")
        if claimsDriverKit && !fm.fileExists(atPath: dextProfile) {
            lines.append("⚠ DEXT claims DriverKit entitlements but has NO provisioning profile to back them")
        }

        // 9. Notarization
        lines.append("")
        lines.append("=== Notarization ===")
        let spctlOut = runProcess("/usr/sbin/spctl", args: ["--assess", "--type", "execute", "-v", appPath])
        if spctlOut.contains("accepted") && spctlOut.contains("Notarized") {
            lines.append("✓ App is notarized")
        } else if spctlOut.contains("accepted") {
            lines.append("⚠ App accepted but may not be notarized: \(spctlOut)")
        } else {
            lines.append("✗ App NOT accepted by Gatekeeper: \(spctlOut)")
        }

        // 10. SIP / Developer mode
        lines.append("")
        lines.append("=== System Policy ===")
        let sipOut = runProcess("/usr/bin/csrutil", args: ["status"])
        let sipDisabled = sipOut.contains("disabled")
        lines.append(sipDisabled ? "SIP: disabled (developer mode possible)" : "SIP: enabled")

        let devOut = runProcess("/usr/bin/systemextensionsctl", args: ["developer"])
        // "developer on" output contains "enabled" when actually on,
        // but error message about SIP also contains "enabled" — disambiguate
        if devOut.contains("developer mode") && devOut.contains("enabled") && !devOut.contains("System Integrity Protection") {
            lines.append("✓ Developer mode: ON")
        } else if sipDisabled {
            lines.append("Developer mode: OFF (run: systemextensionsctl developer on)")
        } else {
            lines.append("Developer mode: N/A (SIP is enabled)")
        }

        // Summary
        lines.append("")
        lines.append("=== Summary ===")
        if !inApps {
            lines.append("→ Move the app to /Applications")
        }
        if !dextExists {
            lines.append("→ DEXT bundle is missing from the app")
        }
        if isDev && !sipDisabled {
            lines.append("→ Development-signed: needs SIP disabled + developer mode, OR re-sign with Developer ID")
        }
        if isDevID && claimsDriverKit && !fm.fileExists(atPath: dextProfile) {
            lines.append("→ DEXT claims DriverKit entitlements without a provisioning profile")
            lines.append("→ Need: Apple-approved DriverKit capability on App ID, then create Developer ID provisioning profile with DriverKit entitlements")
        }
        if isDevID && fm.fileExists(atPath: dextProfile) {
            let profileInfo = runProcess("/usr/bin/security", args: ["cms", "-D", "-i", dextProfile])
            if !profileInfo.contains("com.apple.developer.driverkit") {
                lines.append("→ Provisioning profile does NOT include DriverKit entitlements")
                lines.append("→ Need: Request DriverKit capability approval from Apple, then recreate the profile")
            }
        }

        status = lines.joined(separator: "\n")
    }

    private func runProcess(_ path: String, args: [String]) -> String {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardOutput = pipe
        proc.standardError = pipe
        try? proc.run()
        proc.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
