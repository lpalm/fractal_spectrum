import Foundation
import FractalKit

extension Location {
    /// Stops of the guided tour, in order.
    static let tourIDs = ["seahorse", "galaxy", "crown", "twin", "garden", "ancient", "abyss", "edge", "armada", "cathedral",
                          "dragon", "dragonheart", "rabbit"]
}

/// The guided tour: flies from stop to stop, captioning each with a sense of its scale.
extension AppModel {
    func toggleTour() {
        if touring { stopTour() } else { startTour() }
    }

    func startTour() {
        stopTour()
        autopilot = false
        touring = true
        tourTask = Task { @MainActor [weak self] in
            let stops = Location.tourIDs.compactMap { id in Location.all.first { $0.id == id } }
            for stop in stops {
                guard let self, touring, !Task.isCancelled else { return }
                caption = nil
                fly(to: stop, announce: false)
                try? await Task.sleep(for: .milliseconds(300))
                while camera.isFlying && touring && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard touring, !Task.isCancelled else { return }
                caption = Caption(title: stop.name, subtitle: "Magnified " + ScaleFact.magnification(stop.zoom),
                                  fact: ScaleFact.describe(zoomLog10: stop.zoom))
                try? await Task.sleep(for: .seconds(stop.zoom > 50 ? 7 : 5))
            }
            guard let self, touring else { return }
            caption = nil
            touring = false
            goHome()
        }
    }

    func stopTour() {
        touring = false
        tourTask?.cancel()
        tourTask = nil
        caption = nil
    }
}
