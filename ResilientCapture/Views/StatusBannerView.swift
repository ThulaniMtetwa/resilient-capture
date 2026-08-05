import SwiftUI

/// A slim, non-invasive status strip shown above the queue. Built as a
/// translucent material capsule with a colour-carrying icon and primary-colour
/// text (legible over the material), so it reads as floating chrome rather than a
/// heavy bar. Success auto-dismisses (handled by the parent).
struct StatusBannerView: View {
    let message: StatusMessage

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 20)
            Text(message.text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
        .padding(.horizontal)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.text)
    }

    @ViewBuilder
    private var icon: some View {
        if message.showsActivity {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: message.systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
        }
    }

    private var tint: Color {
        switch message.tone {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .offline: return .secondary
        }
    }
}
