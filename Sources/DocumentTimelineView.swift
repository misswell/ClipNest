import SwiftUI

/// A chronological view of every Markdown document in the open vault. It reads the same
/// refresh-time snapshot as the home screen, so switching tabs does not trigger another
/// recursive filesystem scan or a document-body read.
struct DocumentTimelineView: View {
    @EnvironmentObject private var store: VaultStore
    @State private var navigationPath = NavigationPath()

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if store.rootNode == nil {
                    ContentUnavailableView(
                        "No Vault",
                        systemImage: "folder.badge.questionmark",
                        description: Text("Open a vault from the Vault tab to see its documents here.")
                    )
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

    private var timelineSections: [TimelineSection] {
        let calendar = Calendar.autoupdatingCurrent
        let grouped = Dictionary(grouping: store.homeSnapshot.timelineItems) { item -> Date? in
            guard item.date != .distantPast else { return nil }
            return calendar.startOfDay(for: item.date)
        }

        return grouped
            .map { TimelineSection(day: $0.key, items: $0.value) }
            .sorted { lhs, rhs in
                switch (lhs.day, rhs.day) {
                case let (left?, right?): return left > right
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                }
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

private struct TimelineSection: Identifiable {
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

private struct TimelineDocumentRow: View {
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
        .background(alignment: .topLeading) {
            if !isLast {
                // Draw the connector from the finished row size so it cannot affect the
                // LazyVStack's height calculation or create an infinite-height placeholder.
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Theme.accent.opacity(0.22))
                        .frame(width: 2, height: max(0, proxy.size.height - 11))
                        .offset(x: 6, y: 11)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var timeLabel: String {
        guard item.date != .distantPast else { return "Unknown time" }
        return item.date.formatted(date: .omitted, time: .shortened)
    }
}
