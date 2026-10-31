import SwiftUI

extension View {
    /// `lines` at the regular text sizes and `largeLines` (nil: as many as it takes) at the accessibility
    /// sizes, so big text in a row or tile wraps instead of being cut to a few letters.
    func lineLimit(_ lines: Int, atAccessibilitySizes largeLines: Int?) -> some View {
        modifier(AdaptiveLineLimit(lines: lines, largeLines: largeLines))
    }
}

private struct AdaptiveLineLimit: ViewModifier {
    let lines: Int
    let largeLines: Int?
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content.lineLimit(typeSize.isAccessibilitySize ? largeLines : lines)
    }
}
