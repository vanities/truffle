import SwiftUI

// Stats' building blocks, after Mango's (ShelfKit's StatCard and StatTile), drawn as Truffle's grouped
// cards and tinted by the season.

/// A titled card.
struct StatCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22, style: .continuous))
    }
}

/// One headline number: an icon, the value, what it counts.
struct StatTile: View {
    let value: String
    let label: String
    let systemImage: String

    init(_ value: String, _ label: String, systemImage: String) {
        self.value = value
        self.label = label
        self.systemImage = systemImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(.tint)
            Text(value)
                .font(.title2.weight(.bold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

enum RankKind {
    case artist, album, song

    var placeholder: String {
        switch self {
        case .artist: "music.mic"
        case .album: "square.stack"
        case .song: "music.note"
        }
    }
}

/// A song, album or artist with its place in a list and its plays.
struct RankRow: View {
    let item: ListeningStats.Ranked
    var rank: Int?
    let kind: RankKind
    /// Replaces the subtitle.
    var detail: String?
    /// Replaces the play count.
    var trailing: String?
    /// A small line under it.
    var trailingDetail: String?
    var isStarting = false

    var body: some View {
        HStack(spacing: 12) {
            if let rank {
                Text("\(rank)")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.tint)
                    .frame(minWidth: 18)
            }
            ArtworkView(thumb: item.thumb, pixels: 120, cornerRadius: 8, circle: kind == .artist, placeholderSymbol: kind.placeholder)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                if let line = detail ?? item.subtitle {
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if isStarting {
                ProgressView()
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(trailing ?? item.plays.counted("play"))
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if let trailingDetail {
                        Text(trailingDetail)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension TimeInterval {
    /// "47 min", "3 hr 12 min", "241 hr": past ten hours the minutes stop mattering.
    var statsDuration: String {
        let minutes = isFinite ? Int((Swift.max(0, self) / 60).rounded()) : 0
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        if hours >= 10 || rest == 0 { return "\(hours.grouped) hr" }
        return "\(hours) hr \(rest) min"
    }
}

extension ListeningStats.Period {
    /// The picker's word.
    var label: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .all: "All Time"
        }
    }

    var title: String {
        switch self {
        case .week: "This week"
        case .month: "This month"
        case .year: "This year"
        case .all: "All time"
        }
    }

    var quietLine: String {
        switch self {
        case .week: "Quiet week so far."
        case .month: "Quiet month so far."
        case .year: "Quiet year so far."
        case .all: "Nothing yet."
        }
    }
}
