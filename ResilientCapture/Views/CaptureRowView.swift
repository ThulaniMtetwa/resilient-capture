import SwiftUI

/// One row in the queue: a squircle thumbnail, a human title and timestamp, and a
/// per-state trailing indicator (waiting pill, spinner, success seal, or a retry
/// button). Differentiating the trailing element by state reads cleaner than a
/// single uniform badge and matches how native apps signal progress.
struct CaptureRowView: View {
    let item: CaptureItem
    let loadThumbnail: () async -> UIImage?
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ThumbnailView(
                reloadKey: "\(item.id)-\(item.state.rawValue)",
                load: loadThumbnail
            )

            VStack(alignment: .leading, spacing: 3) {
                Text("Identity capture")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(item.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if item.state == .failed, let lastError = item.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(.vertical, 6)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: item.state)
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.state {
        case .pending:
            StatusPill(text: "Waiting", systemImage: "clock", tint: .orange)
        case .uploading:
            ProgressView()
                .controlSize(.small)
                .transition(.opacity)
        case .uploaded:
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .failed:
            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .tint(.accentColor)
            .accessibilityLabel("Retry upload")
        }
    }
}

/// A small, tinted status pill (icon + text) with a continuous-corner capsule.
struct StatusPill: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule())
    }
}
