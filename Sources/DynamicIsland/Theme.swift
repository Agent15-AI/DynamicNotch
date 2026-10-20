import SwiftUI

/// Hot-rod red, black and gold. Original colours - no Marvel assets.
enum Theme {
    /// Must match the physical cutout exactly, or the collapsed island shows an
    /// outline against it.
    static let notchBlack = Color.black
    /// Warm-shifted off-black so the panel sits with the reds rather than the
    /// blue-grey it used to.
    static let shell = Color(red: 0.055, green: 0.045, blue: 0.045)
    static let core = Color(red: 0.878, green: 0.204, blue: 0.165)   // hot-rod red
    static let gold = Color(red: 0.914, green: 0.725, blue: 0.204)

    /// Text laid on a filled `core` swatch. White holds up on this red; black
    /// lands under 4.5:1 at the small sizes used here.
    static let onCore = Color.white

    /// Only ever used on the expanded panel, never on the collapsed island.
    static let edge = Color.white.opacity(0.08)
    /// A brighter top edge reads as light catching the material.
    static let edgeHighlight = Color.white.opacity(0.16)

    // MARK: - Text

    /// Text over a translucent surface needs more contrast and a touch more
    /// weight than text on a solid one, or it disappears into the background.
    static let primary = Color.white.opacity(0.95)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.40)
}

/// Type scale. Tracking is size-specific by design: small text needs a little
/// positive tracking to stay legible, and larger text needs it pulled back in.
enum TypeScale {
    static func label(_ size: CGFloat = 10) -> Font { .system(size: size, weight: .semibold, design: .monospaced) }
    static let labelTracking: CGFloat = 1.5

    static let title = Font.system(size: 13, weight: .semibold)
    static let titleTracking: CGFloat = -0.1

    static let body = Font.system(size: 11.5)
    static let bodyTracking: CGFloat = 0.05

    static let caption = Font.system(size: 9.5)
    static let captionTracking: CGFloat = 0.2

    static let mono = Font.system(size: 10, design: .monospaced)
}

extension View {
    /// Section heading used across the tabs.
    func sectionLabel() -> some View {
        font(TypeScale.label())
            .tracking(TypeScale.labelTracking)
            .foregroundStyle(Theme.core)
    }
}
