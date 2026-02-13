import SwiftUI

@main
struct WacomTabletApp: App {
    @StateObject private var wacom = WacomManager()

    var body: some Scene {
        MenuBarExtra {
            ContentView(wacom: wacom)
        } label: {
            Image(systemName: wacom.deviceName.isEmpty ? "pencil.slash" : "pencil.and.scribble")
        }
        .menuBarExtraStyle(.window)
    }
}
