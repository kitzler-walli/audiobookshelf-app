import SwiftUI

struct LogView: View {
    private let log = AppLog.shared

    var body: some View {
        List {
            if !log.lines.isEmpty {
                ShareLink(item: report, subject: Text("Audiobookshelf watch log"), message: Text(report)) {
                    Label("Send log", systemImage: "square.and.arrow.up")
                }
            }
            ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 11, design: .monospaced))
            }
        }
        .navigationTitle("Log")
    }

    /// Oldest entry first, with what is needed to make sense of it.
    private var report: String {
        let header = [
            "Audiobookshelf watch log",
            "Version \(DeviceIdentity.appVersion) (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")), \(DeviceIdentity.model)",
            "Sent \(Date().formatted(date: .numeric, time: .standard))",
            ""
        ]
        return (header + log.lines.reversed()).joined(separator: "\n")
    }
}
