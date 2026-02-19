import SwiftUI

struct StarRatingLabel: View {
    let vote: Double

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill")
                .font(.caption2)
                .foregroundStyle(.yellow)
            Text(String(format: "%.1f", vote))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct EmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    let actions: Actions

    init(icon: String, title: String, subtitle: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .frame(width: 80, height: 80)
                .glassEffect(.regular, in: .circle)
            Text(title)
                .font(.title3)
                .fontDesign(.rounded)
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            actions
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(icon: String, title: String, subtitle: String? = nil) {
        self.init(icon: icon, title: title, subtitle: subtitle) {
            EmptyView()
        }
    }
}
