import AVKit
import SwiftUI

/// Lives in the tab bar's bottom accessory, Apple Music style; one line when the tab bar minimizes.
struct MiniPlayerView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let open: () -> Void

    var body: some View {
        if let track = player.current {
            HStack(spacing: 4) {
                Button(action: open) {
                    HStack(spacing: 12) {
                        if placement != .inline {
                            ArtworkView(thumb: track.thumb, pixels: 120, cornerRadius: 8)
                                .frame(width: 40, height: 40)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .accessibilityIdentifier("miniPlayer.title")
                            if placement != .inline {
                                Text(track.artist)
                                    .font(.caption)
                                    // Gray on the accessory's glass is too faint; a lighter black or white isn't.
                                    .foregroundStyle(.primary.opacity(0.78))
                                    .lineLimit(1)
                                    .accessibilityIdentifier("miniPlayer.artist")
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now playing: \(track.title) by \(track.artist)")
                .accessibilityHint("Opens the player")
                .accessibilityInputLabels(["Now Playing", "Player", track.title])
                .accessibilityShowsLargeContentViewer { Text("\(track.title), \(track.artist)") }
                if player.isLoading {
                    ProgressView().frame(width: 44, height: 44)
                } else {
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    .accessibilityInputLabels([player.isPlaying ? "Pause" : "Play", "Play Pause"])
                    .accessibilityShowsLargeContentViewer {
                        Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next")
                .accessibilityInputLabels(["Next", "Skip", "Next Song"])
                .accessibilityShowsLargeContentViewer { Label("Next", systemImage: "forward.fill") }
            }
            .padding(.horizontal, 12)
            // The accessory is a bar with a fixed height, like the tab bar under it: its text stops growing
            // at the largest regular size, and a long press shows the Large Content Viewer instead.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
    }
}

/// AirPlay and Bluetooth output picker.
struct RoutePickerView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .secondaryLabel
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct QueueView: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let current = player.current {
                    Section("Now Playing") {
                        TrackRow(track: current)
                    }
                }
                Section {
                    ForEach(Array(player.queue.upcoming.enumerated()), id: \.offset) { offset, track in
                        Button {
                            player.jump(to: player.queue.index + 1 + offset)
                        } label: {
                            TrackRow(track: track)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { player.removeUpcoming(at: $0) }
                    .onMove { player.moveUpcoming(from: $0, to: $1) }
                } header: {
                    Text("Up Next")
                } footer: {
                    if player.isEndless {
                        Text("More where these came from.")
                    }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Shuffle", systemImage: "shuffle") { player.shuffleUpcoming() }
                        .disabled(player.queue.upcoming.count < 2)
                }
            }
            .environment(\.editMode, .constant(.active))
        }
    }
}
