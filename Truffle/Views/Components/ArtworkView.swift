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
        ZStack {
            LinearGradient(colors: [Color(.secondarySystemFill), Color(.tertiarySystemFill)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: placeholderSymbol)
                .font(.title2)
                .foregroundStyle(.tertiary)
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

private struct ArtworkRequest: Hashable {
    let thumb: String?
    let endpoint: URL?
}
