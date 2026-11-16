import AppKit
import SwiftUI

enum SenseiAccent: CaseIterable, Sendable {
    case cyan
    case indigo
    case emerald
    case amber
    case coral
    case violet

    var primaryColor: Color {
        switch self {
        case .cyan:
            return Color(red: 0.16, green: 0.80, blue: 0.96)
        case .indigo:
            return Color(red: 0.40, green: 0.46, blue: 0.98)
        case .emerald:
            return Color(red: 0.16, green: 0.84, blue: 0.62)
        case .amber:
            return Color(red: 0.98, green: 0.73, blue: 0.20)
        case .coral:
            return Color(red: 0.98, green: 0.38, blue: 0.44)
        case .violet:
            return Color(red: 0.68, green: 0.42, blue: 0.98)
        }
    }

    var secondaryColor: Color {
        switch self {
        case .cyan:
            return Color(red: 0.22, green: 0.56, blue: 0.98)
        case .indigo:
            return Color(red: 0.58, green: 0.36, blue: 0.98)
        case .emerald:
            return Color(red: 0.10, green: 0.68, blue: 0.76)
        case .amber:
            return Color(red: 0.96, green: 0.50, blue: 0.18)
        case .coral:
            return Color(red: 0.92, green: 0.24, blue: 0.52)
        case .violet:
            return Color(red: 0.46, green: 0.36, blue: 0.96)
        }
    }

    private static let nsCyanPrimary = NSColor(srgbRed: 0.16, green: 0.80, blue: 0.96, alpha: 1.0)
    private static let nsIndigoPrimary = NSColor(srgbRed: 0.40, green: 0.46, blue: 0.98, alpha: 1.0)
    private static let nsEmeraldPrimary = NSColor(srgbRed: 0.16, green: 0.84, blue: 0.62, alpha: 1.0)
    private static let nsAmberPrimary = NSColor(srgbRed: 0.98, green: 0.73, blue: 0.20, alpha: 1.0)
    private static let nsCoralPrimary = NSColor(srgbRed: 0.98, green: 0.38, blue: 0.44, alpha: 1.0)
    private static let nsVioletPrimary = NSColor(srgbRed: 0.68, green: 0.42, blue: 0.98, alpha: 1.0)

    private static let nsCyanSecondary = NSColor(srgbRed: 0.22, green: 0.56, blue: 0.98, alpha: 1.0)
    private static let nsIndigoSecondary = NSColor(srgbRed: 0.58, green: 0.36, blue: 0.98, alpha: 1.0)
    private static let nsEmeraldSecondary = NSColor(srgbRed: 0.10, green: 0.68, blue: 0.76, alpha: 1.0)
    private static let nsAmberSecondary = NSColor(srgbRed: 0.96, green: 0.50, blue: 0.18, alpha: 1.0)
    private static let nsCoralSecondary = NSColor(srgbRed: 0.92, green: 0.24, blue: 0.52, alpha: 1.0)
    private static let nsVioletSecondary = NSColor(srgbRed: 0.46, green: 0.36, blue: 0.96, alpha: 1.0)

    var primaryNSColor: NSColor {
        switch self {
        case .cyan: return Self.nsCyanPrimary
        case .indigo: return Self.nsIndigoPrimary
        case .emerald: return Self.nsEmeraldPrimary
        case .amber: return Self.nsAmberPrimary
        case .coral: return Self.nsCoralPrimary
        case .violet: return Self.nsVioletPrimary
        }
    }

    var secondaryNSColor: NSColor {
        switch self {
        case .cyan: return Self.nsCyanSecondary
        case .indigo: return Self.nsIndigoSecondary
        case .emerald: return Self.nsEmeraldSecondary
        case .amber: return Self.nsAmberSecondary
        case .coral: return Self.nsCoralSecondary
        case .violet: return Self.nsVioletSecondary
        }
    }

    var gradient: LinearGradient {
        LinearGradient(
            colors: [primaryColor, secondaryColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var ringAngularGradient: AngularGradient {
        AngularGradient(
            gradient: Gradient(colors: [primaryColor, secondaryColor, primaryColor]),
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360)
        )
    }
}

struct SenseiPalette {
    static func colorScheme(for mode: AppThemeMode) -> ColorScheme? {
        switch mode {
        case .system:
            return nil
        case .darkGraphite:
            return .dark
        case .lightFrost:
            return .light
        }
    }

    static func specularBorderGradient(for scheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(scheme == .dark ? 0.14 : 0.68),
                Color.white.opacity(scheme == .dark ? 0.04 : 0.20)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func cardSurfaceTint(for scheme: ColorScheme, opacity: Double) -> Color {
        if scheme == .dark {
            return Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.54 * opacity)
        } else {
            return Color.white.opacity(0.64 * opacity)
        }
    }
}

extension View {
    func senseiMonospacedNumeric() -> some View {
        self.monospacedDigit()
    }
}
