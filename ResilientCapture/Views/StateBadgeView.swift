import SwiftUI

/// A colour-coded pill showing an item's upload state.
///
/// State is conveyed by an icon + text, not colour alone, so it stays legible
/// under colour-blindness (an accessibility rule from `swiftui-principles`).
struct StateBadgeView: View {
    let state: UploadState

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityLabel("Status: \(title)")
    }

    private var title: String {
        switch state {
        case .pending: return "Pending"
        case .uploading: return "Uploading"
        case .uploaded: return "Uploaded"
        case .failed: return "Failed"
        }
    }

    private var symbol: String {
        switch state {
        case .pending: return "clock"
        case .uploading: return "arrow.up.circle"
        case .uploaded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .pending: return .orange
        case .uploading: return .blue
        case .uploaded: return .green
        case .failed: return .red
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        ForEach(UploadState.allCases, id: \.self) { StateBadgeView(state: $0) }
    }
    .padding()
}
