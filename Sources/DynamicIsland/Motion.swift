import AppKit
import SwiftUI

/// Motion and interaction tokens. Every value here is a deliberate choice, not a
/// default - keeping them in one place is what makes them defensible.
enum Motion {
    /// True when the user asked for less movement. Checked at call time rather
    /// than cached, so a change in System Settings takes effect immediately.
    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var reducedTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    /// The island changing size. Slight underdamping so it reads as an object
    /// with mass rather than a box being resized - this is the one place bounce
    /// is earned, because the shape is standing in for a physical thing.
    static var morph: Animation {
        reduced
            ? .easeOut(duration: 0.2)
            : .spring(response: 0.34, dampingFraction: 0.78)
    }

    /// Content swapping inside the island. Critically damped: overshoot on text
    /// that merely faded in feels wrong.
    static var content: Animation {
        reduced
            ? .easeOut(duration: 0.12)
            : .spring(response: 0.26, dampingFraction: 1.0)
    }

    /// Exit is faster than enter - the user has already decided, so the system
    /// should get out of the way.
    static var exit: Animation {
        reduced ? .easeOut(duration: 0.1) : .spring(response: 0.2, dampingFraction: 1.0)
    }

    /// Hover and press feedback. Short enough to feel instant.
    static let press: Animation = .easeOut(duration: 0.12)
    static let hover: Animation = .easeOut(duration: 0.14)

    /// Cascade for rows entering the expanded panel. Kept short - long stagger
    /// reads as slow, not elegant.
    static func stagger(_ index: Int) -> Double {
        reduced ? 0 : Double(index) * 0.035
    }

    /// Trackpad tick when the island opens. Force Touch only; a no-op elsewhere.
    static func tick() {
        guard !reduced else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

/// Press feedback for every control in the island.
///
/// Buttons that do not visibly respond to being pressed read as broken, and the
/// response has to land on press - waiting for the click to complete feels dead.
struct Pressable: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

extension View {
    /// Hover highlight, gated so it never fires from a touch-style tap.
    func hoverHighlight(_ isHovering: Binding<Bool>) -> some View {
        onHover { hovering in
            withAnimation(Motion.hover) { isHovering.wrappedValue = hovering }
        }
    }
}
