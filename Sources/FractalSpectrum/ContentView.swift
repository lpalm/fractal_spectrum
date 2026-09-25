import SwiftUI
import FractalKit

/// The window: the fractal filling it, with glass controls, notices and overlays on top.
struct ContentView: View {
    @Bindable var model: AppModel
    @State private var thumbnails = Thumbnails()

    var body: some View {
        ZStack {
            FractalCanvas(model: model)
                .ignoresSafeArea()

            if model.showUI {
                HStack(alignment: .top, spacing: 0) {
                    Sidebar(model: model, thumbnails: thumbnails)
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
                GeometryReader { canvas in
                    JuliaInset(hover: hover, formula: model.formula, color: model.color, canvas: canvas.size)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }

            VStack {
                if let toast = model.toast {
                    Text(toast)
                        .font(.rounded(15, .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .panelGlass(in: Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 18)
                }
                Spacer()
            }
            .allowsHitTesting(false)
            .animation(.spring(duration: 0.35), value: model.toast)

            if let caption = model.caption {
                VStack {
                    Spacer()
                    CaptionCard(caption: caption)
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
            thumbnails.requestAll()
        }
    }
}
