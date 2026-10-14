import AbsWatchCore
import Foundation
import WatchConnectivity

/// WatchConnectivity link to the iPhone app, used only to get pairing grants. Everything else talks to the server directly.
final class PhoneLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = PhoneLink()

    enum LinkError: LocalizedError {
        case unavailable
        case unreachable

        var errorDescription: String? {
            switch self {
            case .unavailable: return "WatchConnectivity is not available"
            case .unreachable: return "iPhone not reachable. Keep it nearby and unlocked, with Audiobookshelf logged in."
            }
        }
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Asks the iPhone app to authorize a device code for this watch.
    func requestPairing() async throws -> DevicePairing.PhoneGrant {
        guard WCSession.isSupported() else { throw LinkError.unavailable }
        let session = WCSession.default
        if session.activationState != .activated { session.activate() }
        guard session.isReachable else { throw LinkError.unreachable }

        let reply: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(["type": "pairRequest"], replyHandler: { reply in
                continuation.resume(returning: reply)
            }, errorHandler: { error in
                continuation.resume(throwing: error)
            })
        }
        return try DevicePairing.PhoneGrant(reply: reply)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error { SpikeLog.post("phone link activation failed: \(error.localizedDescription)") }
    }
}
