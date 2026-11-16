import SwiftUI
import os

/// One stop on the A to Z index: a letter, and the first row filed under it.
struct IndexMark: Equatable, Sendable {
    let letter: String
    let id: String
}

/// Which letter a name is filed under, and where each letter starts in a list that's already in order.
enum IndexLetters {
    /// Numbers, symbols and scripts that aren't A to Z.
    static let other = "#"
    /// Shorter lists than this fit on a screen or two: nothing to jump to.
    static let minimumItems = 40

    /// The first letter without its accents ("Édith" is under E), or `other`.
    static func letter(for name: String) -> String {
        guard let first = name.trimmingCharacters(in: .whitespaces).first,
              let base = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased().unicodeScalars.first,
              ("A"..."Z").contains(base) else { return other }
        return String(base)
    }

    /// The stops for a list in the order it's shown. Plex's order isn't strictly by first letter ("$oul" sits
    /// among the S's, 王若琳 after Z), so a letter stops only where it first appears, and `other` only at the
    /// top (numbers) and the bottom (other scripts): strays in between stay with the letter above them.
    static func marks<Item>(for items: [Item], id: (Item) -> String, name: (Item) -> String) -> [IndexMark] {
        guard items.count >= minimumItems else { return [] }
        var marks: [IndexMark] = []
        var seen: Set<String> = []
        var previous: String?
        var trailingOther: IndexMark?
        for item in items {
            let letter = letter(for: name(item))
            defer { previous = letter }
            guard letter != previous else { continue }
            if letter == other {
                if marks.isEmpty { marks.append(IndexMark(letter: other, id: id(item))) } else { trailingOther = IndexMark(letter: other, id: id(item)) }
            } else if seen.insert(letter).inserted {
                marks.append(IndexMark(letter: letter, id: id(item)))
                trailingOther = nil
            }
        }
        if let trailingOther { marks.append(trailingOther) }
        return marks.count > 1 ? marks : []
    }
}

/// The letters down the right edge of Artists and Albums: tap or slide to jump. One adjustable element to
/// VoiceOver, like the system's own index.
struct IndexBar: View {
    let marks: [IndexMark]
    let jump: (IndexMark) -> Void
    /// The stop under the finger, or the last one VoiceOver moved to.
    @State private var current: Int?
    @State private var touching = false

    /// The widest the strip gets; the letters sit in the page's own 16 pt margin.
    static let width: CGFloat = 20
    private static let rowHeight: CGFloat = 15

    var body: some View {
        GeometryReader { geometry in
            let height = min(geometry.size.height, CGFloat(marks.count) * Self.rowHeight)
            // Too short for every letter (a phone on its side): every other one becomes a dot, as iOS does.
            let thinned = height / CGFloat(marks.count) < 11
            VStack(spacing: 0) {
                ForEach(Array(marks.enumerated()), id: \.offset) { index, mark in
                    Text(thinned && index % 2 == 1 ? "•" : mark.letter)
                        .font(.caption2.weight(.semibold))
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .foregroundStyle(.tint)
            // Past this the letters outgrow the strip; the system's index stops growing too.
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .frame(width: Self.width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        touching = true
                        select(Int(value.location.y / height * CGFloat(marks.count)))
                    }
                    .onEnded { _ in touching = false }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .frame(width: Self.width)
        .sensoryFeedback(trigger: current) { _, _ in touching ? .selection : nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Index")
        .accessibilityValue(marks.indices.contains(current ?? 0) ? spoken(marks[current ?? 0].letter) : "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select((current ?? -1) + 1)
            case .decrement: select((current ?? 1) - 1)
            @unknown default: break
            }
        }
        .onChange(of: marks) { current = nil }
    }

    private func select(_ index: Int) {
        let index = min(max(index, 0), marks.count - 1)
        guard index != current, marks.indices.contains(index) else { return }
        current = index
        Logger.ui.debug("[index] jump to \(marks[index].letter, privacy: .public) (\(index + 1) of \(marks.count))")
        jump(marks[index])
    }

    private func spoken(_ letter: String) -> String { letter == IndexLetters.other ? "Numbers and symbols" : letter }
}
