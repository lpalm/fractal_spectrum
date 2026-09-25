import SwiftUI

/// Paste coordinates (as copied with ⇧⌘C, or "re im zoom") and fly there.
struct GoToSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Go to Coordinates")
                .font(.rounded(20, .bold))
            Text("Paste \"re: … im: … zoom: …\" as copied with ⇧⌘C, or three numbers: real, imaginary, log₁₀ zoom.")
                .font(.rounded(12))
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if failed {
                Text("Couldn't read coordinates from that text.")
                    .font(.rounded(12))
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Paste") { text = NSPasteboard.general.string(forType: .string) ?? text }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Go") {
                    if model.goTo(text: text) { dismiss() } else { failed = true }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string), clip.contains("re:") { text = clip }
        }
    }
}
