#if os(macOS)
import SwiftUI

enum AdjustmentInterfaceMode: String, CaseIterable, Identifiable {
    case quick
    case basic
    case advanced
    case debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quick: return "Quick"
        case .basic: return "Basic"
        case .advanced: return "Advanced"
        case .debug: return "Debug"
        }
    }

    var systemImage: String {
        switch self {
        case .quick: return "bolt"
        case .basic: return "slider.horizontal.3"
        case .advanced: return "dial.high"
        case .debug: return "ladybug"
        }
    }

    var summary: String {
        switch self {
        case .quick:
            return "Fast film conversion with only profile choice and the most useful finishing controls."
        case .basic:
            return "Essential photographic controls plus simplified film character and detail adjustments."
        case .advanced:
            return "Complete film, print, optical, scanner, color, and engine controls using progressive disclosure."
        case .debug:
            return "The full sidebar, including internal diagnostics, taps, and implementation controls."
        }
    }
}

enum PreviewCompareMode: String, CaseIterable, Identifiable {
    case click
    case hold
    case beforeAfterSlider

    var id: String { rawValue }

    var title: String {
        switch self {
        case .click: return "Click to compare"
        case .hold: return "Hold to compare"
        case .beforeAfterSlider: return "Before/after slider"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum PreviewBackground: String, CaseIterable, Identifiable {
    case gray
    case black
    case white

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gray: return "Mid-gray"
        case .black: return "Black"
        case .white: return "White"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .gray: return NSColor(srgbRed: 0.466, green: 0.466, blue: 0.466, alpha: 1)
        case .black: return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case .white: return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }
}

enum AdjustmentInterfacePreferences {
    static let modeKey = "adjustmentInterfaceMode"
    static let soloPanelsKey = "adjustmentInspectorSoloPanels"
    static let debugModeKey = "adjustmentDebugMode"
    static let compareModeKey = "previewCompareMode"
    static let appearanceKey = "appAppearance"
    static let previewBackgroundKey = "previewBackground"
    static let defaultMode = AdjustmentInterfaceMode.basic.rawValue
}
#endif
