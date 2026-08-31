import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// How the app icon is chosen: follow the system light/dark appearance, or pin one.
enum AppIconPreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "Follow System")
        case .light: return String(localized: "Light Icon")
        case .dark: return String(localized: "Dark Icon")
        }
    }

    /// Compiled alternate app-icon set name (`Assets.xcassets`) for a pinned choice.
    var alternateIconName: String? {
        switch self {
        case .system: return nil
        case .light: return "AppIconDay"
        case .dark: return "AppIconNight"
        }
    }
}

/// Applies the icon preference. On iOS this goes through the system alternate-icon API
/// (the OS persists the choice and shows a confirmation alert when it changes). On macOS
/// there is no public alternate-icon API, so the Dock icon is swapped at runtime, the
/// choice persists in UserDefaults, and `.system` tracks the appearance live via KVO.
enum AppIconManager {
    static let storageKey = "app.iconPreference"

    static var current: AppIconPreference {
        #if os(iOS)
        guard let name = UIApplication.shared.alternateIconName else { return .system }
        return AppIconPreference.allCases.first { $0.alternateIconName == name } ?? .system
        #else
        let raw = UserDefaults.standard.string(forKey: storageKey)
        return raw.flatMap(AppIconPreference.init) ?? .system
        #endif
    }

    static func set(_ preference: AppIconPreference) {
        #if os(iOS)
        guard preference.alternateIconName != UIApplication.shared.alternateIconName else { return }
        UIApplication.shared.setAlternateIconName(preference.alternateIconName) { error in
            if let error {
                NSLog("ClipNest: switching app icon failed — \(error.localizedDescription)")
            }
        }
        #else
        UserDefaults.standard.set(preference.rawValue, forKey: storageKey)
        applyMacDockIcon(preference)
        #endif
    }

    #if os(macOS)
    private static var launchIcon: NSImage?
    private static var appearanceObservation: NSKeyValueObservation?

    /// Apply the stored preference when the app launches. The macOS bundle icon is the
    /// dark design, so every mode needs a runtime pass: pinned modes pick their icon and
    /// `.system` follows the current appearance (and keeps following via KVO).
    static func applyStoredMacIcon() {
        let app = NSApplication.shared
        if launchIcon == nil { launchIcon = app.applicationIconImage }
        if appearanceObservation == nil {
            appearanceObservation = app.observe(\.effectiveAppearance) { _, _ in
                guard AppIconManager.current == .system else { return }
                applyAppearanceMatchingMacIcon()
            }
        }
        applyMacDockIcon(current)
    }

    private static func applyMacDockIcon(_ preference: AppIconPreference) {
        switch preference {
        case .system:
            applyAppearanceMatchingMacIcon()
        case .light:
            NSApplication.shared.applicationIconImage = macIcon(named: "IconDay")
        case .dark:
            NSApplication.shared.applicationIconImage = macIcon(named: "IconNight")
        }
    }

    private static func applyAppearanceMatchingMacIcon() {
        let appearance = NSApplication.shared.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSApplication.shared.applicationIconImage = macIcon(named: isDark ? "IconNight" : "IconDay")
    }

    private static func macIcon(named name: String) -> NSImage? {
        NSImage(named: name) ?? launchIcon
    }
    #endif
}
