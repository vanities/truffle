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
                            if placement != .inline {
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now playing: \(track.title) by \(track.artist)")
                .accessibilityHint("Opens the player")
                if player.isLoading {
                    ProgressView().frame(width: 44, height: 44)
                } else {
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                }
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next")
            }
            .padding(.horizontal, 12)
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
