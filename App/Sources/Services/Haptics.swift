import UIKit

/// Haptic feedback helpers.
///
/// Round-3 device feedback: "haptics are super laggy". The one-shot
/// generators allocated a new `UIFeedbackGenerator` on EVERY call — allocation
/// plus the first impact without a prepared generator is exactly the
/// "half a mississippi" delay on device. The generators are now cached for
/// the app's lifetime and `prepare()` fires before each impact so the Taptic
/// engine is warm for the next tap too.
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)
    private static let notification = UINotificationFeedbackGenerator()

    static func tap() {
        light.prepare()
        light.impactOccurred()
    }

    static func press() {
        medium.prepare()
        medium.impactOccurred()
    }

    static func success() {
        notification.prepare()
        notification.notificationOccurred(.success)
    }

    static func warning() {
        notification.prepare()
        notification.notificationOccurred(.warning)
    }
}
