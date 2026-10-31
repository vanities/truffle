import SwiftUI
import os

/// The toolbar's sort button: a list's orders, with a check by the one in use.
struct SortMenu<Order: SortOrder>: View {
    @Binding var selection: Order

    var body: some View {
        Menu {
            Picker("Sort By", selection: $selection) {
                ForEach(Order.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityValue(selection.label)
        .onChange(of: selection) { old, new in
            Logger.ui.info("[sort] \(Order.defaultsKey, privacy: .public): \(old.rawValue, privacy: .public) → \(new.rawValue, privacy: .public)")
        }
    }
}
