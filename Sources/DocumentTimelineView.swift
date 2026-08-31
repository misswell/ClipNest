import SwiftUI

/// A chronological view of every Markdown document in the open vault. It reads the same
/// refresh-time snapshot as the home screen, so switching tabs does not trigger another
/// recursive filesystem scan or a document-body read.
struct DocumentTimelineView: View {
    @EnvironmentObject private var store: VaultStore
    @State private var navigationPath = NavigationPath()
    @State private var timelineSections: [TimelineSection] = []
    @State private var isPreparingTimeline = false
    @State private var preparedSnapshotRevision: UInt64?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if store.rootURL == nil {
                    ContentUnavailableView(
                        "No Vault",
                        systemImage: "folder.badge.questionmark",
                        description: Text("Open a vault from the Vault tab to see its documents here.")
                    )
                } else if timelineSections.isEmpty && (isPreparingTimeline || store.isHomeSnapshotLoading) {
                    ProgressView("Preparing Timeline…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if timelineSections.isEmpty {
                    ContentUnavailableView(
                        "No Markdown Notes",
                        systemImage: "clock",
                        description: Text("Markdown documents will appear here in chronological order.")
                    )
                } else {
                    timelineList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .navigationTitle("Timeline")
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        store.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh Timeline")
                }
            }
            .navigationDestination(for: URL.self) { url in
                MarkdownEditorView(url: url)
            }
        }
        .task {
            store.restoreVaultIfNeeded()
        }
        .task(id: TimelineReloadID(treeRevision: store.treeRevision,
                                   snapshotRevision: store.homeSnapshotRevision)) {
            let snapshotRevision = store.homeSnapshotRevision
            guard preparedSnapshotRevision != snapshotRevision else { return }

            let items = store.homeSnapshot.timelineItems
            guard !items.isEmpty else {
                timelineSections = []
                preparedSnapshotRevision = snapshotRevision
                isPreparingTimeline = false
                return
            }

            isPreparingTimeline = true
            let worker = Task.detached(priority: .utility) {
                TimelineSectionBuilder.make(from: items)
            }
            let sections = await withTaskCancellationHandler(operation: {
                await worker.value
            }, onCancel: {
                worker.cancel()
            })

            guard let sections, !Task.isCancelled else { return }
            timelineSections = sections
            preparedSnapshotRevision = snapshotRevision
            isPreparingTimeline = false
        }
    }

    private var timelineList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(timelineSections) { section in
                    Text(section.title)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                        .padding(.top, section.id == timelineSections.first?.id ? 0 : 24)
                        .padding(.bottom, 10)

                    ForEach(section.items) { item in
                        Button {
                            store.selectedFileURL = item.url
                            navigationPath.append(item.url)
                        } label: {
                            TimelineDocumentRow(
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
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
    }

    private func relativePath(for url: URL) -> String {
        guard let rootURL = store.rootURL else { return url.lastPathComponent }
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(filePath.dropFirst(rootPath.count + 1))
    }
}

private struct TimelineReloadID: Equatable {
    let treeRevision: UInt64
    let snapshotRevision: UInt64
}

private struct TimelineSection: Identifiable, Sendable {
    let day: Date?
    let items: [VaultTimelineItem]

    var id: String {
        day.map { String($0.timeIntervalSinceReferenceDate) } ?? "unknown-date"
    }

    var title: String {
        guard let day else { return "Unknown Date" }
        return day.formatted(date: .complete, time: .omitted)
    }
}

/// The home snapshot is already newest-first. Grouping it linearly avoids the extra dictionary,
/// per-section sort, and temporary allocations that become noticeable with a large vault.
private enum TimelineSectionBuilder {
    static func make(from items: [VaultTimelineItem]) -> [TimelineSection]? {
        guard !items.isEmpty else { return [] }

        let calendar = Calendar.autoupdatingCurrent
        var sections: [TimelineSection] = []
        sections.reserveCapacity(min(items.count, 365))
        var currentDay: Date?
        var currentItems: [VaultTimelineItem] = []
        currentItems.reserveCapacity(16)

        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return nil }
            let day = item.date == .distantPast ? nil : calendar.startOfDay(for: item.date)
            if !currentItems.isEmpty, day != currentDay {
                sections.append(TimelineSection(day: currentDay, items: currentItems))
                currentItems.removeAll(keepingCapacity: true)
            }
            currentDay = day
            currentItems.append(item)
        }

        if !currentItems.isEmpty {
            sections.append(TimelineSection(day: currentDay, items: currentItems))
        }
        return sections
    }
}

private struct TimelineDocumentRow: View, Equatable {
    let item: VaultTimelineItem
    let relativePath: String
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 11, height: 11)
                .overlay {
                    Circle()
                        .strokeBorder(Theme.background, lineWidth: 3)
                }
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.url.deletingPathExtension().lastPathComponent)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(timeLabel)
                    Text(relativePath)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(Theme.mutedInk)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.hairline)
            }
        }
        .contentShape(Rectangle())
        .padding(.bottom, 12)
        .overlay(alignment: .topLeading) {
            if !isLast {
                // An overlay receives the finished row size without participating in its
                // layout. This keeps LazyVStack's measurements finite while the connector
                // still follows rows with one or two title lines.
                TimelineConnectorShape()
                    .stroke(Theme.accent.opacity(0.22), lineWidth: 2)
                    .frame(width: 14)
                    .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            }
        }
    }

    private var timeLabel: String {
        guard item.date != .distantPast else { return "Unknown time" }
        return item.date.formatted(date: .omitted, time: .shortened)
    }
}

private struct TimelineConnectorShape: Shape {
    func path(in rect: CGRect) -> Path {
        guard rect.height > 11 else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: 11))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
