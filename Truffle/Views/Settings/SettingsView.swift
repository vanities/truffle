import SwiftUI

struct SettingsView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(SeasonClock.self) private var season
    @Environment(AppRouter.self) private var router
    @Environment(PlayerEngine.self) private var player
    @State private var confirmingSignOut = false
    @State private var confirmingNewRound = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section("Plex") {
                    LabeledContent("Signed in as", value: library.userName ?? "—")
                    LabeledContent("Server") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(library.serverName)
                            if let kind = library.endpoint?.kind {
                                Text(kind.label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if library.sections.count > 1 {
                        Picker("Music library", selection: Binding(
                            get: { library.section?.id ?? "" },
                            set: { id in if let section = library.sections.first(where: { $0.id == id }) { library.setSection(section) } }
                        )) {
                            ForEach(library.sections) { Text($0.title).tag($0.id) }
                        }
                    }
                    LabeledContent("Songs", value: library.trackCount.grouped)
                    LabeledContent("Albums", value: library.albums.count.grouped)
                }

                Section {
                    Toggle("Even Out Volume", isOn: $settings.evenOutVolume)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Keeps loud songs from shouting.")
                }

                Section {
                    Picker("Crossfade", selection: $settings.crossfadeSeconds) {
                        ForEach(Crossfade.choices, id: \.self) { seconds in
                            Text(seconds == 0 ? "Off" : "\(seconds) sec").tag(seconds)
                        }
                    }
                    .onChange(of: settings.crossfadeSeconds) { player.playbackSettingsChanged() }
                    Toggle("Data Saver", isOn: $settings.dataSaver)
                        .onChange(of: settings.dataSaver) { player.playbackSettingsChanged() }
                } header: {
                    Text("Shuffle & Cellular")
                } footer: {
                    Text("Shuffles melt into each other; albums never do. On cellular, Data Saver sips 192 kbps.")
                }
                .id("shuffleCellular")

                Section {
                    if let progress = library.shuffleProgress {
                        LabeledContent("This round", value: "\(progress.played.grouped) of \(progress.total.grouped)")
                    }
                    Button("Start a New Round") { confirmingNewRound = true }
                } header: {
                    Text("True Shuffle")
                } footer: {
                    Text("Every song once before any song twice. No favorites.")
                }
                .id("shuffle")

                Section {
                    Toggle("Play in the Car", isOn: $settings.playInTheCar)
                } header: {
                    Text("CarPlay")
                } footer: {
                    Text("Hop in and it picks up where you left off.")
                }
                .id("car")

                Section {
                    Toggle("Keep Holidays in Season", isOn: $settings.holidaysInSeason)
                } header: {
                    Text("Holiday Music")
                } footer: {
                    Text(holidayFooter)
                }
                .id("holidays")

                Section {
                    HStack(spacing: 18) {
                        ForEach(AppIconChoice.allCases, id: \.self) { choice in
                            Button {
                                settings.appIcon = choice
                            } label: {
                                VStack(spacing: 6) {
                                    Image(decorative: choice.preview)
                                        .resizable()
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                                .strokeBorder(.tint, lineWidth: settings.appIcon == choice ? 3 : 0)
                                        }
                                    Text(choice.title).font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(settings.appIcon == choice ? .isSelected : [])
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    Toggle("Match the Season", isOn: $settings.seasonalIcon)
                } header: {
                    Text("App Icon")
                } footer: {
                    Text("The note shows up in the fall.")
                }
                .id("appIcon")

                Section {
                    Toggle("Seasonal Effects", isOn: $settings.seasonalEffects)
                    Picker("Hemisphere", selection: $settings.hemisphere) {
                        Text("Automatic").tag(Hemisphere.automatic)
                        Text("Northern").tag(Hemisphere.northern)
                        Text("Southern").tag(Hemisphere.southern)
                    }
                } header: {
                    Text("Seasons")
                } footer: {
                    Text("Right now: \(season.theme.title).")
                }

                Section {
                    Button("Refresh Library") { Task { await library.refresh() } }
                    Button("Sign Out", role: .destructive) { confirmingSignOut = true }
                }

                AboutSection()
                    .id("about")
            }
            .onChange(of: router.scrollTarget) { _, target in
                guard let target else { return }
                proxy.scrollTo(target, anchor: .top)
            }
            }
            .navigationTitle("Settings")
            .onChange(of: settings.hemisphere) { season.refresh() }
            .confirmationDialog("Sign out of Plex?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { library.signOut() }
            } message: {
                Text("Your music stays put.")
            }
            .confirmationDialog("Start a new shuffle round?", isPresented: $confirmingNewRound, titleVisibility: .visible) {
                Button("Start Over") { library.startNewShuffleRound() }
            } message: {
                Text("Everything goes back in the hat.")
            }
        }
    }

    private var holidayFooter: String {
        let songs = library.holidays.songs
        guard settings.holidaysInSeason else { return "Jingle bells all year. Bold." }
        if HolidayMusic.isInSeason(season.now) {
            return songs > 0 ? "'Tis the season: \(songs.counted("song")) back in the shuffle." : "'Tis the season."
        }
        guard songs > 0 else { return "No jingle bells in July." }
        return "No jingle bells in July. \(songs.counted("song")) \(songs == 1 ? "is" : "are") waiting for \(songs == 1 ? "its" : "their") season."
    }
}
