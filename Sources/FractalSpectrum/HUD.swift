import SwiftUI
import FractalKit

/// The status bar at the bottom: magnification, iterations, frame rate, throughput and progress.
struct HUDBar: View {
    @Bindable var model: AppModel

    var body: some View {
        let status = model.status
        HStack(spacing: 16) {
            readout("scope", status.map { Magnification.text($0.view.zoomLog10) } ?? "—", "magnification")
            divider
            readout("arrow.triangle.2.circlepath", (status?.maxIter ?? model.iteration.maxIter).formatted(), "iterations")
            divider
            // measured only while the view moves
            readout("speedometer", status.map { $0.fps > 0 ? "\(Int($0.fps.rounded()))" : "—" } ?? "—", "fps")
            divider
            let rate = rateReadout(status?.iterationRate ?? 0)
            readout("bolt.fill", rate.value, rate.unit)
            divider
            HStack(spacing: 7) {
                ProgressRing(progress: status?.progress ?? 0, active: status?.stage != .done)
                    .frame(width: 14, height: 14)
                Text(stageText(status))
                    .font(.rounded(12, .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if model.autopilotEngaged {
                divider
                Label("Autopilot", systemImage: "airplane")
                    .font(.rounded(12, .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            if let since = model.recordingSince {
                divider
                TimelineView(.periodic(from: since, by: 1)) { timeline in
                    let seconds = Int(timeline.date.timeIntervalSince(since))
                    Label(String(format: "%d:%02d", seconds / 60, seconds % 60), systemImage: "record.circle.fill")
                        .font(.rounded(12, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .panelGlass(in: Capsule())
        .onTapGesture(count: 2) { model.copyCoordinates() }
        .help("Double-click to copy the coordinates")
    }

    private func readout(_ icon: String, _ value: String, _ caption: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.rounded(14, .semibold))
                    .monospacedDigit()
                Text(caption)
                    .font(.rounded(10, .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 16)
    }

    /// Iterations per second as a number and its unit in words ("7.3", "billion iter / s").
    private func rateReadout(_ rate: Double) -> (value: String, unit: String) {
        switch rate {
        case 1e15...: (String(format: "%.1f", rate / 1e15), "quadrillion iter / s")
        case 1e12...: (String(format: "%.1f", rate / 1e12), "trillion iter / s")
        case 1e9...: (String(format: "%.1f", rate / 1e9), "billion iter / s")
        case 1e6...: (String(format: "%.0f", rate / 1e6), "million iter / s")
        default: ("—", "iter / s")
        }
    }

    private func stageText(_ status: LiveRenderer.Status?) -> String {
        guard let status else { return "Starting" }
        if let referenceProgress = status.referenceProgress { return String(format: "Orbit %.0f%%", referenceProgress * 100) }
        return switch status.stage {
        case .preparing: status.stage.rawValue
        case .refining: String(format: "Refining %.0f%%", status.progress * 100)
        case .smoothing: "Smoothing \(status.samples)×"
        case .done: status.samples > 1 ? "Sharp · \(status.samples)×" : "Sharp"
        }
    }
}

/// Circular progress of the current refinement; a full green ring once done.
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

/// The round buttons at the top right.
struct TopControls: View {
    @Bindable var model: AppModel

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                control(model.autopilotEngaged ? "pause.fill" : "play.fill", model.autopilotEngaged ? "Stop autopilot (P)" : "Autopilot dive (P)") {
                    model.autopilotEngaged.toggle()
                }
                control(model.touring ? "stop.fill" : "sparkles", model.touring ? "Stop tour (T)" : "Guided tour (T)") {
                    model.toggleTour()
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
        .panelGlass(in: Circle(), interactive: true)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Card showing the tour's caption above the status bar.
struct CaptionCard: View {
    let caption: AppModel.Caption

    var body: some View {
        VStack(spacing: 6) {
            Text(caption.title)
                .font(.rounded(30, .bold))
            Text(caption.subtitle)
                .font(.rounded(17, .semibold))
                .foregroundStyle(.secondary)
            if !caption.fact.isEmpty {
                Text(caption.fact)
                    .font(.rounded(13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .panelGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}
