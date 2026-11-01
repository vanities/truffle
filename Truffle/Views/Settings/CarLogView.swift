import SwiftUI

/// Settings → Car Log: each time the car might have started music, newest first, to share in a bug report.
struct CarLogView: View {
    private let log = CarLog.shared
    @State private var confirmingClear = false

    var body: some View {
        List {
            if log.entries.isEmpty {
                ContentUnavailableView("Nothing Yet", systemImage: "car",
                                       description: Text("Go for a drive. Every time the car could start music, it shows up here."))
            }
            ForEach(log.entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.text)
                    Text(entry.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .navigationTitle("Car Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !log.entries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: log.text, subject: Text("Truffle car log")) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Clear", role: .destructive) { confirmingClear = true }
                }
            }
        }
        .confirmationDialog("Clear the car log?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { log.clear() }
        }
    }
}
