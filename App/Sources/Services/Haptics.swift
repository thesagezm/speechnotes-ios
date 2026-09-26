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

    /// User-controlled kill switch (Appearance → Haptic feedback, v1.7 round
    /// 5). Read per call — a toggle in Settings takes effect immediately.
    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
    }

    static func tap() {
        guard enabled else { return }
        light.prepare()
        light.impactOccurred()
    }

    static func press() {
        guard enabled else { return }
        medium.prepare()
        medium.impactOccurred()
    }

    static func success() {
        guard enabled else { return }
        notification.prepare()
        notification.notificationOccurred(.success)
    }

    static func warning() {
        guard enabled else { return }
        notification.prepare()
        notification.notificationOccurred(.warning)
    }
}
