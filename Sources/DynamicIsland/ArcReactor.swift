import SwiftUI

/// Static concentric-ring mark. Intensity is driven by the notch spring, never
/// by a repeating animation - a pulsing glow would keep the GPU awake forever.
struct ArcReactor: View {
    var size: CGFloat
    var intensity: Double

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.gold.opacity(0.25 + 0.35 * intensity), lineWidth: size * 0.045)
            Circle()
                .inset(by: size * 0.13)
                .strokeBorder(Theme.core.opacity(0.30 + 0.50 * intensity), lineWidth: size * 0.07)
            Circle()
                .inset(by: size * 0.30)
                .fill(Theme.core.opacity(0.55 + 0.45 * intensity))
                .blur(radius: size * (0.03 + 0.03 * intensity))
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .shadow(color: Theme.core.opacity(0.6 * intensity), radius: size * 0.12 * intensity)
    }
}
