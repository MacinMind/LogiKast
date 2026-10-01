import SwiftUI
import AppKit

struct CopyableRow: View {
    let label: String
    let value: String
    var secret = false
    @State private var revealed = false
    @State private var copied = false

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(secret && !revealed ? String(repeating: "•", count: max(value.count, 6)) : value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer()
            if secret {
                Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless).help(revealed ? "Hide" : "Show")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
            .buttonStyle(.borderless).help("Copy")
        }
    }
}

struct IntField: View {
    let title: String
    @Binding var value: Int
    var suffix: String?

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField("", value: $value, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                if let suffix { Text(suffix).foregroundStyle(.secondary) }
            }
        }
    }
}

struct IssuesView: View {
    let issues: [ConfigIssue]
    var body: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(issues) { i in
                    Label(i.message, systemImage: i.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(i.severity == .error ? Color.red : Color.orange)
                        .font(.callout)
                }
            }
        }
    }
}
