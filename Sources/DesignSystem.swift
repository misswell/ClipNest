import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Single source of truth for layout metrics. Every screen uses these instead of ad-hoc
/// numbers so the iPhone/iPad/macOS surfaces line up on the same grid.
///
/// Keep the values in sync with `Theme.AppCard`: a card is `cardPadding` inside a
/// `cardRadius` continuous corner, and screens sit `screenHorizontal` from the edge.
enum AppMetrics {
    static let screenHorizontal: CGFloat = 20
    static let screenTop: CGFloat = 16

    static let sectionSpacing: CGFloat = 24
    static let rowSpacing: CGFloat = 12

    static let cardPadding: CGFloat = 16
    static let cardRadius: CGFloat = 16

    /// Vertical padding for a tappable settings/row entry.
    static let rowVertical: CGFloat = 13

    static let toolbarIconSize: CGFloat = 17
    static let rowIconSize: CGFloat = 18

    /// Minimum tappable side for any standalone control (Apple HIG).
    static let controlHitSize: CGFloat = 44

    static let fabSize: CGFloat = 56
    static let fabInset: CGFloat = 20

    /// Height of the bottom strip reserved for the iOS 26 floating tab bar. Content that
    /// scrolls under the tab bar must not receive taps there; see
    /// `BottomInteractionExclusionZone`.
    static let tabBarProtectionHeight: CGFloat = 80

    static let contentMaxWidth: CGFloat = 720

    /// iPad / regular width gets a slightly roomier gutter; iPhone stays at 20.
    static func screenHorizontal(for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? 24 : screenHorizontal
    }
}

// MARK: - Interaction isolation

/// Swallows taps in the strip occupied by the floating iOS tab bar.
///
/// The system tab bar is drawn above the tab's content, but content (a note row, a timeline
/// row) can scroll underneath it. A tap that lands on the tab bar while the *content* still
/// hit-tests there would otherwise activate the row below — which is exactly how tapping
/// "Vault" while already on Vault used to open a note. This view sits in that strip as a
/// transparent, always-hit-testable shape so the touch is consumed before it reaches a row.
///
/// It consumes taps only: a scroll gesture that starts here still scrolls the content.
struct BottomInteractionExclusionZone: View {
    var height: CGFloat = AppMetrics.tabBarProtectionHeight

    var body: some View {
        // iPadOS draws the tab bar at the top, so protecting the bottom strip there would only
        // add dead scroll space. Only iPhone-style layouts need it.
        if Self.tabBarSitsAtBottom {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .contentShape(Rectangle())
                .onTapGesture {
                    // Deliberately consume the tap so it cannot reach a row underneath.
                }
                .accessibilityHidden(true)
        }
    }

    private static var tabBarSitsAtBottom: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }
}

extension View {
    /// Reserves the tab-bar strip at the bottom of a scroll surface and blocks touches there.
    func bottomTabBarExclusion() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            BottomInteractionExclusionZone()
        }
    }
}

// MARK: - Shared components

/// One visual + hit-area spec for every navigation-bar icon, including the labels of
/// `Menu`-backed bar items that cannot use `AppToolbarIconButton` directly.
struct AppToolbarIconStyle: ViewModifier {
    var isSelected = false
    var tint: Color = Theme.ink

    func body(content: Content) -> some View {
        content
            .font(.system(size: AppMetrics.toolbarIconSize, weight: .semibold))
            .foregroundStyle(isSelected ? Theme.accent : tint)
            .frame(width: AppMetrics.controlHitSize, height: AppMetrics.controlHitSize)
            .contentShape(Rectangle())
    }
}

extension View {
    func appToolbarIcon(isSelected: Bool = false, tint: Color = Theme.ink) -> some View {
        modifier(AppToolbarIconStyle(isSelected: isSelected, tint: tint))
    }
}

/// A navigation-bar icon button with one consistent visual size and hit area.
///
/// The 44×44 frame matches UIKit's own bar-button geometry, so it does not grow the bar;
/// it only guarantees that every toolbar icon is at least as easy to hit as the system's.
struct AppToolbarIconButton: View {
    let systemImage: String
    var role: ButtonRole? = nil
    var isSelected = false
    var tint: Color = Theme.ink
    var label: String
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .appToolbarIcon(isSelected: isSelected, tint: tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A leading icon on a list/timeline row, sized and hit-tested consistently.
struct AppRowIcon: View {
    let systemImage: String
    var tint: Color = Theme.accent

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: AppMetrics.rowIconSize, weight: .regular))
            .foregroundStyle(tint)
            .frame(width: AppMetrics.rowIconSize, height: AppMetrics.rowIconSize)
    }
}

/// Section heading used by every card on the home / settings surfaces.
struct AppSectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(Theme.ink)
    }
}
