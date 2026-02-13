import SwiftUI

@main
struct WacomTabletApp: App {
    @StateObject private var extensionManager = ExtensionManager()

    var body: some Scene {
        WindowGroup {
            ContentView(manager: extensionManager)
        }
    }
}

struct ContentView: View {
    @ObservedObject var manager: ExtensionManager

    var body: some View {
        VStack(spacing: 16) {
            Text("Wacom Tablet Driver")
                .font(.title2.bold())

            Text(manager.status)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Install Driver") { manager.activate() }
                    .disabled(manager.isBusy || manager.isInstalled)
                Button("Uninstall") { manager.deactivate() }
                    .disabled(manager.isBusy || !manager.isInstalled)
            }
            .buttonStyle(.bordered)

            if !manager.debugInfo.isEmpty {
                ScrollView {
                    Text(manager.debugInfo)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
        }
        .padding(24)
        .frame(width: 480, height: 400)
    }
}
