import Core
import CloudCore
import SwiftUI

/// Editable local/remote addresses with a per-address connection test.
struct ServerAddressSection: View {
    let model: AppModel

    @State private var local = ""
    @State private var remote = ""
    @State private var report: [String]?
    @State private var isTesting = false

    var body: some View {
        Section {
            LabeledContent("Home") {
                TextField("192.168.1.10:2283", text: $local)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Away") {
                TextField("100.64.0.10:2283", text: $remote)
                    .multilineTextAlignment(.trailing)
            }
            Button {
                test()
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if isTesting { ProgressView() }
                }
            }
            .disabled(isTesting)
            if let report {
                ForEach(report, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(line.contains("OK") ? Color.secondary : Color.red)
                }
            }
        } header: {
            Text("Server")
        } footer: {
            Text("The home address is used when it answers within 1.5 seconds; otherwise the away address (Tailscale).")
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
        .onAppear {
            local = model.serverSettings.addresses.local?.absoluteString ?? ""
            remote = model.serverSettings.addresses.remote?.absoluteString ?? ""
        }
        .onChange(of: local) { save() }
        .onChange(of: remote) { save() }
    }

    private func save() {
        let addresses = ServerAddresses(local: ServerAddresses.normalize(local), remote: ServerAddresses.normalize(remote))
        guard addresses != model.serverSettings.addresses else { return }
        model.serverSettings.addresses = addresses
        model.reconnect()
    }

    private func test() {
        isTesting = true
        Task {
            report = await model.connectivityReport()
            isTesting = false
        }
    }
}
