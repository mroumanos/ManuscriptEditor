// AppTheme.swift
//
// App-wide appearance + editor typography.
//
// APPEARANCE
// ─────────────────────────────────────────────────────────────────────────────
// `AppearanceMode` is persisted in UserDefaults under "appearance" and applied
// at the app root via `.preferredColorScheme`.  "System" follows macOS.
//
// TYPOGRAPHY
// ─────────────────────────────────────────────────────────────────────────────
// The prose editors read three shared settings — font family, point size, and
// line spacing — so changing them in Preferences restyles every editor at once.
// `EditorTypography` centralises the mapping from those stored values to SwiftUI
// `Font` and line-spacing points.

import SwiftUI

// MARK: - AppearanceMode

/// The user's chosen colour scheme.  `system` defers to macOS.
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// The SwiftUI scheme to force, or `nil` to follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - Shared preference keys & defaults

/// Central definition of the editor preference keys and their default values so
/// every `@AppStorage` declaration agrees.
enum EditorPrefs {
    static let appearanceKey = "appearance"
    static let fontKey       = "defaultFont"      // "Serif" | "Sans" | "Mono"
    static let fontSizeKey   = "editorFontSize"
    static let lineSpacingKey = "lineSpacing"     // multiplier 1.0…2.5
    /// App-wide citation format (RefEngine.CitationStyle raw code).
    static let citationStyleKey = "defaultCitationStyle"
    /// Personal display zoom over the document typography (Phase 2:
    /// editors render the journal's export format; zoom is view-only).
    static let zoomKey = "editorZoom"
    static let defaultZoom = 1.4

    static let defaultFont       = "Sans"   // clean system sans (SF Pro), Inter-like
    static let defaultFontSize   = 17.0
    static let defaultLineSpacing = 1.5
}

// MARK: - EditorTypography

/// Resolves the stored editor preferences into concrete SwiftUI values.
struct EditorTypography {
    var family: String
    var size: Double
    var lineSpacingMultiplier: Double

    /// Reads the live values from UserDefaults (used where `@AppStorage` is awkward).
    static var current: EditorTypography {
        let d = UserDefaults.standard
        return EditorTypography(
            family: d.string(forKey: EditorPrefs.fontKey) ?? EditorPrefs.defaultFont,
            size: d.object(forKey: EditorPrefs.fontSizeKey) as? Double ?? EditorPrefs.defaultFontSize,
            lineSpacingMultiplier: d.object(forKey: EditorPrefs.lineSpacingKey) as? Double ?? EditorPrefs.defaultLineSpacing
        )
    }

    var font: Font {
        switch family {
        case "Sans": return .system(size: size)
        case "Mono": return .system(size: size, design: .monospaced)
        default:     return .system(size: size, design: .serif)
        }
    }

    /// Extra points between lines derived from the multiplier and point size.
    var lineSpacingPoints: CGFloat {
        CGFloat((lineSpacingMultiplier - 1.0) * size)
    }
}
