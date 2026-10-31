import AppIntents
import SwiftUI
import WidgetKit
import os

@main
struct TruffleWidgets: WidgetBundle {
    var body: some Widget {
        MixesWidget()
        ShuffleAllControl()
    }
}

/// Shuffle All on the Home Screen (and in CarPlay's widgets), with the season's mixes beside it at
/// medium size.
struct MixesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TruffleMixes", provider: MixesProvider()) { entry in
            FamilyView(entry: entry)
        }
        .configurationDisplayName("Truffle")
        .description("Shuffle All and the season's mixes.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }

    private struct FamilyView: View {
        let entry: MixesEntry
        @Environment(\.widgetFamily) private var family

        var body: some View {
            MixesWidgetView(entry: entry, family: family)
        }
    }
}

/// Today, then each time the season's mixes change in the next day. Nothing it shows comes from the
/// app, so there's nothing to share with it and no App Group.
struct MixesProvider: TimelineProvider {
    func placeholder(in context: Context) -> MixesEntry {
        MixesEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (MixesEntry) -> Void) {
        completion(MixesEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MixesEntry>) -> Void) {
        let sw = Stopwatch()
        let now = Date.now
        let entries = [MixesEntry(date: now)] + MixesEntry.changes(after: now).map { MixesEntry(date: $0) }
        Logger.widget.info("[widget] timeline: \(entries.count) entries, \(entries[0].theme.id, privacy: .public) now, in \(sw.ms, format: .fixed(precision: 1))ms")
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

/// Shuffle All in Control Center, on the Lock Screen or on the Action button.
struct ShuffleAllControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.vanities.truffle.shuffleAll") {
            ControlWidgetButton(action: ShuffleAllIntent()) {
                Label("Shuffle All", systemImage: "shuffle")
            }
        }
        .displayName("Shuffle All")
        .description("Every song, no favorites.")
    }
}
