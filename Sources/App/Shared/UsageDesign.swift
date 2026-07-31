import SwiftUI

extension Color {
    static let usageBackground = Color(red: 0.055, green: 0.061, blue: 0.071)
    static let usageSidebar = Color(red: 0.073, green: 0.080, blue: 0.094)
    static let usageCard = Color(red: 0.105, green: 0.114, blue: 0.132)
    static let usageCardRaised = Color(red: 0.135, green: 0.145, blue: 0.165)
    static let usageBorder = Color.white.opacity(0.08)
    static let usageDownload = Color(red: 0.122, green: 0.659, blue: 0.545)
    static let usageUpload = Color(red: 0.545, green: 0.486, blue: 1.0)
    static let usageCost = Color(red: 0.647, green: 0.427, blue: 0.063)
}

struct GraphiteCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.usageCard)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.usageBorder, lineWidth: 1)
            }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let detail: String
    let color: Color
    let symbol: String

    var body: some View {
        GraphiteCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 34, height: 34)
                    .background(color.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct DirectionLegend: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 12, height: 4)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct EmptyStateCard: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        GraphiteCard {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
        }
    }
}
