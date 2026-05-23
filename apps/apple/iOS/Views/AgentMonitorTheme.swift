import SwiftUI

enum AgentMonitorTheme {
    static let darkPrimary = Color(red: 0.05, green: 0.05, blue: 0.06)
    static let darkSecondary = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let darkTertiary = Color(red: 0.17, green: 0.17, blue: 0.18)

    static let lightPrimary = Color.white
    static let lightSecondary = Color(red: 0.98, green: 0.98, blue: 0.99)
    static let lightTertiary = Color(red: 0.95, green: 0.95, blue: 0.97)

    static func backgroundGradient(for colorScheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [darkPrimary, darkSecondary]
                : [lightPrimary, lightSecondary],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func pageBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkPrimary : lightSecondary
    }

    static func surface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkSecondary : lightPrimary
    }

    static func elevatedSurface(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkTertiary : lightPrimary
    }

    static func softFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.055)
    }

    static func separator(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    static func cardShadow(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.black.opacity(0.18) : Color.black.opacity(0.045)
    }
}

extension Animation {
    static let agentThemeChange = Animation.easeInOut(duration: 0.28)
    static let agentSpring = Animation.spring(response: 0.52, dampingFraction: 0.82, blendDuration: 0)
}
