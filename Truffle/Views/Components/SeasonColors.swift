import SwiftUI

extension RGB {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

extension SeasonTheme {
    var accentColor: Color { accent.color }
    var colors: [Color] { palette.map(\.color) }
    /// Deep to bright, for cards and the home header.
    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// The small caps line over the greeting: "HALLOWEEN · FALL".
    var label: String {
        moment == nil ? title.uppercased() : "\(title.uppercased()) · \(season.title.uppercased())"
    }
}
