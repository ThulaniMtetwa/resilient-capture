import SwiftUI

/// A slim, non-invasive status strip shown above the queue. It never blocks
/// interaction and animates in/out; success auto-dismisses (handled by the
/// parent). Colour + icon both carry meaning (accessibility).
struct StatusBannerView: View {
    let message: StatusMessage

    var body: some View {
        HStack(spacing: 8) {
            if message.showsActivity {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: message.systemImage)
                    .imageScale(.medium)
            }
            Text(message.text)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.text)
    }

    private var tint: Color {
        switch message.tone {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .offline: return .gray
        }
    }
}

#Preview {
    VStack(spacing: 8) {
        StatusBannerView(message: .init(text: "Offline · captures are saved and will upload when you reconnect.", systemImage: "wifi.slash", tone: .offline))
        StatusBannerView(message: .init(text: "Uploading 2 captures over Cellular…", systemImage: "arrow.up.circle", tone: .info, showsActivity: true))
        StatusBannerView(message: .init(text: "1 upload failed · tap Retry to try again.", systemImage: "exclamationmark.triangle.fill", tone: .warning))
        StatusBannerView(message: .init(text: "All captures uploaded.", systemImage: "checkmark.circle.fill", tone: .success))
    }
}
