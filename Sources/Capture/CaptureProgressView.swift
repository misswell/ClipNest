import SwiftUI

struct CaptureProgressView: View {
    @EnvironmentObject private var coordinator: CaptureCoordinator
    @State private var dragOffset: CGFloat = 0

    private let dismissThreshold: CGFloat = 52

    var body: some View {
        VStack(spacing: 8) {
            Capsule()
                .fill(Theme.mutedInk.opacity(0.3))
                .frame(width: 34, height: 4)

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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 430)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .offset(y: dragOffset)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    dragOffset = min(0, value.translation.height)
                }
                .onEnded { value in
                    let draggedUp = -value.translation.height
                    let predictedDraggedUp = -value.predictedEndTranslation.height
                    guard draggedUp >= dismissThreshold || predictedDraggedUp >= dismissThreshold * 1.75 else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            dragOffset = 0
                        }
                        return
                    }

                    withAnimation(.easeInOut(duration: 0.2)) {
                        dragOffset = -180
                        coordinator.dismissStatusBanner()
                    }
                }
        )
        .onAppear {
            dragOffset = 0
        }
        .accessibilityHint(Text("Swipe up to dismiss"))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
