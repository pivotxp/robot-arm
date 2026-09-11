import UIKit

/// Lightweight haptic feedback helpers.
///
/// Used to make taps "feel" instant — UI animation alone often reads as laggy
/// even when frame timing is fine. A 10ms impact tells the user "registered."
enum Haptics {
    static func light()  { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func heavy()  { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    static func soft()   { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func rigid()  { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }

    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success()   { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning()   { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error()     { UINotificationFeedbackGenerator().notificationOccurred(.error) }

    /// Pre-warm generators so the first impact isn't ~50ms late on cold start.
    static func warmUp() {
        UIImpactFeedbackGenerator(style: .light).prepare()
        UIImpactFeedbackGenerator(style: .medium).prepare()
        UIImpactFeedbackGenerator(style: .heavy).prepare()
        UISelectionFeedbackGenerator().prepare()
        UINotificationFeedbackGenerator().prepare()
    }
}
