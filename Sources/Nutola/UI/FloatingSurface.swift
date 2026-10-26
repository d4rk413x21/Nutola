import SwiftUI

/// Glass belongs to floating controls; expanded readers keep an opaque text surface.
private struct FloatingSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let shape: S
    var opaque: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if opaque || reduceTransparency || contrast == .increased {
            content
                .background(Theme.panel(scheme), in: shape)
                .overlay { shape.strokeBorder(.primary.opacity(contrast == .increased ? 0.5 : 0.12)) }
                .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    func floatingSurface(in shape: some InsettableShape, opaque: Bool = false) -> some View {
        modifier(FloatingSurface(shape: shape, opaque: opaque))
    }
}
