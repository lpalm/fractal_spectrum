import SwiftUI

extension View {
    /// Glass for panels floating over the fractal, tinted dark so that their text stays legible over
    /// its brightest colours.
    func panelGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        let glass = Glass.regular.tint(.black.opacity(0.3))
        return glassEffect(interactive ? glass.interactive() : glass, in: shape)
    }
}
