import SwiftUI

struct SettingsView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(SeasonClock.self) private var season
    @State private var confirmingSignOut = false
    @State private var confirmingNewRound = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
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
                    Text("Uses your server's loudness analysis, so a quiet old record and a loud new one play at about the same volume. Albums played in order keep their own dynamics.")
                }

                Section {
                    if let progress = library.shuffleProgress {
                        LabeledContent("This round", value: "\(progress.played.grouped) of \(progress.total.grouped)")
                    }
                    Button("Start a New Round") { confirmingNewRound = true }
                } header: {
                    Text("True Shuffle")
                } footer: {
                    Text("Shuffle All plays every song once, in a random order, before any song plays twice. No song is favored: not by ratings, plays, or how popular it is.")
                }

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
                    Text("Right now it's \(season.theme.title.lowercased() == season.theme.season.title.lowercased() ? season.theme.title.lowercased() : "\(season.theme.title) (\(season.theme.season.title.lowercased()))"). The colors, the falling things on Home, and the mixes follow the season.")
                }

                Section {
                    Button("Refresh Library") { Task { await library.refresh() } }
                    Button("Sign Out", role: .destructive) { confirmingSignOut = true }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    LabeledContent("Made by", value: "AM2 LLC")
                }
            }
            .navigationTitle("Settings")
            .onChange(of: settings.hemisphere) { season.refresh() }
            .confirmationDialog("Sign out of Plex?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { library.signOut() }
            } message: {
                Text("Your music stays on your server. Truffle forgets the sign-in and the queue.")
            }
            .confirmationDialog("Start a new shuffle round?", isPresented: $confirmingNewRound, titleVisibility: .visible) {
                Button("Start Over") { library.startNewShuffleRound() }
            } message: {
                Text("Songs you've heard this round can come up again.")
            }
        }
    }
}
