import Charts
import SwiftUI
import os

/// Mango's Stats, for music: plays, time, streaks and favorites from the server's play history.
struct StatsView: View {
    @Environment(StatsModel.self) private var model
    @Environment(MusicLibrary.self) private var library
    @Environment(PlayerEngine.self) private var player
    @Environment(SeasonClock.self) private var season
    @Environment(AppRouter.self) private var router
    @State private var period: ListeningStats.Period = .month
    @State private var startingSong: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    content
                }
                .background(Color(.systemGroupedBackground))
                .refreshable { await model.refresh() }
                .onChange(of: router.scrollTarget) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target, anchor: .top)
                }
            }
            .navigationTitle("Stats")
            .libraryDestinations()
        }
        .task(id: library.section?.id) { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        if let stats = model.stats, !stats.isEmpty {
            cards(stats)
        } else if model.stats != nil {
            ContentUnavailableView("Nothing played yet", systemImage: "chart.bar", description: Text("Press play. The numbers follow."))
                .containerRelativeFrame([.horizontal, .vertical])
        } else if let message = model.errorMessage {
            ContentUnavailableView {
                Label("Can't count right now", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.refresh() } }
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
            .containerRelativeFrame([.horizontal, .vertical])
        } else {
            counting
                .containerRelativeFrame([.horizontal, .vertical])
        }
    }

    private var counting: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.large)
            Text("Counting plays…")
                .font(.headline)
            if let progress = model.progress, let total = progress.total, total > 0 {
                Text("\(min(progress.read, total).grouped) of \(total.grouped)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func cards(_ stats: ListeningStats) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            headline(stats)
            lately(stats)
            months(stats)
                .id("months")
            mostPlayed(stats)
                .id("mostPlayed")
            habits(stats)
                .id("habits")
            if !stats.longTimeNoHear.isEmpty {
                longTimeNoHear(stats.longTimeNoHear)
                    .id("longTime")
            }
            if let first = stats.firstPlay {
                dayOne(first)
                    .id("dayOne")
            }
            footnote
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Headline

    private func headline(_ stats: ListeningStats) -> some View {
        let all = stats.total(.all)
        // One tile across at the accessibility text sizes, so the numbers and their names fit.
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 300 : 150), spacing: 12)], spacing: 12) {
            StatTile(all.plays.grouped, "Plays", systemImage: "play.circle.fill")
            StatTile(all.seconds.statsDuration, "Listening", systemImage: "headphones")
            StatTile(stats.currentStreak.counted("day"), "Current streak", systemImage: "flame.fill")
            StatTile(stats.longestStreak.counted("day"), "Longest streak", systemImage: "trophy.fill")
            StatTile(stats.songsHeard.grouped, heardLabel(stats), systemImage: "music.note")
            StatTile(all.artists.grouped, "Artists", systemImage: "music.mic")
        }
    }

    private func heardLabel(_ stats: ListeningStats) -> String {
        guard let share = stats.libraryShare else { return "Songs heard" }
        return "Songs heard · \(share.formatted(.percent.precision(.fractionLength(0))))"
    }

    private func lately(_ stats: ListeningStats) -> some View {
        StatCard("Lately") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                ForEach([ListeningStats.Period.week, .month, .year]) { period in
                    let total = stats.total(period)
                    GridRow {
                        Text(period.title)
                            .foregroundStyle(.secondary)
                        Text(total.plays.counted("play"))
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Text(total.seconds.statsDuration)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: 96, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - Charts

    /// The season's middle color rising into its accent.
    private var barFill: LinearGradient {
        LinearGradient(colors: [season.theme.colors[1], season.theme.accentColor], startPoint: .bottom, endPoint: .top)
    }

    private var quietBar: Color { season.theme.accentColor.opacity(0.3) }

    private func months(_ stats: ListeningStats) -> some View {
        StatCard("Plays by month") {
            Chart(stats.months) { month in
                BarMark(x: .value("Month", month.start, unit: .month), y: .value("Plays", month.plays))
                    .foregroundStyle(barFill)
                    .cornerRadius(4)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 180)
            if let best = stats.bestMonth {
                Text("Best month: \(best.start.formatted(.dateTime.month(.wide).year())), \(best.plays.counted("play")).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func habits(_ stats: ListeningStats) -> some View {
        let calendar = Calendar.current
        let weekdays = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        let busiestHour = stats.busiestHour
        let busiestDay = stats.busiestWeekday
        // The hours sit on one real day, a clock change nowhere near it, so the axis can label them as times.
        let midnight = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1)) ?? .now
        return StatCard("When you listen") {
            Chart(0..<24, id: \.self) { hour in
                BarMark(x: .value("Hour", calendar.date(byAdding: .hour, value: hour, to: midnight) ?? midnight, unit: .hour),
                        y: .value("Plays", stats.byHour[hour]))
                    .foregroundStyle(hour == busiestHour ? AnyShapeStyle(barFill) : AnyShapeStyle(quietBar))
                    .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisValueLabel(format: .dateTime.hour(), centered: false)
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 120)
            Chart(weekdays, id: \.self) { weekday in
                BarMark(x: .value("Day", calendar.shortWeekdaySymbols[weekday - 1]), y: .value("Plays", stats.byWeekday[weekday - 1]))
                    .foregroundStyle(weekday == busiestDay ? AnyShapeStyle(barFill) : AnyShapeStyle(quietBar))
                    .cornerRadius(4)
            }
            .chartXScale(domain: weekdays.map { calendar.shortWeekdaySymbols[$0 - 1] })
            .chartXAxis { AxisMarks { AxisValueLabel() } }
            .chartYAxis(.hidden)
            .frame(height: 110)
            if let busiestHour, let busiestDay {
                Text("Busiest day: \(calendar.weekdaySymbols[busiestDay - 1]). Busiest hour: \(hourName(busiestHour)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "7:00 AM", or "07:00" where the clock is 24-hour.
    private func hourName(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Lists

    private func mostPlayed(_ stats: ListeningStats) -> some View {
        let top = stats.top(period)
        return StatCard("Most played") {
            Picker("Period", selection: $period) {
                ForEach(ListeningStats.Period.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.extraLarge)
            if top.isEmpty {
                Text(period.quietLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 88)
            } else {
                ranks("Artists", Array(top.artists.prefix(3)), kind: .artist)
                ranks("Albums", Array(top.albums.prefix(3)), kind: .album)
                ranks("Songs", top.songs, kind: .song)
            }
        }
    }

    @ViewBuilder
    private func ranks(_ title: String, _ items: [ListeningStats.Ranked], kind: RankKind) -> some View {
        if !items.isEmpty {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    rankLink(item, rank: index + 1, kind: kind, in: items)
                    if index < items.count - 1 {
                        Divider().padding(.leading, 86)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rankLink(_ item: ListeningStats.Ranked, rank: Int, kind: RankKind, in list: [ListeningStats.Ranked]) -> some View {
        let row = RankRow(item: item, rank: rank, kind: kind, isStarting: startingSong == item.id)
        switch kind {
        case .artist:
            if let id = item.artistID {
                NavigationLink(value: Route.artist(Artist(id: id, title: item.title, thumb: item.thumb))) { row }
                    .buttonStyle(.plain)
            } else {
                row
            }
        case .album:
            if let id = item.albumID {
                NavigationLink(value: Route.album(Album(id: id, title: item.title, artist: item.subtitle ?? "",
                                                        artistID: item.artistID, thumb: item.thumb))) { row }
                    .buttonStyle(.plain)
            } else {
                row
            }
        case .song:
            Button { play(list, from: item, source: "Most Played") } label: { row }
                .buttonStyle(.plain)
                .disabled(item.trackID == nil)
        }
    }

    private func longTimeNoHear(_ items: [ListeningStats.Ranked]) -> some View {
        StatCard("Long time no hear") {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button { play(items, from: item, source: "Long Time No Hear") } label: {
                        RankRow(item: item, kind: .song, trailingDetail: item.lastPlayed?.formatted(.dateTime.month(.abbreviated).year()),
                                isStarting: startingSong == item.id)
                    }
                    .buttonStyle(.plain)
                    if index < items.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
        }
    }

    private func dayOne(_ first: ListeningStats.FirstPlay) -> some View {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: first.date), to: calendar.startOfDay(for: .now)).day ?? 0
        return StatCard("Day one") {
            Button { play([first.song], from: first.song, source: "Day One") } label: {
                HStack(spacing: 14) {
                    ArtworkView(thumb: first.song.thumb, pixels: 240, cornerRadius: 10)
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(first.song.title)
                            .font(.headline)
                            .lineLimit(2)
                        if let artist = first.song.subtitle {
                            Text(artist)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1, atAccessibilitySizes: nil)
                        }
                        Text(first.date.formatted(date: .long, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Group {
                        if startingSong == first.song.id {
                            ProgressView()
                        } else {
                            Image(systemName: "play.circle.fill")
                                .font(.title)
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(first.song.trackID == nil)
            .accessibilityHint("Plays it")
            Text("The first play on record, \(days.counted("day")) ago.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let message = model.errorMessage {
                Label("Couldn't update. \(message)", systemImage: "wifi.exclamationmark")
            } else if model.isUpdating {
                Label("Catching up…", systemImage: "arrow.triangle.2.circlepath")
            }
            Text("Straight from Plex's play history, every app included.")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 4)
    }

    // MARK: - Playing

    /// Plays the list from the tapped song. Lists hold only ids, so the songs' details come first.
    private func play(_ list: [ListeningStats.Ranked], from item: ListeningStats.Ranked, source title: String) {
        guard startingSong == nil, let trackID = item.trackID else { return }
        startingSong = item.id
        let ids = list.compactMap(\.trackID)
        Logger.stats.info("[stats] play \(title, privacy: .public) from \(ids.firstIndex(of: trackID) ?? 0) of \(ids.count)")
        Task {
            defer { startingSong = nil }
            do {
                let tracks = try await library.details(for: ids)
                guard !tracks.isEmpty else {
                    router.say("That one's gone from the library.")
                    return
                }
                player.play(tracks, startAt: tracks.firstIndex { $0.id == trackID } ?? 0, source: PlaySource(kind: .songs, title: title))
            } catch {
                Logger.stats.error("[stats] couldn't start \(title, privacy: .public): \(error.localizedDescription, privacy: .public)")
                router.say("Couldn't start that one.")
            }
        }
    }
}
