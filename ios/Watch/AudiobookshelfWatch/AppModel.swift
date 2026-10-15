import AbsWatchCore
import Foundation
import Observation

/// The watch's server connection: pairing with the iPhone, the watch's own tokens and the API client.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    private let store = KeychainCredentialStore()
    /// Listening on downloaded items, waiting for upload
    let localSessions = LocalSessionStore(directory: URL.applicationSupportDirectory.appending(path: "LocalSessions", directoryHint: .isDirectory))
    private var isUploading = false
    private(set) var tokens: TokenManager?
    private(set) var credentials: Credentials?
    private(set) var pairingStatus: String?
    private(set) var isPairing = false

    var isPaired: Bool { tokens != nil }

    var client: AbsClient? {
        guard let tokens else { return nil }
        return AbsClient(tokens: tokens, deviceId: DeviceIdentity.deviceId, clientVersion: DeviceIdentity.appVersion)
    }

    private init() {
        if let saved = store.load() {
            credentials = saved
            tokens = TokenManager(credentials: saved, store: store)
        }
    }

    /// Gets a device code authorized by the iPhone app, then polls the server for this watch's own session.
    func pair() async {
        isPairing = true
        defer { isPairing = false }
        do {
            pairingStatus = "Asking iPhone…"
            let grant = try await PhoneLink.shared.requestPairing()
            AppLog.shared.add("iPhone authorized a device code for \(grant.serverAddress.host() ?? "?")")
            pairingStatus = "Waiting for server…"
            let credentials = try await DevicePairing.pollForCredentials(grant: grant)
            try store.save(credentials)
            self.credentials = credentials
            tokens = TokenManager(credentials: credentials, store: store)
            pairingStatus = nil
            AppLog.shared.add("paired as \(credentials.username ?? "?") on \(credentials.serverName ?? credentials.serverAddress.absoluteString)")
        } catch {
            pairingStatus = error.localizedDescription
            AppLog.shared.add("pairing failed: \(error.localizedDescription)")
        }
    }

    /// Uploads listening done on downloads, and continues downloads, e.g. when the app comes back online.
    func uploadPendingSessions() async {
        guard let client, !isUploading else { return }
        isUploading = true
        defer { isUploading = false }
        let active = PlayerController.shared.localSessionId
        let uploaded = await localSessions.uploadPending(client: client, model: DeviceIdentity.model, excluding: active)
        if uploaded > 0 { AppLog.shared.add("uploaded \(uploaded) offline listening session(s)") }
    }

    /// Downloads belong to this account, so they are removed too. Offline listening is uploaded first if possible.
    func signOut() async {
        await PlayerController.shared.stop()
        await uploadPendingSessions()
        DownloadManager.shared.removeAll()
        // Whatever could not be uploaded belongs to this account and must not go to the next one
        for session in localSessions.all() { localSessions.delete(id: session.id) }
        await tokens?.signOut()
        forgetSession()
        AppLog.shared.add("signed out")
    }

    /// Called when the server rejected the refresh token (30 days unused, password change, logout everywhere).
    func handle(_ error: Error) {
        if case TokenManager.TokenError.signedOut = error {
            AppLog.shared.add("server ended this watch's session")
            forgetSession()
        }
    }

    private func forgetSession() {
        tokens = nil
        credentials = nil
    }
}
