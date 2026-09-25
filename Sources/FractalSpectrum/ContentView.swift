import SwiftUI
import FractalKit

/// Full-bleed fractal canvas with floating glass controls.
struct ContentView: View {
    @Bindable var model: AppModel
    @State private var thumbs = Thumbnails()

    var body: some View {
        ZStack {
            FractalCanvas(model: model)
                .ignoresSafeArea()

            if model.showUI {
                HStack(alignment: .top, spacing: 0) {
                    Sidebar(model: model, thumbs: thumbs)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Spacer(minLength: 0)
                    TopControls(model: model)
                }
                .padding(14)

                VStack {
                    Spacer()
                    HUDBar(model: model)
                        .padding(.bottom, 16)
                }
                .transition(.opacity)
            }

            VStack {
                if let t = model.toast {
                    Text(t)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 18)
                }
                Spacer()
            }
            .allowsHitTesting(false)
            .animation(.spring(duration: 0.35), value: model.toast)

            if model.showHelp {
                HelpOverlay(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.spring(duration: 0.4), value: model.showUI)
        .animation(.easeOut(duration: 0.2), value: model.showHelp)
        .preferredColorScheme(.dark)
        .onAppear {
            for f in FractalFamily.allCases {
                thumbs.requestFamily(Formula(family: f), color: model.color)
            }
            thumbs.requestFamily(Formula(family: .mandelbrot, power: 3), color: model.color)
            for l in Location.all { thumbs.requestLocation(l, color: model.color) }
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Bindable var model: AppModel
    let thumbs: Thumbnails

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                header
                FractalSection(model: model, thumbs: thumbs)
                LocationsSection(model: model, thumbs: thumbs)
                ColorSection(model: model)
                QualitySection(model: model)
            }
            .padding(16)
        }
        .frame(width: 304)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Spectrum")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("fractal explorer")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            PaletteStrip(palette: Palette.all[model.color.palette])
                .frame(height: 5)
                .clipShape(Capsule())
                .animation(.easeInOut(duration: 0.4), value: model.color.palette)
        }
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Spacer()
            trailing
        }
    }
}

struct FractalSection: View {
    @Bindable var model: AppModel
    let thumbs: Thumbnails

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Fractal")
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(FractalFamily.allCases) { f in
                    let key = "family-\(f.rawValue)-2"
                    Tile(title: f.displayName, image: thumbs.image(key),
                         selected: model.formula.family == f) {
                        model.selectFamily(f, power: f == .mandelbrot ? 2 : nil)
                    }
                }
            }
            if model.formula.family == .mandelbrot {
                HStack(spacing: 6) {
                    Text("Power")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    ForEach(2...8, id: \.self) { p in
                        Button {
                            model.selectFamily(.mandelbrot, power: p)
                        } label: {
                            Text("\(p)")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .frame(width: 24, height: 22)
                                .background(model.formula.effectivePower == p ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Toggle(isOn: Binding(get: { model.formula.julia }, set: { v in if v != model.formula.julia { model.toggleJulia() } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Julia set")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text(model.formula.julia
                             ? String(format: "c = %.5f %+.5fi", model.formula.juliaRe, model.formula.juliaIm)
                             : "⌥-click the set to pick c")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }
}

struct Tile: View {
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
                .frame(height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.white.opacity(hover ? 0.3 : 0.08),
                                      lineWidth: selected ? 2 : 1)
                )
                .scaleEffect(hover ? 1.02 : 1)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium, design: .rounded))
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

struct LocationsSection: View {
    @Bindable var model: AppModel
    let thumbs: Thumbnails

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Explore")
            ForEach(Location.all) { l in
                LocationRow(location: l, image: thumbs.image("loc-\(l.id)")) { model.fly(to: l) }
            }
        }
    }
}

struct LocationRow: View {
    let location: Location
    let image: NSImage?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.35))
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(location.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(location.formula.displayName)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(location.depthText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .padding(6)
            .background(hover ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct ColorSection: View {
    @Bindable var model: AppModel
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Colour")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Palette.all) { p in
                    Button { model.setPalette(p.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            PaletteStrip(palette: p)
                                .frame(height: 16)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(model.color.palette == p.id ? Color.white : Color.white.opacity(0.1),
                                                  lineWidth: model.color.palette == p.id ? 2 : 1))
                            Text(p.name)
                                .font(.system(size: 11, weight: model.color.palette == p.id ? .semibold : .regular, design: .rounded))
                                .foregroundStyle(model.color.palette == p.id ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Picker("", selection: $model.color.mapping) {
                Text("Linear").tag(0)
                Text("Root").tag(1)
                Text("Log").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            LabeledSlider(title: "Density", value: $model.color.density, range: 0.02...3, log: true)
            LabeledSlider(title: "Phase", value: $model.color.offset, range: 0...1)
            LabeledSlider(title: "Relief", value: $model.color.lightStrength, range: 0...1)
            LabeledSlider(title: "Light angle", value: $model.color.lightAzimuth, range: -Double.pi...Double.pi)
            LabeledSlider(title: "Edges", value: $model.color.edgeStrength, range: 0...1)
            Toggle("Animate colours", isOn: $model.cycleColors)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

struct QualitySection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Quality")
            Picker("", selection: $model.quality) {
                ForEach(Quality.allCases) { q in Text(q.rawValue).tag(q) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Iterations")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                    Text(model.iter.maxIter.formatted())
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: model.iter.maxIter)
                }
                Spacer()
                Button { model.scaleIterations(0.5) } label: { Image(systemName: "minus") }
                    .buttonStyle(.glass)
                Button { model.scaleIterations(2) } label: { Image(systemName: "plus") }
                    .buttonStyle(.glass)
                Toggle("Auto", isOn: $model.iter.autoIterations)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var log = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: value < 10 ? "%.2f" : "%.0f", value))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            if log {
                Slider(value: Binding(get: { Foundation.log(value) }, set: { value = exp($0) }),
                       in: Foundation.log(range.lowerBound)...Foundation.log(range.upperBound))
                    .controlSize(.small)
            } else {
                Slider(value: $value, in: range).controlSize(.small)
            }
        }
    }
}

struct PaletteStrip: View {
    let palette: Palette

    var body: some View {
        let cols = PaletteBank.swatch(palette, count: 48).map { Color(red: $0.x, green: $0.y, blue: $0.z) }
        LinearGradient(colors: cols, startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - HUD

struct HUDBar: View {
    @Bindable var model: AppModel

    var body: some View {
        let s = model.status
        HStack(spacing: 16) {
            item("scope", s?.view.zoomText ?? "—", "zoom")
            divider
            item("arrow.triangle.2.circlepath", (s?.maxIter ?? model.iter.maxIter).formatted(), "iterations")
            divider
            item("speedometer", "\(Int(s?.fps ?? 0))", "fps")
            divider
            HStack(spacing: 7) {
                ProgressRing(progress: s?.progress ?? 0, active: (s?.stage ?? "") != "Done")
                    .frame(width: 14, height: 14)
                Text(stageText(s))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if model.autopilot {
                divider
                Label("Autopilot", systemImage: "airplane")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .onTapGesture(count: 2) { model.copyCoordinates() }
        .help("Double-click to copy the coordinates")
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 16)
    }

    private func stageText(_ s: LiveRenderer.Status?) -> String {
        guard let s else { return "Starting" }
        if let r = s.referenceProgress { return String(format: "Orbit %.0f%%", r * 100) }
        switch s.stage {
        case "Refining": return String(format: "Refining %.0f%%", s.progress * 100)
        case "Smoothing": return "Smoothing \(s.samples)×"
        case "Done": return s.samples > 1 ? "Sharp · \(s.samples)×" : "Sharp"
        default: return s.stage
        }
    }

    private func item(_ icon: String, _ value: String, _ caption: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(caption)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct ProgressRing: View {
    let progress: Double
    let active: Bool

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: active ? max(0.04, progress) : 1)
                .stroke(active ? Color.accentColor : Color.green.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.2), value: progress)
        }
    }
}

struct TopControls: View {
    @Bindable var model: AppModel

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                control(model.autopilot ? "pause.fill" : "play.fill", model.autopilot ? "Stop autopilot (P)" : "Autopilot dive (P)") {
                    model.autopilot.toggle()
                }
                control("house.fill", "Home (H)") { model.goHome() }
                control("questionmark", "Shortcuts") { model.showHelp.toggle() }
                control("eye.slash", "Hide interface (Space)") { model.showUI = false }
            }
        }
    }

    private func control(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(help)
    }
}

struct HelpOverlay: View {
    @Bindable var model: AppModel

    private let rows: [(String, String)] = [
        ("Drag / two-finger scroll", "Pan"),
        ("Scroll wheel / pinch / ⌘-scroll", "Zoom at pointer"),
        ("Double-click / ⌥ double-click", "Zoom in / out"),
        ("Right-click", "Zoom out"),
        ("Rotate gesture · Q / E", "Rotate"),
        ("⌥-click", "Julia set at point"),
        ("J", "Toggle Julia set"),
        ("C / X", "Next / previous palette"),
        ("[ / ]", "Halve / double iterations"),
        ("L", "Relief lighting"),
        ("P", "Autopilot dive"),
        ("H", "Home"),
        ("F", "Full screen"),
        ("Space", "Hide interface"),
        ("⇧⌘C", "Copy coordinates"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Shortcuts")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Button { model.showHelp = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.glass)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                ForEach(rows, id: \.0) { r in
                    GridRow {
                        Text(r.0)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text(r.1)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
