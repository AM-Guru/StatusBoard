#if os(macOS)
import SwiftUI

/// Control panel for the Mac's bridge server: start/stop, port, token,
/// connected devices, live log, and copy-paste push examples.
public struct BridgeConsoleView: View {
    @Bindable var server: BridgeServer

    public init(server: BridgeServer) {
        self.server = server
    }

    var sampleCurl: String {
        let authorization = server.token.isEmpty
            ? "" : " -H 'X-StatusBoard-Token: \(server.token)'"
        return "curl -X POST http://localhost:\(server.port)/api/push\(authorization) -d '{\"key\":\"cpu\",\"number\":42,\"unit\":\"%\",\"history\":120}'"
    }

    public var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(server.isRunning ? SBTheme.good : SBTheme.textSecondary)
                            .frame(width: 8, height: 8)
                        Text(server.isRunning ? "Running" : "Stopped")
                    }
                }
                LabeledContent("Devices connected") {
                    Text("\(server.subscriberCount)")
                }
                TextField("Port", value: $server.port, format: .number.grouping(.never))
                    .disabled(server.isRunning)
                SecureField("Token (optional)", text: $server.token)
                Text("When set, data pushes and subscribing devices must use this token. Enter the same token in the Apple TV bridge settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("Publish this Mac's system metrics (mac.cpu, mac.memory, …)",
                       isOn: $server.publishesSystemMetrics)
                Button(server.isRunning ? "Stop Bridge" : "Start Bridge") {
                    server.isRunning ? server.stop() : server.start()
                }
                if let error = server.lastError {
                    Text(error).foregroundStyle(SBTheme.bad)
                }
            }

            Section("Push data from the terminal") {
                Text(sampleCurl)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text("Or use the bundled CLI:  sbctl push --key cpu --number 42")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section("Log") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(server.log.suffix(80).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 120, maxHeight: 200)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 520)
    }
}
#endif
