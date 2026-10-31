import AppIntents
import SwiftUI
import WidgetKit

// Compiled into the app as well as the widget extension, so the tests can draw it.

/// What the Home Screen widget shows at one moment: the season's look, and the mixes it offers.
struct MixesEntry: TimelineEntry, Sendable {
    let date: Date
    let theme: SeasonTheme
    /// The medium widget's tiles: Liked, then the season's mixes.
    let tiles: [MixCatalog.Entry]

    init(date: Date, southern: Bool = Hemisphere.saved().isSouthern(), calendar: Calendar = .current,
         region: Locale.Region? = Locale.current.region) {
        let today = MixCatalog.today(at: date, southern: southern, calendar: calendar, region: region)
        self.date = date
        theme = today.first?.theme ?? SeasonCalendar.theme(for: date, southern: southern, calendar: calendar, region: region)
        tiles = Array(today.filter { $0.mix.kind != .shuffleAll && $0.mix.kind != .randomAlbum }.prefix(4))
    }

    /// When the widget has to change on its own: midnight (a holiday starts or ends), 5 am and 8 pm
    /// (Night Drive comes and goes).
    static func changes(after date: Date, calendar: Calendar = .current) -> [Date] {
        [0, 5, 20].compactMap {
            calendar.nextDate(after: date, matching: DateComponents(hour: $0, minute: 0), matchingPolicy: .nextTime)
        }.sorted()
    }
}

struct MixesWidgetView: View {
    let entry: MixesEntry
    let family: WidgetFamily

    var body: some View {
        Group {
            if family == .systemMedium {
                HStack(spacing: 12) {
                    shuffleAll
                    VStack(spacing: 8) {
                        ForEach(Array(stride(from: 0, to: entry.tiles.count, by: 2)), id: \.self) { start in
                            HStack(spacing: 8) {
                                ForEach(entry.tiles[start..<min(start + 2, entry.tiles.count)]) { tile in
                                    Button(intent: PlayMixIntent(mix: MixEntity(tile))) {
                                        MixTile(entry: tile)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            } else {
                shuffleAll
            }
        }
        .containerBackground(for: .widget) {
            entry.theme.gradient
        }
    }

    private var shuffleAll: some View {
        Button(intent: ShuffleAllIntent()) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.theme.label)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .opacity(0.85)
                Spacer(minLength: 0)
                Image(systemName: "shuffle")
                    .font(.system(size: 26, weight: .bold))
                    .padding(.bottom, 4)
                Text(Mix.shuffleAll.title)
                    .font(.system(size: 17, weight: .bold))
                Text(entry.theme.greeting)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shuffle All")
    }
}

/// A mix's cover with its name on it; Liked is a heart.
private struct MixTile: View {
    let entry: MixCatalog.Entry

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let art = entry.mix.art {
                Image("Mix-\(art)")
                    .resizable()
                    .widgetAccentedRenderingMode(.accentedDesaturated)
                    .scaledToFill()
            } else {
                LinearGradient(colors: [Color(red: 1, green: 0.32, blue: 0.42), Color(red: 0.6, green: 0.1, blue: 0.3)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: entry.mix.symbol)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            Text(entry.mix.shortTitle)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.horizontal, 6)
                .padding(.bottom, 5)
        }
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: .infinity)
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.mix.title)
        .accessibilityAddTraits(.isButton)
    }
}
