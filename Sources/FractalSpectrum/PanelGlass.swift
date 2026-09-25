import SwiftUI

extension View {
    /// Glass for panels floating over the fractal, dimmed so that their text stays legible over its
    /// brightest colours.
    func panelGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        background(.black.opacity(0.28), in: shape)
            .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    }
}
