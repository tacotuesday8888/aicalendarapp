import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum AppTheme {
    static var background: Color {
        dynamicColor(
            light: UIColor(red: 0.93, green: 0.96, blue: 1.00, alpha: 1.0),
            dark: UIColor(red: 0.08, green: 0.09, blue: 0.14, alpha: 1.0)
        )
    }

    static var backgroundTop: Color {
        dynamicColor(
            light: UIColor(red: 0.95, green: 0.98, blue: 1.00, alpha: 1.0),
            dark: UIColor(red: 0.12, green: 0.14, blue: 0.22, alpha: 1.0)
        )
    }

    static var backgroundBottom: Color {
        dynamicColor(
            light: UIColor(red: 0.84, green: 0.91, blue: 0.98, alpha: 1.0),
            dark: UIColor(red: 0.10, green: 0.17, blue: 0.24, alpha: 1.0)
        )
    }

    static var surface: Color {
        dynamicColor(
            light: UIColor.white.withAlphaComponent(0.18),
            dark: UIColor.white.withAlphaComponent(0.08)
        )
    }

    static var primary: Color {
        dynamicColor(
            light: UIColor(red: 0.12, green: 0.42, blue: 0.88, alpha: 1.0),
            dark: UIColor(red: 0.39, green: 0.67, blue: 0.98, alpha: 1.0)
        )
    }

    static var accent: Color {
        dynamicColor(
            light: UIColor(red: 0.09, green: 0.73, blue: 0.67, alpha: 1.0),
            dark: UIColor(red: 0.18, green: 0.80, blue: 0.73, alpha: 1.0)
        )
    }

    static var textPrimary: Color {
        dynamicColor(
            light: UIColor(red: 0.08, green: 0.12, blue: 0.22, alpha: 1.0),
            dark: UIColor(red: 0.90, green: 0.93, blue: 0.98, alpha: 1.0)
        )
    }

    static var textSecondary: Color {
        dynamicColor(
            light: UIColor(red: 0.34, green: 0.42, blue: 0.55, alpha: 1.0),
            dark: UIColor(red: 0.63, green: 0.69, blue: 0.80, alpha: 1.0)
        )
    }

    static var border: Color {
        dynamicColor(
            light: UIColor.white.withAlphaComponent(0.34),
            dark: UIColor.white.withAlphaComponent(0.14)
        )
    }

    static var glassHighlight: Color {
        dynamicColor(
            light: UIColor.white.withAlphaComponent(0.62),
            dark: UIColor.white.withAlphaComponent(0.20)
        )
    }

    static var glassShadow: Color {
        dynamicColor(
            light: UIColor(red: 0.17, green: 0.24, blue: 0.39, alpha: 0.14),
            dark: UIColor.black.withAlphaComponent(0.34)
        )
    }

    static let screenPadding: CGFloat = 20
    static let cardCornerRadius: CGFloat = 20
    static let controlCornerRadius: CGFloat = 14

    #if canImport(UIKit)
    private static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
        Color(
            uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            }
        )
    }
    #else
    private static func dynamicColor(light: Any, dark: Any) -> Color {
        Color.white
    }
    #endif
}
