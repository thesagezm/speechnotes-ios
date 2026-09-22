import SwiftUI

enum AccentColorChoice: String, CaseIterable, Identifiable {
    case system
    case blue, indigo, purple, pink, red, orange, yellow, green, teal, mint, cyan

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .blue: return "Blue"
        case .indigo: return "Indigo"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .teal: return "Teal"
        case .mint: return "Mint"
        case .cyan: return "Cyan"
        }
    }

    var color: Color {
        switch self {
        case .system: return .accentColor
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .mint: return .mint
        case .cyan: return .cyan
        }
    }
}

final class AppTheme: ObservableObject {
    // NOTE: @AppStorage does NOT publish changes when stored inside an
    // ObservableObject — it only triggers view invalidation when the
    // property wrapper lives in a View/Scene. Using @Published + explicit
    // UserDefaults sync so the root `.accentColor(theme.accentColor)` and
    // `.preferredColorScheme(theme.colorScheme)` in SpeechnotesApp re-render
    // when the user changes these in AppearanceSettingsView.
    @Published var accentChoice: AccentColorChoice {
        didSet { UserDefaults.standard.set(accentChoice.rawValue, forKey: "accentColorChoice") }
    }
    @Published var appearance: String {
        didSet { UserDefaults.standard.set(appearance, forKey: "appAppearance") }
    }
    /// Reading-view text scale — 1.0 = 100%, range 0.75…1.5. Applied to the
    /// markdown preview's body font so users can size text for their eyes.
    @Published var previewTextScale: Double {
        didSet { UserDefaults.standard.set(previewTextScale, forKey: "previewTextScale") }
    }

    // MARK: - Reader spacing (user-tunable, v1.6.3)
    //
    // Three multipliers over the ReaderSpacing base constants, so the reader
    // can go from tight to airy without touching code. They ship at 1.0 over
    // bases that already moved to roomier values than the old hardcoded ones
    // (the "too crowded" report) — the sliders exist so the user can tune
    // further in either direction. @Published + explicit UserDefaults sync
    // (the same pattern as the accent: @AppStorage inside an ObservableObject
    // does not publish).

    /// Line spacing INSIDE paragraphs and quotes.
    @Published var readerLineSpacing: Double {
        didSet { UserDefaults.standard.set(readerLineSpacing, forKey: "readerLineSpacing") }
    }

    /// Space BETWEEN blocks — paragraph bottom padding, list row spacing,
    /// heading clearance. The "sentences are too close" knob.
    @Published var readerBlockSpacing: Double {
        didSet { UserDefaults.standard.set(readerBlockSpacing, forKey: "readerBlockSpacing") }
    }

    /// Table room — row height and cell padding. Its own knob with a wider
    /// range (up to 2×) because tables need visibly more air than paragraphs
    /// before they stop looking cramped.
    @Published var readerTableSpacing: Double {
        didSet { UserDefaults.standard.set(readerTableSpacing, forKey: "readerTableSpacing") }
    }

    enum AppearanceMode: String { case light = "light", dark = "dark", system = "system" }

    init() {
        let defaults = UserDefaults.standard
        accentChoice = AccentColorChoice(rawValue: defaults.string(forKey: "accentColorChoice") ?? "") ?? .system
        appearance = defaults.string(forKey: "appAppearance") ?? "system"
        previewTextScale = defaults.object(forKey: "previewTextScale") as? Double ?? 1.0
        readerLineSpacing = defaults.object(forKey: "readerLineSpacing") as? Double ?? 1.0
        readerBlockSpacing = defaults.object(forKey: "readerBlockSpacing") as? Double ?? 1.0
        readerTableSpacing = defaults.object(forKey: "readerTableSpacing") as? Double ?? 1.0
    }

    /// Restores the three spacing knobs to their defaults (Appearance →
    /// Reset spacing).
    func resetReaderSpacing() {
        readerLineSpacing = 1.0
        readerBlockSpacing = 1.0
        readerTableSpacing = 1.0
    }

    var accentColor: Color { accentChoice.color }

    /// Accent → translucent-accent fade for buttons, play glyphs and the
    /// progress ring. Hardcoding a second hue (e.g. .purple) fought 11 of
    /// the 12 accent choices — everything accent-tinted derives from the
    /// chosen color now.
    var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accentColor, accentColor.opacity(0.5)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Horizontal variant for progress bars.
    var accentFadeGradient: LinearGradient {
        LinearGradient(
            colors: [accentColor, accentColor.opacity(0.5)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Top-down variant for the landscape rail's vertical progress strip —
    /// the strip fills from the TOP (progress runs the direction a page
    /// fills), so the fade runs top→bottom. (The portrait bars keep the
    /// left→right accentFadeGradient.)
    var accentFadeVerticalGradient: LinearGradient {
        LinearGradient(
            colors: [accentColor, accentColor.opacity(0.5)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case AppearanceMode.light.rawValue: return .light
        case AppearanceMode.dark.rawValue: return .dark
        default: return nil
        }
    }
}
