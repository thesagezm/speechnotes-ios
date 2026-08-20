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
    @AppStorage("accentColorChoice") var accentChoice: AccentColorChoice = .system
    @AppStorage("appAppearance") var appearance: String = "system" // "light", "dark", "system"

    enum AppearanceMode: String { case light = "light", dark = "dark", system = "system" }

    var accentColor: Color { accentChoice.color }

    var colorScheme: ColorScheme? {
        switch appearance {
        case AppearanceMode.light.rawValue: return .light
        case AppearanceMode.dark.rawValue: return .dark
        default: return nil
        }
    }
}
