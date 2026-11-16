import SwiftUI

/// Album (or playlist, or artist) art from the server, with a soft placeholder while it loads.
struct ArtworkView: View {
    let thumb: String?
    var pixels = 300
    var cornerRadius: CGFloat = 8
    var circle = false
    var placeholderSymbol = "music.note"
    @Environment(MusicLibrary.self) private var library
    @State private var image: UIImage?

    var body: some View {
        // The art is an overlay so it never sizes the view: a cover that isn't square fills the frame it's
        // given and is clipped to it, whether that frame is fixed or a grid column's width.
        LinearGradient(colors: [Color(.secondarySystemFill), Color(.tertiarySystemFill)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Image(systemName: placeholderSymbol)
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
        // Keyed on the connection too: art asked for before the server answered loads once it does.
        .task(id: ArtworkRequest(thumb: thumb, endpoint: library.endpoint?.baseURL)) {
            guard let thumb, let client = library.client else {
                image = nil
                return
            }
            let loaded = await ArtworkCache.shared.image(thumb: thumb, size: pixels, client: client)
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
        .accessibilityHidden(true)
    }
}

/// The cover on top of an album or playlist: most of a phone's width, up to 340 pt. A phone on its side
/// keeps it to 250 pt, or the cover takes the screen and the songs start below it.
enum HeaderCover {
    static func side(pageWidth: CGFloat, compactHeight: Bool) -> CGFloat {
        guard pageWidth > 0 else { return 250 }
        return min((pageWidth * 0.72).rounded(), compactHeight ? 250 : 340)
    }
}

extension EnvironmentValues {
    @Entry var headerCoverSide: CGFloat = HeaderCover.side(pageWidth: 0, compactHeight: false)
}

extension View {
    /// On the page: measures its width, so the cover inside knows its size.
    func measuresHeaderCover() -> some View { modifier(HeaderCoverMeasure()) }

    /// On the cover. A fixed frame on purpose: sized with `containerRelativeFrame` inside a List row, the
    /// accessibility audit reported the text under the cover as clipped.
    func headerCoverSize() -> some View { modifier(HeaderCoverSize()) }
}

private struct HeaderCoverMeasure: ViewModifier {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .environment(\.headerCoverSide, HeaderCover.side(pageWidth: width, compactHeight: verticalSizeClass == .compact))
    }
}

private struct HeaderCoverSize: ViewModifier {
    @Environment(\.headerCoverSide) private var side

    func body(content: Content) -> some View {
        content.frame(width: side, height: side)
    }
}

private struct ArtworkRequest: Hashable {
    let thumb: String?
    let endpoint: URL?
}
