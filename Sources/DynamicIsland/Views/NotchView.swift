import SwiftUI

struct NotchView: View {
    @Bindable var state: NotchState
    @Namespace private var morph

    var body: some View {
        let shape = NotchShape(topRadius: state.topRadius, bottomRadius: state.bottomRadius)
        let expanded = state.mode == .expanded
        let showIdle = state.idleVisible
        // Read here and passed down, which looks like ceremony and is not.
        // `HUD` is `@Observable`, but a read of `current` from inside
        // `ExpandedView` - or from the `Receipt` below it - never registered as
        // a dependency: measured, one body evaluation at open and no second one
        // when the value changed, so the receipt stayed permanently empty. Read
        // from this body it registers, because this is the body that already
        // observes `HUD` through `state.size` while collapsed. Move it back down
        // and the receipt silently stops appearing.
        let receipt = HUD.shared.current

        ZStack {
            background(shape, expanded: expanded, showIdle: showIdle)

            ZStack {
                if expanded {
                    ExpandedView(state: state, morph: morph, receipt: receipt)
                        .transition(.opacity)
                } else if showIdle {
                    CollapsedView(state: state, morph: morph)
                        .transition(.opacity)
                }
            }
            // Blur bridges the two states during the swap. Without it the eye
            // reads two separate objects overlapping instead of one changing.
            .blur(radius: state.swapping && !Motion.reduced ? 3 : 0)
            .clipShape(shape)
        }
        // `alignment: .top` is load-bearing, not decoration. A fixed frame in
        // SwiftUI *centres* a child that does not fit, so a tab whose content
        // was taller than the island split the overflow evenly and pushed the
        // header upward - straight under the physical notch, where the bezel
        // hides it. Measured: home wanted 237pt in a 218pt island and the header
        // rendered at y = -9.5. Pinned to the top, overflow can only ever go
        // downward, where `clipped()` deals with it.
        .frame(width: state.size.width, height: state.size.height, alignment: .top)
        // The closed island grows for a live activity; spring it rather than
        // letting the frame jump.
        .animation(Motion.morph, value: state.size)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Collapsed is either true black - so it vanishes into the physical cutout -
    /// or nothing at all. Expanded is a translucent dark material, which reads as
    /// a surface hanging off the notch rather than a rectangle on the screen.
    @ViewBuilder
    private func background(_ shape: NotchShape, expanded: Bool, showIdle: Bool) -> some View {
        if expanded {
            ZStack {
                if Motion.reducedTransparency {
                    shape.fill(Theme.shell)
                } else {
                    shape.fill(.black.opacity(0.72))
                        .background(shape.fill(.ultraThinMaterial))
                }
                // ponytail: one flat hairline. The gradient rim that used to sit
                // under it read as a halo around the notch rather than an edge.
                shape.stroke(Theme.edge, lineWidth: 0.5)
            }
            // The shadow belongs to the shape, not to everything drawn in it.
            // Cast by the whole island, it was recomputed from the contents
            // every time anything inside changed - the sound graph twenty times
            // a second, the stats every second. Measured with the graph
            // running: about three points of CPU, for a shadow that looks the same.
            .shadow(color: .black.opacity(0.55), radius: 22, y: 10)
        } else if showIdle {
            shape.fill(Theme.notchBlack)
        }
    }
}
