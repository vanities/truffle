import AuthenticationServices
import SwiftUI
import os

/// Signing in happens on plex.tv in a browser sheet; Truffle only ever gets a token.
struct SignInView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(SeasonClock.self) private var season
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @Environment(\.onTintColor) private var onTint
    @State private var waiting = false
    @State private var problem: String?
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 44

    var body: some View {
        ZStack {
            season.theme.gradient.ignoresSafeArea()
            SeasonalBackdrop(theme: season.theme, density: 1.3).ignoresSafeArea()
            // The brighter end of a season's gradient (spring's pink, summer's yellow) sits under the
            // buttons and the fine print; the shade keeps white words readable on it.
            LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: .black.opacity(0.55), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            // One copy of the page that scrolls only when the largest text sizes need more than a screen.
            GeometryReader { geometry in
                ScrollView {
                    content
                        .frame(minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        // Always on the season's dark colors, so the glass and the tint take their dark forms.
        .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        VStack(spacing: 22) {
            Spacer()
            Image("Mark")
                .resizable()
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Truffle")
                    .font(.system(size: titleSize, weight: .heavy, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Text("Plex music, but sweeter.")
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 5, y: 1)
            Spacer()
            VStack(spacing: 14) {
                if let problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
                Button {
                    Task { await signIn() }
                } label: {
                    Group {
                        if waiting {
                            HStack(spacing: 10) {
                                ProgressView().tint(onTint)
                                Text("Waiting on Plex…")
                            }
                        } else {
                            Text("Sign in with Plex")
                        }
                    }
                    .font(.headline)
                    .foregroundStyle(onTint)
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(waiting)
                // A built-in library, so App Review (and anyone without a Plex server) can try it all.
                Button {
                    library.startDemo()
                } label: {
                    Text("Take it for a spin")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(waiting)
                Text("We never see your password. Pinky promise.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
    }

    private func signIn() async {
        waiting = true
        problem = nil
        defer { waiting = false }
        do {
            let (pin, url) = try await library.beginSignIn()
            let tasks = SignInTasks()
            // Polling catches the token and closes the browser sheet; closing the sheet by hand checks
            // once more and stops the polling.
            tasks.poll = Task {
                do {
                    try await library.waitForSignIn(pin: pin)
                    tasks.browser?.cancel()
                } catch {
                    Logger.auth.debug("[auth] polling stopped: \(error.localizedDescription, privacy: .public)")
                }
            }
            tasks.browser = Task {
                do {
                    _ = try await webAuthentication.authenticate(using: url, callbackURLScheme: "truffle", preferredBrowserSession: .shared)
                } catch {
                    Logger.auth.info("[auth] browser closed: \(error.localizedDescription, privacy: .public)")
                }
                if !library.isSignedIn { _ = await library.checkSignIn(pin: pin) }
                tasks.poll?.cancel()
            }
            await tasks.browser?.value
            await tasks.poll?.value
            if !library.isSignedIn { problem = "No luck. Try again?" }
        } catch {
            problem = error.localizedDescription
            Logger.auth.error("[auth] sign in failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

@MainActor
private final class SignInTasks {
    var poll: Task<Void, Never>?
    var browser: Task<Void, Never>?
}
