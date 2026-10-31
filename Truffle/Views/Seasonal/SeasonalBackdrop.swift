import SwiftUI
import os

/// The season's weather behind the top of Home and the sign-in screen: falling leaves, snow and
/// flakes, petals and butterflies, fireflies, embers under a crescent moon, string lights and Santa's
/// sleigh, confetti and fireworks, hearts, shamrocks and a rainbow.
///
/// Everything moving is drawn in one Canvas per frame (`SeasonScene`), as a function of time, at 30 fps.
/// The clock stops when nobody can see it: effects off, Reduce Motion (a still frame instead), scrolled
/// away or covered (`isActive`), another tab or page on top, or the app in the background.
struct SeasonalBackdrop: View {
    let theme: SeasonTheme
    var density: Double = 1
    /// Where the open sky starts in this view, just under the status bar.
    var skyTop: CGFloat = 64
    /// False while it's out of sight (scrolled away, under the player).
    var isActive = true
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false

    var body: some View {
        let running = settings.seasonalEffects && !reduceMotion && isActive && isOnScreen && scenePhase == .active
        ZStack {
            if settings.seasonalEffects, theme.decor.contains(.moon) {
                // Still, so it's drawn once instead of every frame.
                Canvas { canvas, size in
                    SeasonScene.drawMoon(in: &canvas, size: size, skyTop: skyTop)
                }
            }
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running)) { context in
                Canvas(rendersAsynchronously: true) { canvas, size in
                    guard settings.seasonalEffects else { return }
                    let time = reduceMotion ? 12.0 : context.date.timeIntervalSinceReferenceDate
                    SeasonScene(theme: theme, density: density, skyTop: skyTop, size: size, time: time, still: reduceMotion)
                        .draw(in: &canvas)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .onChange(of: running, initial: true) { _, running in
            Logger.ui.debug("[season] \(theme.id, privacy: .public) effects \(running ? "running" : "paused", privacy: .public) (on: \(settings.seasonalEffects), reduce motion: \(reduceMotion), in view: \(isActive), shown: \(isOnScreen))")
        }
    }
}

/// The occasional events' schedules. In debug builds `-TruffleFlyby YES`, `-TruffleFireworks YES` and
/// `-TruffleRainbow YES` start the first one two seconds after the backdrop first draws, then repeat
/// every 14 seconds, so they can be captured.
enum SeasonEvents {
    static let flyby = schedule(.flyby, debugKey: "TruffleFlyby")
    static let fourthFireworks = schedule(.fourthFireworks, debugKey: "TruffleFireworks")
    static let newYearFireworks = schedule(.newYearFireworks, debugKey: "TruffleFireworks")
    static let rainbow = schedule(.rainbow, debugKey: "TruffleRainbow")

    private static func schedule(_ schedule: EventSchedule, debugKey: String) -> EventSchedule {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: debugKey) {
            Logger.ui.info("[season] -\(debugKey, privacy: .public): first one in 2 s, then every 14 s")
            return .rightAway(schedule, now: firstDraw)
        }
        #endif
        return schedule
    }

    #if DEBUG
    private static let firstDraw = Date.now.timeIntervalSinceReferenceDate
    #endif
}
