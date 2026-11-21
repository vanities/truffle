import UIKit

/// The car's Library: artists by first letter. One list of every artist was a long scroll with the truck
/// moving, and CarPlay stops showing rows past `CPListTemplate.maximumItemCount`, so the letters go in a grid
/// and each opens its own short list.
enum CarLetters {
    struct Group: Equatable, Sendable {
        let letter: String
        let artists: [Artist]
    }

    /// A to Z, then `#` for numbers, symbols and other scripts. Filed like the phone's index, by Plex's sort
    /// name ("The Lumineers" is under L); artists keep the library's order inside a letter.
    static func groups(_ artists: [Artist]) -> [Group] {
        let byLetter = Dictionary(grouping: artists) { IndexLetters.letter(for: $0.sortTitle ?? $0.title) }
        let letters = byLetter.keys.sorted { lhs, rhs in
            if (lhs == IndexLetters.other) != (rhs == IndexLetters.other) { return rhs == IndexLetters.other }
            return lhs < rhs
        }
        return letters.map { Group(letter: $0, artists: byLetter[$0] ?? []) }
    }

    /// The groups split into as few image rows as CarPlay allows (`CPMaximumNumberOfGridImages` tiles each, 24
    /// on iOS 27.2), evenly, so the last one isn't a stub. Each wraps onto as many lines as the car's screen
    /// needs.
    static func rows(_ groups: [Group], atMost limit: Int) -> [[Group]] {
        guard !groups.isEmpty else { return [] }
        let limit = max(1, limit)
        let count = (groups.count + limit - 1) / limit
        let size = (groups.count + count - 1) / count
        return stride(from: 0, to: groups.count, by: size).map { Array(groups[$0..<min($0 + size, groups.count)]) }
    }

    /// Tiles are drawn this big (CarPlay scales them to fit); its 220 pt maximum at a car's scale would be
    /// 47 MB of letters.
    static let tileSide: CGFloat = 96

    /// A tile with the letter on it, drawn at the car screen's scale: CarPlay's image rows take pictures, not
    /// text.
    static func tile(_ letter: String, size: CGSize, scale: CGFloat, color: UIColor) -> UIImage {
        let side = max(24, min(size.width, size.height, tileSide))
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(1, scale)
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            color.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: side, height: side), cornerRadius: side * 0.22).fill()
            let base = UIFont.systemFont(ofSize: side * 0.56, weight: .bold)
            let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: base.pointSize) } ?? base
            let text = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: UIColor.white])
            let bounds = text.size()
            text.draw(at: CGPoint(x: (side - bounds.width) / 2, y: (side - bounds.height) / 2))
        }
    }
}
