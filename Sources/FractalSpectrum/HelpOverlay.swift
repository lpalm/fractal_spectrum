import SwiftUI

/// The keyboard and mouse shortcuts (? or the question-mark button).
struct HelpOverlay: View {
    @Bindable var model: AppModel

    private let rows: [(keys: String, action: String)] = [
        ("Drag / two-finger scroll", "Pan"),
        ("Scroll wheel / pinch / ⌘-scroll", "Zoom at pointer"),
        ("Double-click / right-click", "Zoom in / out"),
        ("Arrows · + / −", "Pan · zoom"),
        ("Rotate gesture · Q / E", "Rotate"),
        ("Hold ⌥ / ⌥-click", "Preview / open the Julia set at the pointer"),
        ("Hold ⇧", "Orbit of the point under the pointer"),
        ("J", "Toggle Julia set"),
        ("C / X", "Next / previous palette"),
        ("[ / ]", "Halve / double iterations"),
        ("L", "Relief lighting"),
        ("P", "Autopilot dive (follows intricate detail, stops at minibrots)"),
        (", / .", "Autopilot slower / faster"),
        ("T", "Guided tour"),
        ("H", "Home"),
        ("B", "Save view to Your Places"),
        ("M", "Find a mini-Mandelbrot in view"),
        ("F", "Full screen"),
        ("Space", "Hide interface"),
        ("? / Esc", "Show / hide these shortcuts"),
        ("⌘S / ⌘E", "Export image / zoom video"),
        ("⇧⌘C / ⌘L", "Copy / go to coordinates"),
        ("⌥⌘C", "Copy image"),
        ("⌘R", "Record the view to a movie"),
        ("⌘[ / ⌘]", "Back / forward through visited views"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Shortcuts")
                    .font(.rounded(20, .bold))
                Spacer()
                Button { model.showHelp = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Close")
            }
            // two columns, so the list fits the smallest window
            HStack(alignment: .top, spacing: 32) {
                column(rows.prefix((rows.count + 1) / 2))
                column(rows.dropFirst((rows.count + 1) / 2))
            }
        }
        .padding(24)
        .frame(width: 820)
        .panelGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func column(_ part: ArraySlice<(keys: String, action: String)>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            ForEach(part, id: \.keys) { row in
                GridRow {
                    Text(row.keys)
                        .font(.rounded(13, .semibold))
                    Text(row.action)
                        .font(.rounded(13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
