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

            if let orbit = model.orbitHover {
                OrbitOverlay(orbit: orbit)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if let hover = model.juliaHover {
                GeometryReader { geo in
                    JuliaInset(hover: hover, formula: model.formula, color: model.color, canvas: geo.size)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
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

            if let c = model.caption {
                VStack {
                    Spacer()
                    CaptionCard(caption: c)
                        .padding(.bottom, model.showUI ? 86 : 40)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .allowsHitTesting(false)
            }

            if model.showHelp {
                HelpOverlay(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .sheet(isPresented: $model.showExport) {
            ExportSheet(model: model, export: model.export)
        }
        .sheet(isPresented: $model.showGoTo) {
            GoToSheet(model: model)
        }
        .animation(.spring(duration: 0.4), value: model.showUI)
        .animation(.easeOut(duration: 0.2), value: model.showHelp)
        .animation(.spring(duration: 0.6), value: model.caption)
        .preferredColorScheme(.dark)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                model.show("Scroll to zoom · T for a guided tour · ? for shortcuts", duration: 4)
            }
            for f in FractalFamily.allCases {
                var c = ColorSettings()
                c.palette = [.mandelbrot: 0, .tricorn: 4, .burningShip: 7, .celtic: 2][f] ?? 0
                thumbs.requestFamily(Formula(family: f), color: c)
            }
            for l in Location.all { thumbs.requestLocation(l, color: ColorSettings()) }
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
                ExportSection(model: model)
            }
            .padding(16)
        }
        .frame(width: 304)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer().frame(height: 14)   // clear the window's traffic-light buttons
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

/// Sidebar section whose expanded state persists across launches.
struct CollapsibleSection<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @AppStorage private var expanded: Bool
    @ViewBuilder let content: () -> Content

    init(_ title: String, id: String, expandedByDefault: Bool = true, trailing: AnyView? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = trailing
        _expanded = AppStorage(wrappedValue: expandedByDefault, "section.\(id)")
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if expanded { trailing }
            }
            if expanded {
                content()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct FractalSection: View {
    @Bindable var model: AppModel
    let thumbs: Thumbnails

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        CollapsibleSection("Fractal", id: "fractal") {
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
                             : "Hold ⌥ over the set to preview, click to pick c")
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
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        CollapsibleSection("Explore", id: "explore", trailing: AnyView(
            Button { model.addBookmark() } label: {
                Label("Save view", systemImage: "plus")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Save the current view to Your Places (B)")
        )) {
            if !model.bookmarks.isEmpty {
                Text("Your Places")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(model.bookmarks) { l in
                        PlaceTile(location: l, image: thumbs.image("loc-\(l.id)")) { model.fly(to: l) }
                            .contextMenu {
                                Button("Remove", role: .destructive) { model.removeBookmark(l) }
                            }
                            .onAppear { thumbs.requestLocation(l, color: model.color) }
                    }
                }
                Text("Curated")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Location.all) { l in
                    PlaceTile(location: l, image: thumbs.image("loc-\(l.id)")) { model.fly(to: l) }
                }
            }
        }
    }
}

/// Thumbnail tile of a place with its name and magnification.
struct PlaceTile: View {
    let location: Location
    let image: NSImage?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
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
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(5)
                }
                .frame(height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(hover ? 0.35 : 0.08), lineWidth: 1))
                .scaleEffect(hover ? 1.03 : 1)
                Text(location.name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(location.formula.displayName)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
        .animation(.easeOut(duration: 0.3), value: image != nil)
        .help(location.name + " · " + ScaleFact.magnification(location.zoom))
    }
}

struct ColorSection: View {
    @Bindable var model: AppModel
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        CollapsibleSection("Colour", id: "colour") {
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
                Text("Distance").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            LabeledSlider(title: "Density", value: $model.color.density, range: 0.02...3, log: true)
            LabeledSlider(title: "Phase", value: $model.color.offset, range: 0...1)
            LabeledSlider(title: "Relief", value: $model.color.lightStrength, range: 0...1)
            LabeledSlider(title: "Light angle", value: $model.color.lightAzimuth, range: -Double.pi...Double.pi)
            LabeledSlider(title: "Edges", value: $model.color.edgeStrength, range: 0...1)
            if model.hdrAvailable {
                Toggle("HDR highlights", isOn: $model.hdr)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Let the brightest parts glow beyond standard white on HDR displays")
            }
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
        CollapsibleSection("Quality", id: "quality") {
            Picker("", selection: $model.quality) {
                ForEach(Quality.allCases) { q in Text(q.rawValue).tag(q) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Fast: no smoothing, loosest approximation · Balanced: 4× · High: 16× · Ultra: 64× smoothing with exact approximation")
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
                    .help("Halve iterations ([)")
                    .accessibilityLabel("Halve iterations")
                Button { model.scaleIterations(2) } label: { Image(systemName: "plus") }
                    .buttonStyle(.glass)
                    .help("Double iterations (])")
                    .accessibilityLabel("Double iterations")
                Toggle("Auto", isOn: $model.iter.autoIterations)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
    }
}

struct ExportSection: View {
    @Bindable var model: AppModel

    var body: some View {
        CollapsibleSection("Export", id: "export") {
            HStack(spacing: 8) {
                Button {
                    model.export.kind = .image
                    model.showExport = true
                } label: {
                    Label("Image", systemImage: "photo").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button {
                    model.export.kind = .video
                    model.showExport = true
                } label: {
                    Label("Zoom Video", systemImage: "film").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            if model.export.running {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.export.status).font(.system(size: 11, weight: .medium, design: .rounded))
                    ProgressView(value: model.export.progress).controlSize(.small)
                }
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
            item("scope", s.map { ScaleFact.magnification($0.view.zoomLog10) } ?? "—", "magnification")
            divider
            item("arrow.triangle.2.circlepath", (s?.maxIter ?? model.iter.maxIter).formatted(), "iterations")
            divider
            // measured only while the view moves
            item("speedometer", s.map { $0.fps > 0 ? "\(Int($0.fps.rounded()))" : "—" } ?? "—", "fps")
            divider
            item("bolt.fill", rateText(s?.iterationRate ?? 0), "effective iter / s")
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
            if let since = model.recordingSince {
                divider
                TimelineView(.periodic(from: since, by: 1)) { t in
                    let s = Int(t.date.timeIntervalSince(since))
                    Label(String(format: "%d:%02d", s / 60, s % 60), systemImage: "record.circle.fill")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .onTapGesture(count: 2) { model.copyCoordinates() }
        .help("Double-click to copy the coordinates")
    }

    private func rateText(_ r: Double) -> String {
        switch r {
        case 1e15...: return String(format: "%.1f P", r / 1e15)
        case 1e12...: return String(format: "%.1f T", r / 1e12)
        case 1e9...: return String(format: "%.1f G", r / 1e9)
        case 1e6...: return String(format: "%.0f M", r / 1e6)
        default: return "—"
        }
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
                control(model.touring ? "stop.fill" : "sparkles", model.touring ? "Stop tour (T)" : "Guided tour (T)") {
                    if model.touring { model.stopTour() } else { model.startTour() }
                }
                control("scope", "Find a mini-Mandelbrot in view (M)") { model.findMinibrot() }
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
        .accessibilityLabel(help)
    }
}

struct CaptionCard: View {
    let caption: AppModel.Caption

    var body: some View {
        VStack(spacing: 6) {
            Text(caption.title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text(caption.subtitle)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            if !caption.fact.isEmpty {
                Text(caption.fact)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// Paste coordinates (as copied with ⇧⌘C, or "re im zoom") and fly there.
struct GoToSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Go to Coordinates")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("Paste \"re: … im: … zoom: …\" as copied with ⇧⌘C, or three numbers: real, imaginary, log₁₀ zoom.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if failed {
                Text("Couldn't read coordinates from that text.")
                    .font(.system(size: 12, design: .rounded))
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

struct HelpOverlay: View {
    @Bindable var model: AppModel

    private let rows: [(String, String)] = [
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
                    .font(.system(size: 20, weight: .bold, design: .rounded))
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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func column(_ part: ArraySlice<(String, String)>) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            ForEach(part, id: \.0) { r in
                GridRow {
                    Text(r.0)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(r.1)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
