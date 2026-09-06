import SwiftUI

/// One shared toast presenter — small, non-blocking status lines ("Deleted —
/// Undo", "Imported to Books") with an optional action. The app-wide
/// alternative to alert() for *successes and confirmations*; failures that
/// need an explicit dismissal keep using alerts.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let actionTitle: String?
        let action: (() -> Void)?

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var current: Toast?

    private var dismissTask: Task<Void, Never>?

    /// Shows (or replaces) the toast. A replacement restarts the timer —
    /// rapid events never stack.
    func show(
        _ message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        duration: TimeInterval = 2.5
    ) {
        dismissTask?.cancel()
        current = Toast(message: message, actionTitle: actionTitle, action: action)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }
}

/// Root-window toast surface. Anchored above the mini-player / tab-bar zone.
/// Uses `ToastCenter.shared` directly (no environment dependency) so it can
/// sit anywhere on the root chain; attach it next to `.globalMiniPlayer()`.
struct AppToastOverlay: ViewModifier {
    @ObservedObject private var toasts = ToastCenter.shared

    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content
            if let toast = toasts.current {
                HStack(spacing: 12) {
                    Text(toast.message)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2)
                    if let actionTitle = toast.actionTitle {
                        Button {
                            toasts.dismiss()
                            toast.action?()
                        } label: {
                            Text(actionTitle)
                                .font(.footnote.bold())
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(
                    Capsule()
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                )
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.06))
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 102)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: toasts.current)
    }
}

extension View {
    func appToasts() -> some View { modifier(AppToastOverlay()) }
}
