import AppIntents
import Foundation

// These compile into the widget extension too, so its buttons can name them. As AudioPlaybackIntents
// they always run in the app's process, and `IntentRunner` is the app's (the widget's own copy only
// logs).

/// Every song, in a truly random order: from Siri, Shortcuts, the Action button, the widget and Control
/// Center.
struct ShuffleAllIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle All"
    static let description: IntentDescription? = IntentDescription("Every song in your library, in a truly random order.")

    func perform() async throws -> some IntentResult {
        try await IntentRunner.playMix(id: Mix.shuffleAll.id)
        return .result()
    }
}

struct PlayLikedIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Liked Songs"
    static let description: IntentDescription? = IntentDescription("The songs you've hearted, shuffled.")

    func perform() async throws -> some IntentResult {
        try await IntentRunner.playMix(id: Mix.liked.id)
        return .result()
    }
}

/// One of the season's mixes, or any holiday's or season's own.
struct PlayMixIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play a Mix"
    static let description: IntentDescription? = IntentDescription("The season's mixes, This Time Last Year, Night Drive and the rest.")

    @Parameter(title: "Mix")
    var mix: MixEntity

    init() {}

    init(mix: MixEntity) {
        self.mix = mix
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$mix)")
    }

    func perform() async throws -> some IntentResult {
        try await IntentRunner.playMix(id: mix.id)
        return .result()
    }
}

struct MixEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mix"
    static let defaultQuery = MixQuery()

    let id: String
    let title: String
    let subtitle: String
    let symbol: String

    init(id: String, mix: Mix) {
        self.id = id
        title = mix.title
        subtitle = mix.subtitle
        symbol = mix.symbol
    }

    init(_ entry: MixCatalog.Entry) {
        self.init(id: entry.id, mix: entry.mix)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)", image: .init(systemName: symbol))
    }
}

struct MixQuery: EntityStringQuery {
    func entities(for identifiers: [MixEntity.ID]) async throws -> [MixEntity] {
        let now = SeasonCalendar.now, southern = Hemisphere.saved().isSouthern()
        return identifiers.compactMap { id in
            MixCatalog.entry(id: id, at: now, southern: southern).map { MixEntity(id: id, mix: $0.mix) }
        }
    }

    func entities(matching string: String) async throws -> [MixEntity] {
        try await suggestedEntities().filter { MediaText.score($0.title, asked: string) > 0 }
    }

    func suggestedEntities() async throws -> [MixEntity] {
        MixCatalog.all(at: SeasonCalendar.now, southern: Hemisphere.saved().isSouthern()).map(MixEntity.init)
    }
}
