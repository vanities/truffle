import SwiftUI
import os

/// The season's weather behind the top of Home and the sign-in screen: falling leaves, snow and
/// flakes, petals and butterflies, fireflies, embers under a crescent moon, string lights and Santa's
/// sleigh, confetti and fireworks, hearts, shamrocks and a rainbow.
///
/// Everything moving is drawn in one Canvas per frame (`SeasonScene`), as a function of time, on the
/// season's clock (`SeasonalTimeline`).
struct SeasonalBackdrop: View {
    let theme: SeasonTheme
    var density: Double = 1
    /// Where the open sky starts in this view, just under the status bar.
    var skyTop: CGFloat = 64
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ZStack {
            if settings.seasonalEffects, theme.decor.contains(.moon) {
                // Still, so it's drawn once instead of every frame.
                Canvas { canvas, size in
                    SeasonScene.drawMoon(in: &canvas, size: size, skyTop: skyTop)
                }
            }
            SeasonalTimeline(name: "\(theme.id) sky") { time, still in
                Canvas(rendersAsynchronously: true) { canvas, size in
                    guard settings.seasonalEffects else { return }
                    SeasonScene(theme: theme, density: density, skyTop: skyTop, size: size, time: time, still: still)
                        .draw(in: &canvas)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// False while the screen's seasonal touches are out of sight: scrolled away, or under the player.
    @Entry var seasonalInView = true
}

/// The clock every seasonal animation runs on: 30 fps while someone can see it, stopped when nobody can
/// (effects off, scrolled away or covered (`seasonalInView`), another tab or page on top, the app in the
/// background). Reduce Motion gets one still frame instead.
struct SeasonalTimeline<Content: View>: View {
    /// What the log calls it.
    let name: String
    @ViewBuilder let content: (_ time: TimeInterval, _ still: Bool) -> Content
    @Environment(AppSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.seasonalInView) private var inView
    @State private var isOnScreen = false

    var body: some View {
        let running = settings.seasonalEffects && !reduceMotion && inView && isOnScreen && scenePhase == .active
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running)) { context in
            content(reduceMotion ? 12 : context.date.timeIntervalSinceReferenceDate, reduceMotion)
        }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .onChange(of: running, initial: true) { _, running in
            Logger.ui.debug("[season] \(name, privacy: .public) \(running ? "running" : "paused", privacy: .public) (on: \(settings.seasonalEffects), reduce motion: \(reduceMotion), in view: \(inView), shown: \(isOnScreen))")
        }
    }
}

/// The occasional events' schedules. In debug builds `-TruffleFlyby YES`, `-TruffleFireworks YES`,
/// `-TruffleRainbow YES`, `-TruffleGust YES`, `-TruffleBat YES` and `-TruffleShootingStar YES` start the
/// first one two seconds after the backdrop first draws, then repeat every 14 seconds, so they can be
/// captured.
enum SeasonEvents {
    static let flyby = schedule(.flyby, debugKey: "TruffleFlyby")
    static let fourthFireworks = schedule(.fourthFireworks, debugKey: "TruffleFireworks")
    static let newYearFireworks = schedule(.newYearFireworks, debugKey: "TruffleFireworks")
    static let rainbow = schedule(.rainbow, debugKey: "TruffleRainbow")
    static let gust = schedule(.gust, debugKey: "TruffleGust")
    static let bat = schedule(.bat, debugKey: "TruffleBat")
    static let shootingStar = schedule(.shootingStar, debugKey: "TruffleShootingStar")

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
