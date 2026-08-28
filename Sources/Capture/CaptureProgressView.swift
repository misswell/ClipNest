import SwiftUI

struct CaptureProgressView: View {
    @EnvironmentObject private var coordinator: CaptureCoordinator

    var body: some View {
        HStack(spacing: 12) {
            if coordinator.isProcessing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: coordinator.state == .completed ? "checkmark.circle.fill" : "doc.text.magnifyingglass")
                    .foregroundStyle(Theme.accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("ClipNest")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.mutedInk)
                Text(coordinator.statusMessage.isEmpty ? coordinator.state.title : coordinator.statusMessage)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 430)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
