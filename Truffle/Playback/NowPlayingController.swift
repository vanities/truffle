import Foundation
import MediaPlayer
import UIKit
import os

/// Mirrors the player to the lock screen, Control Center, CarPlay's Now Playing, headphones and the
/// steering wheel's buttons.
@MainActor
final class NowPlayingController {
    private let player: PlayerEngine
    private let library: MusicLibrary
    private var artwork: (thumb: String, image: UIImage)?
    private var loadingThumb: String?

    init(player: PlayerEngine, library: MusicLibrary) {
        self.player = player
        self.library = library
    }

    func activate() {
        registerCommands()
        let previous = player.stateDidChange
        player.stateDidChange = { [weak self] in
            previous?()
            self?.update()
        }
        update()
        Logger.nowPlaying.info("[nowplaying] activated")
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.player.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            MainActor.assumeIsolated { self?.player.seek(to: position) }
            return .success
        }
        center.likeCommand.localizedTitle = "Love"
        center.likeCommand.localizedShortTitle = "Love"
        center.likeCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.player.toggleLike() }
            }
            return .success
        }
        for command in [center.skipForwardCommand, center.skipBackwardCommand, center.seekForwardCommand,
                        center.seekBackwardCommand, center.dislikeCommand, center.bookmarkCommand, center.ratingCommand,
                        center.changePlaybackRateCommand] {
            command.isEnabled = false
        }
    }

    func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = player.current else {
            center.nowPlayingInfo = nil
            artwork = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: player.queue.index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: player.queue.tracks.count,
        ]
        if let thumb = track.thumb {
            if let artwork, artwork.thumb == thumb {
                let image = artwork.image
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            } else {
                loadArtwork(thumb)
            }
        }
        center.nowPlayingInfo = info
        MPRemoteCommandCenter.shared().likeCommand.isActive = track.isLiked
        Logger.nowPlaying.debug("[nowplaying] \(track.title, privacy: .public) at \(Int(self.player.currentTime))s playing=\(self.player.isPlaying)")
    }

    private func loadArtwork(_ thumb: String) {
        guard loadingThumb != thumb, let client = library.client else { return }
        loadingThumb = thumb
        Task {
            let image = await ArtworkCache.shared.image(thumb: thumb, size: 600, client: client)
            loadingThumb = nil
            guard let image, player.current?.thumb == thumb else { return }
            artwork = (thumb, image)
            update()
        }
    }
}
