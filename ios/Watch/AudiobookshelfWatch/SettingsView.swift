import AbsWatchCore
import SwiftUI

struct SettingsView: View {
    private let app = AppModel.shared
    @State private var confirmSignOut = false

    var body: some View {
        List {
            if let credentials = app.credentials {
                Section("Server") {
                    LabeledContent("Server", value: credentials.serverName ?? credentials.serverAddress.host() ?? "")
                    if let username = credentials.username {
                        LabeledContent("User", value: username)
                    }
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                }
            }
            Section("Diagnostics") {
                NavigationLink(value: Route.log) { Label("Log", systemImage: "doc.plaintext") }
                NavigationLink(value: Route.debug) { Label("Spike tests", systemImage: "wrench.and.screwdriver") }
                LabeledContent("Version", value: DeviceIdentity.appVersion)
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Sign out this watch? You can pair it again with the iPhone.", isPresented: $confirmSignOut) {
            Button("Sign out", role: .destructive) {
                Task {
                    await app.signOut()
                    Router.shared.path = NavigationPath()
                }
            }
        }
    }
}
