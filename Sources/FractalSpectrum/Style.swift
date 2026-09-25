import SwiftUI

extension View {
    /// Glass for panels floating over the fractal, dimmed so that their text stays legible over its
    /// brightest colours.
    func panelGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        background(.black.opacity(0.28), in: shape)
            .glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    }
}

extension Font {
    /// The interface's typeface, SF Pro Rounded.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
