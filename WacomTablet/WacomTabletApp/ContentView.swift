import SwiftUI

struct ContentView: View {
    @ObservedObject var wacom: WacomManager

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "pencil.and.scribble")
                    .font(.title3)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Wacom Tablet Driver")
                        .font(.headline)
                    Text(wacom.deviceName.isEmpty ? "No tablet connected" : wacom.deviceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(wacom.deviceName.isEmpty ? .orange : .green)
                    .frame(width: 8, height: 8)
            }

            Divider()

            // Status
            HStack {
                Text(wacom.status)
                    .font(.system(.caption, design: .monospaced))
                Spacer()
            }

            // Permissions (only show if missing)
            if !wacom.hasAccessibility || !wacom.hasInputMonitoring {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    if !wacom.hasAccessibility {
                        HStack {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            Text("Accessibility").font(.caption)
                            Spacer()
                            Button("Grant") { wacom.requestAccessibility() }
                                .buttonStyle(.bordered).controlSize(.mini)
                        }
                    }
                    if !wacom.hasInputMonitoring {
                        HStack {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            Text("Input Monitoring").font(.caption)
                            Spacer()
                            Button("Open Settings") { wacom.openInputMonitoringSettings() }
                                .buttonStyle(.bordered).controlSize(.mini)
                        }
                    }
                }
            }

            // Pen state (live)
            if !wacom.deviceName.isEmpty {
                Divider()
                let s = wacom.penState
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    GridRow {
                        Text("Pos").foregroundStyle(.secondary)
                        Text("\(s.x), \(s.y)")
                    }
                    GridRow {
                        Text("Prs").foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text("\(s.pressure)")
                                .frame(width: 32, alignment: .trailing)
                            ProgressView(value: Double(s.pressure), total: 2047)
                                .frame(width: 80)
                        }
                    }
                    GridRow {
                        Text("").foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            flagBadge("Range", s.inRange)
                            flagBadge("Touch", s.touching)
                            flagBadge("Btn1", s.btn1)
                            flagBadge("Btn2", s.btn2)
                            flagBadge("Eraser", s.eraser)
                        }
                    }
                }
                .font(.system(.caption2, design: .monospaced))
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
        .frame(width: 300)
        .onAppear {
            wacom.checkPermissions()
        }

    }

    private func flagBadge(_ label: String, _ active: Bool) -> some View {
        Text(label)
            .font(.system(.caption2, design: .monospaced))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(active ? Color.blue.opacity(0.2) : Color.gray.opacity(0.1))
            .foregroundStyle(active ? .blue : .secondary)
            .cornerRadius(3)
    }
}
