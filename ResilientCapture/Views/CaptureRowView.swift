import SwiftUI

/// One row in the queue list: thumbnail, short id, capture time, state badge,
/// and (for failed items) the last error and a manual retry button.
///
/// The row is a value describing a single `CaptureItem`; the retry action is
/// passed in rather than reaching back into the model, keeping the row reusable
/// and previewable.
struct CaptureRowView: View {
    let item: CaptureItem
    let loadThumbnail: () async -> UIImage?
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(reloadKey: "\(item.id)-\(item.state.rawValue)", load: loadThumbnail)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.id.uuidString.prefix(8) + "…")
                    .font(.subheadline.monospaced())
                Text(item.createdAt, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.state == .failed, let lastError = item.lastError {
                    Text(lastError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                StateBadgeView(state: item.state)
                if item.state == .failed {
                    Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
