import SwiftUI
import FractalKit

/// The glass sidebar: formula, places, colour, quality and export, each in its own card.
struct Sidebar: View {
    @Bindable var model: AppModel
    let thumbnails: Thumbnails
    static let width: CGFloat = 304

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                header
                FractalSection(model: model, thumbnails: thumbnails)
                PlacesSection(model: model, thumbnails: thumbnails)
                ColorSection(model: model)
                QualitySection(model: model)
                ExportSection(model: model)
            }
            .padding(12)
        }
        .frame(width: Sidebar.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .panelGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer().frame(height: 18)   // clear the window's traffic-light buttons
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Spectrum")
                    .font(.rounded(26, .bold))
                Text("fractal explorer")
                    .font(.rounded(12, .medium))
                    .foregroundStyle(.secondary)
            }
            PaletteStrip(palette: Palette.all[model.color.palette])
                .frame(height: 5)
                .clipShape(Capsule())
                .animation(.easeInOut(duration: 0.4), value: model.color.palette)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }
}

/// A sidebar card with a title that folds it away (remembered across launches), and an optional
/// control or note beside the title.
struct CollapsibleSection<Content: View, Trailing: View>: View {
    let title: String
    @AppStorage private var expanded: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, id: String, @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        _expanded = AppStorage(wrappedValue: true, "section.\(id)")
        self.content = content
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.spring(duration: 0.35)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.tertiary)
                        Text(title.uppercased())
                            .font(.rounded(11, .semibold))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                trailing()
            }
            if expanded {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
    }
}

extension CollapsibleSection where Trailing == EmptyView {
    init(_ title: String, id: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, id: id, content: content, trailing: { EmptyView() })
    }
}

/// The fractal families, the Multibrot power and the Julia switch.
struct FractalSection: View {
    @Bindable var model: AppModel
    let thumbnails: Thumbnails

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        CollapsibleSection("Fractal", id: "fractal") {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(FractalFamily.allCases) { family in
                    FamilyTile(title: family.displayName, image: thumbnails.image(for: family),
                               selected: model.formula.family == family) {
                        model.selectFamily(family, power: family == .mandelbrot ? 2 : nil)
                    }
                }
            }
            if model.formula.family == .mandelbrot {
                HStack(spacing: 5) {
                    Text("Power")
                        .font(.rounded(12, .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    ForEach(2...8, id: \.self) { power in
                        Button {
                            model.selectFamily(.mandelbrot, power: power)
                        } label: {
                            Text("\(power)")
                                .font(.rounded(12, .semibold))
                                .frame(width: 24, height: 22)
                                .background(model.formula.effectivePower == power ? Color.accentColor.opacity(0.85)
                                                                                   : Color.white.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            SwitchRow("Julia set",
                      detail: model.formula.julia ? String(format: "c = %.5f %+.5fi", model.formula.juliaRe, model.formula.juliaIm)
                                                  : "Hold ⌥ over the set to preview",
                      isOn: Binding(get: { model.formula.julia }, set: { if $0 != model.formula.julia { model.toggleJulia() } }))
                .help("Hold ⌥ over the Mandelbrot set to preview a Julia set; ⌥-click opens it")
        }
    }
}

/// Thumbnail tile of a fractal family.
struct FamilyTile: View {
    let title: String
    let image: NSImage?
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35))
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    }
                }
                .frame(height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.white.opacity(hover ? 0.3 : 0.08),
                                      lineWidth: selected ? 2 : 1)
                )
                .scaleEffect(hover ? 1.02 : 1)
                Text(title)
                    .font(.rounded(12, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
        .animation(.easeOut(duration: 0.3), value: image != nil)
    }
}

/// The user's saved places and the curated ones (the first few, or all of them).
struct PlacesSection: View {
    @Bindable var model: AppModel
    let thumbnails: Thumbnails
    @AppStorage("places.showAll") private var showAll = false
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    /// Curated places shown while the list is folded.
    private static let foldedCount = 6

    var body: some View {
        CollapsibleSection("Explore", id: "explore") {
            if !model.bookmarks.isEmpty {
                subheading("Your Places")
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(model.bookmarks) { place in
                        PlaceTile(location: place, image: thumbnails.image(for: place)) { model.fly(to: place) }
                            .contextMenu {
                                Button("Remove", role: .destructive) { model.removeBookmark(place) }
                            }
                            .onAppear { thumbnails.requestLocation(place, color: model.color) }
                    }
                }
                subheading("Curated")
                    .padding(.top, 2)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(showAll ? Location.all : Array(Location.all.prefix(PlacesSection.foldedCount))) { place in
                    PlaceTile(location: place, image: thumbnails.image(for: place)) { model.fly(to: place) }
                }
            }
            Button {
                withAnimation(.spring(duration: 0.35)) { showAll.toggle() }
            } label: {
                Text(showAll ? "Show fewer" : "Show all \(Location.all.count) places")
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } trailing: {
            Button { model.addBookmark() } label: {
                Label("Save view", systemImage: "plus")
                    .font(.rounded(11, .semibold))
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Save the current view to Your Places (B)")
        }
    }

    private func subheading(_ text: String) -> some View {
        Text(text)
            .font(.rounded(11, .semibold))
            .foregroundStyle(.secondary)
    }
}

/// Thumbnail tile of a place with its name and magnification; the formula is in the tooltip.
struct PlaceTile: View {
    let location: Location
    let image: NSImage?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35))
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity)
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Text(location.depthText)
                        .font(.rounded(10, .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(5)
                }
                .frame(height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(hover ? 0.35 : 0.08), lineWidth: 1))
                .scaleEffect(hover ? 1.03 : 1)
                Text(location.name)
                    .font(.rounded(12, .semibold))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
        .animation(.easeOut(duration: 0.3), value: image != nil)
        .help("\(location.name) · \(location.formula.displayName) · " + Magnification.text(location.zoom))
    }
}

/// Palettes, the escape-time mapping and the shading controls (folded under "Adjust").
struct ColorSection: View {
    @Bindable var model: AppModel
    @AppStorage("colour.adjust") private var adjusting = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 5)

    var body: some View {
        CollapsibleSection("Colour", id: "colour") {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Palette.all) { palette in
                    let selected = model.color.palette == palette.id
                    Button { model.setPalette(palette.id) } label: {
                        PaletteStrip(palette: palette)
                            .frame(height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(selected ? Color.white : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .help(palette.name)
                    .accessibilityLabel(palette.name)
                }
            }
            Picker("", selection: $model.color.mapping) {
                Text("Linear").tag(0)
                Text("Root").tag(1)
                Text("Log").tag(2)
                Text("Distance").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            SwitchRow("Animate colours", isOn: $model.cycleColors)
            if model.hdrAvailable {
                SwitchRow("HDR highlights", isOn: $model.hdr)
                    .help("Let the brightest parts glow beyond standard white on HDR displays")
            }
            DisclosureGroup(isExpanded: $adjusting.animation(.spring(duration: 0.35))) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledSlider(title: "Density", value: $model.color.density, range: 0.02...3, logarithmic: true)
                    LabeledSlider(title: "Phase", value: $model.color.offset, range: 0...1)
                    LabeledSlider(title: "Relief", value: $model.color.lightStrength, range: 0...1)
                    LabeledSlider(title: "Light angle", value: $model.color.lightAzimuth, range: -Double.pi...Double.pi)
                    LabeledSlider(title: "Edges", value: $model.color.edgeStrength, range: 0...1)
                }
                .padding(.top, 6)
            } label: {
                Text("Adjust")
                    .font(.rounded(12, .medium))
                    .foregroundStyle(.secondary)
            }
        } trailing: {
            Text(Palette.all[model.color.palette].name)
                .font(.rounded(11, .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// Quality preset and the iteration limit.
struct QualitySection: View {
    @Bindable var model: AppModel

    var body: some View {
        CollapsibleSection("Quality", id: "quality") {
            Picker("", selection: $model.quality) {
                ForEach(Quality.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Fast: no smoothing, loosest approximation · Balanced: 4× · High: 16× · Ultra: 64× smoothing with exact approximation")
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Iterations")
                        .font(.rounded(12, .medium))
                    Text(model.iteration.maxIter.formatted())
                        .font(.rounded(15, .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: model.iteration.maxIter)
                }
                Spacer()
                Button { model.scaleIterations(0.5) } label: { Image(systemName: "minus") }
                    .buttonStyle(.glass)
                    .help("Halve iterations ([)")
                    .accessibilityLabel("Halve iterations")
                Button { model.scaleIterations(2) } label: { Image(systemName: "plus") }
                    .buttonStyle(.glass)
                    .help("Double iterations (])")
                    .accessibilityLabel("Double iterations")
                Toggle("Auto", isOn: $model.iteration.autoIterations)
                    .font(.rounded(12, .medium))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
    }
}

/// Opens the export sheet and shows a running export's progress.
struct ExportSection: View {
    @Bindable var model: AppModel

    var body: some View {
        CollapsibleSection("Export", id: "export") {
            HStack(spacing: 8) {
                Button { model.openExport(.image) } label: {
                    Label("Image", systemImage: "photo").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button { model.openExport(.video) } label: {
                    Label("Zoom Video", systemImage: "film").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            if model.export.running {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.export.status)
                        Spacer()
                        Text(model.export.remainingTimeText)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.rounded(11, .medium))
                    ProgressView(value: model.export.progress).controlSize(.small)
                }
            }
        }
    }
}

/// A setting with its switch at the trailing edge, and optionally a line of detail below its title.
struct SwitchRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.rounded(12, .medium))
                if let detail {
                    Text(detail)
                        .font(.rounded(11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// A slider with its title and value, optionally on a logarithmic scale.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var logarithmic = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.rounded(12, .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: value < 10 ? "%.2f" : "%.0f", value))
                    .font(.rounded(11, .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if logarithmic {
                Slider(value: Binding(get: { log(value) }, set: { value = exp($0) }),
                       in: log(range.lowerBound)...log(range.upperBound))
                    .controlSize(.small)
            } else {
                Slider(value: $value, in: range).controlSize(.small)
            }
        }
    }
}

/// A palette's full cycle as a horizontal gradient.
struct PaletteStrip: View {
    let palette: Palette

    var body: some View {
        let colors = palette.swatchColors(count: 48).map { Color(red: $0.x, green: $0.y, blue: $0.z) }
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}
