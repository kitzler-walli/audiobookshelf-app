import AbsWatchCore
import Foundation
import Observation

/// The watch's server connection: pairing with the iPhone, the watch's own tokens and the API client.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    private let store = KeychainCredentialStore()
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
            SpikeLog.shared.add("iPhone authorized a device code for \(grant.serverAddress.host() ?? "?")")
            pairingStatus = "Waiting for server…"
            let credentials = try await DevicePairing.pollForCredentials(grant: grant)
            try store.save(credentials)
            self.credentials = credentials
            tokens = TokenManager(credentials: credentials, store: store)
            pairingStatus = nil
            SpikeLog.shared.add("paired as \(credentials.username ?? "?") on \(credentials.serverName ?? credentials.serverAddress.absoluteString)")
        } catch {
            pairingStatus = error.localizedDescription
            SpikeLog.shared.add("pairing failed: \(error.localizedDescription)")
        }
    }

    func signOut() async {
        await PlayerController.shared.stop()
        SpikeModel.shared.reset()
        await tokens?.signOut()
        forgetSession()
        SpikeLog.shared.add("signed out")
    }

    /// Called when the server rejected the refresh token (30 days unused, password change, logout everywhere).
    func handle(_ error: Error) {
        if case TokenManager.TokenError.signedOut = error {
            SpikeLog.shared.add("server ended this watch's session")
            forgetSession()
        }
    }

    private func forgetSession() {
        tokens = nil
        credentials = nil
    }
}
