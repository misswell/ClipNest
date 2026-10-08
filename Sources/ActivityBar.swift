#if os(macOS)
import SwiftUI
import AppKit

/// The sections selectable from the activity bar that drive the side bar content.
enum ActivityItem: String, CaseIterable, Identifiable {
    case explorer, timeline, search, extensions
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .explorer:   return "doc.on.doc"
        case .timeline:   return "clock"
        case .search:     return "magnifyingglass"
        case .extensions: return "square.grid.2x2"
        }
    }
    var help: String {
        switch self {
        case .explorer:   return String(localized: "Explorer")
        case .timeline:   return String(localized: "Timeline")
        case .search:     return String(localized: "Search")
        case .extensions: return String(localized: "Extensions")
        }
    }
}

/// VS Code's far-left vertical icon strip. Selecting the active item toggles the side bar.
struct ActivityBar: View {
    @Binding var selection: ActivityItem
    @Binding var sidebarVisible: Bool
    var onSettings: () -> Void

    var body: some View {
        VStack(spacing: AppMetrics.DesktopNavigation.spacing) {
            ForEach(ActivityItem.allCases) { item in
                itemButton(item)
            }
            Spacer()
            AccountButton()
            bottomButton("gearshape", help: String(localized: "Settings"), action: onSettings)
        }
        .padding(.vertical, AppMetrics.DesktopNavigation.verticalInset)
        .frame(width: AppMetrics.DesktopNavigation.railWidth)
        .frame(maxHeight: .infinity)
        .background(VSCode.activityBg)
        .overlay(alignment: .trailing) {
            Rectangle().fill(VSCode.border).frame(width: 1)
        }
    }

    private func itemButton(_ item: ActivityItem) -> some View {
        let isActive = selection == item && sidebarVisible
        return Button {
            if selection == item {
                sidebarVisible.toggle()
            } else {
                selection = item
                sidebarVisible = true
            }
        } label: {
            ActivityBarIcon(icon: item.icon, isActive: isActive)
        }
        .buttonStyle(.plain)
        .help(item.help)
        .accessibilityLabel(item.help)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func bottomButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ActivityBarIcon(icon: icon)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One label for navigation, account and settings controls, including pointer feedback.
private struct ActivityBarIcon: View {
    let icon: String
    var isActive = false
    @State private var isHovered = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: AppMetrics.DesktopNavigation.iconSize, weight: .regular))
            .foregroundStyle(isActive || isHovered ? VSCode.activeIcon : VSCode.muted)
            .frame(width: AppMetrics.DesktopNavigation.buttonSize,
                   height: AppMetrics.DesktopNavigation.buttonSize)
            .background(isActive ? VSCode.fieldBg : (isHovered ? VSCode.hoverBg : Color.clear),
                        in: RoundedRectangle(cornerRadius: AppMetrics.DesktopNavigation.cornerRadius))
            .frame(width: AppMetrics.DesktopNavigation.railWidth)
            .overlay(alignment: .leading) {
                if isActive {
                    Capsule()
                        .fill(VSCode.activeIcon)
                        .frame(width: AppMetrics.DesktopNavigation.indicatorWidth,
                               height: AppMetrics.DesktopNavigation.indicatorHeight)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

/// VS Code-style "Accounts" menu — shows the Mac's iCloud sign-in status and a shortcut
/// to manage the Apple Account in System Settings.
private struct AccountButton: View {
    private var signedIn: Bool { FileManager.default.ubiquityIdentityToken != nil }

    var body: some View {
        Menu {
            Section("Accounts") {
                Label(signedIn ? String(localized: "iCloud — Signed In") : String(localized: "iCloud — Not Signed In"),
                      systemImage: signedIn ? "checkmark.icloud" : "icloud.slash")
                    .disabled(true)
            }
            Divider()
            if signedIn {
                Button("Manage Apple Account…") { openAppleIDSettings() }
            } else {
                Button("Sign In to iCloud…") { openAppleIDSettings() }
            }
            Button("iCloud Settings…") { openICloudSettings() }
        } label: {
            ActivityBarIcon(icon: "person.crop.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(signedIn ? String(localized: "Accounts — iCloud Signed In") : String(localized: "Accounts"))
        .accessibilityLabel(String(localized: "Accounts"))
    }

    private func openAppleIDSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
            NSWorkspace.shared.open(url)
        }
    }
    private func openICloudSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane?iCloud") {
            NSWorkspace.shared.open(url)
        }
    }
}
#endif
