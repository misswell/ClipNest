#if os(macOS)
import SwiftUI

/// The desktop counterpart of the iPhone's Timeline tab: a day-grouped chronology of every
/// Markdown note in the vault, compacted for the side bar. It reads the same refresh-time
/// snapshot as the home screen, so opening it never triggers another filesystem scan.
/// Clicking a row selects the note, which opens it in an editor tab.
struct TimelineSidebar: View {
    @EnvironmentObject var store: VaultStore
    @State private var sections: [TimelineDaySection] = []
    @State private var isPreparing = false
    @State private var preparedSnapshotRevision: UInt64?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(VSCode.border)
            content
        }
        .frame(maxHeight: .infinity)
        .background(VSCode.sidebarBg)
        .task(id: TimelineReloadID(treeRevision: store.treeRevision,
                                   snapshotRevision: store.homeSnapshotRevision)) {
            await reloadIfNeeded()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("TIMELINE")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(VSCode.muted)
                .tracking(0.6)
            Spacer()
            if isPreparing {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else {
                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(VSCode.muted)
                }
                .buttonStyle(.plain)
                .help("Refresh the timeline")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 35)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if store.rootURL == nil {
            sidebarHint("Open a vault to see its notes here, newest first.")
        } else if sections.isEmpty && (isPreparing || store.isHomeSnapshotLoading) {
            sidebarHint("Preparing timeline…")
        } else if sections.isEmpty {
            sidebarHint("No Markdown notes yet. New notes appear here in chronological order.")
        } else {
            list
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections) { section in
                    Text(section.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(VSCode.muted)
                        .tracking(0.4)
                        .padding(.horizontal, 12)
                        .padding(.top, section.id == sections.first?.id ? 8 : 14)
                        .padding(.bottom, 4)

                    ForEach(section.items) { item in
                        // The click lives here, not in the row: rows stay plain Equatable
                        // views and the environment-owned store is only touched in the list.
                        Button {
                            store.selectedFileURL = item.url
                        } label: {
                            TimelineSidebarRow(
                                item: item,
                                relativePath: relativePath(for: item.url),
                                isLast: item.url == section.items.last?.url
                            )
                            .equatable()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func sidebarHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(VSCode.muted)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func relativePath(for url: URL) -> String {
        guard let rootURL = store.rootURL else { return url.lastPathComponent }
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    /// Rebuild the day sections only when the snapshot revision moved on, off the main
    /// actor — the same discipline as the iPhone's Timeline tab.
    private func reloadIfNeeded() async {
        let snapshotRevision = store.homeSnapshotRevision
        guard preparedSnapshotRevision != snapshotRevision else { return }

        let items = store.homeSnapshot.timelineItems
        guard !items.isEmpty else {
            sections = []
            preparedSnapshotRevision = snapshotRevision
            isPreparing = false
            return
        }

        isPreparing = true
        let worker = Task.detached(priority: .utility) {
            TimelineDaySection.make(from: items)
        }
        let built = await withTaskCancellationHandler(operation: {
            await worker.value
        }, onCancel: {
            worker.cancel()
        })

        guard let built, !Task.isCancelled else { return }
        sections = built
        preparedSnapshotRevision = snapshotRevision
        isPreparing = false
    }
}

private struct TimelineReloadID: Equatable {
    let treeRevision: UInt64
    let snapshotRevision: UInt64
}

struct TimelineDaySection: Identifiable, Sendable {
    let day: Date?
    let items: [VaultTimelineItem]

    var id: String {
        day.map { String($0.timeIntervalSinceReferenceDate) } ?? "unknown-date"
    }

    var title: String {
        guard let day else { return "Unknown Date" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    /// The home snapshot is already newest-first; grouping it linearly avoids extra
    /// dictionary and per-section sort work on large vaults.
    static func make(from items: [VaultTimelineItem]) -> [TimelineDaySection]? {
        guard !items.isEmpty else { return [] }

        let calendar = Calendar.autoupdatingCurrent
        var sections: [TimelineDaySection] = []
        sections.reserveCapacity(min(items.count, 365))
        var currentDay: Date?
        var currentItems: [VaultTimelineItem] = []
        currentItems.reserveCapacity(16)

        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return nil }
            let day = item.date == .distantPast ? nil : calendar.startOfDay(for: item.date)
            if !currentItems.isEmpty, day != currentDay {
                sections.append(TimelineDaySection(day: currentDay, items: currentItems))
                currentItems.removeAll(keepingCapacity: true)
            }
            currentDay = day
            currentItems.append(item)
        }

        if !currentItems.isEmpty {
            sections.append(TimelineDaySection(day: currentDay, items: currentItems))
        }
        return sections
    }
}

/// One compact timeline row: violet dot + connector line, note title, time and folder.
/// Purely visual — the wrapping Button in the list owns the selection action.
private struct TimelineSidebarRow: View, Equatable {
    let item: VaultTimelineItem
    let relativePath: String
    let isLast: Bool

    @State private var hovering = false

    // Hover state is deliberately excluded: the row only needs re-rendering when its data
    // changes, and hovering already re-renders through @State directly.
    static func == (lhs: TimelineSidebarRow, rhs: TimelineSidebarRow) -> Bool {
        lhs.item == rhs.item && lhs.relativePath == rhs.relativePath && lhs.isLast == rhs.isLast
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(VSCode.accent)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .frame(width: 10)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(hovering ? VSCode.activeIcon : VSCode.fg)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(timeLabel)
                    Text(relativePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 10))
                .foregroundStyle(VSCode.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(hovering ? VSCode.hoverBg : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .overlay(alignment: .topLeading) {
            if !isLast {
                TimelineSidebarConnector()
                    .stroke(VSCode.accent.opacity(0.25), lineWidth: 1)
                    .frame(width: 10)
                    .allowsHitTesting(false)
            }
        }
    }

    private var timeLabel: String {
        guard item.date != .distantPast else { return "Unknown time" }
        return item.date.formatted(date: .omitted, time: .shortened)
    }
}

private struct TimelineSidebarConnector: Shape {
    func path(in rect: CGRect) -> Path {
        guard rect.height > 7 else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: 7))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
#endif
