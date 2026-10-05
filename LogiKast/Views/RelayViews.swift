import SwiftUI

/// The rows that describe another server a stream is taken from: used for a relay mount's source and for a backup stream.
struct RelayEditor: View {
    @Binding var relay: RelaySource

    var body: some View {
        LabeledContent("Server") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TextField("", text: $relay.server, prompt: Text("e.g. radio.example.com"))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                Text(":").foregroundStyle(.secondary)
                TextField("", value: $relay.port, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                    .help("The other server's port")
            }
        }
        LabeledContent("Mount on that server") {
            TextField("", text: $relay.mount, prompt: Text("/live")).multilineTextAlignment(.trailing).autocorrectionDisabled()
        }
        LabeledContent("Login (if it asks)") {
            HStack(spacing: 8) {
                TextField("", text: $relay.username, prompt: Text("Username")).multilineTextAlignment(.trailing).autocorrectionDisabled()
                SecureField("", text: $relay.password, prompt: Text("Password")).multilineTextAlignment(.trailing)
            }
        }
        Toggle("Only pull the stream while someone is listening", isOn: $relay.onDemand)
    }
}
