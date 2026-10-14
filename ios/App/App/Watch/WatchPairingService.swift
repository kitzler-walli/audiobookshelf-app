//
//  WatchPairingService.swift
//  Audiobookshelf
//
//  Gives the watch app a server session of its own via the device-code flow (server fork: /auth/device-code/*).
//  The watch asks over WatchConnectivity; this side requests a device code, authorizes it with the phone's login
//  and replies with only the server address and the device code. The watch then polls the server for its own
//  tokens, so the phone's tokens never leave the phone and the two sessions rotate independently.
//

import Foundation
import WatchConnectivity

class WatchPairingService: NSObject, WCSessionDelegate {
    static let shared = WatchPairingService()

    private struct DeviceCodeResponse: Decodable {
        let userCode: String
        let deviceCode: String
    }

    private struct AuthorizeResponse: Decodable {
        let success: Bool?
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            AbsLogger.error(message: "WatchPairingService: activation failed: \(error.localizedDescription)", error: error)
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Switching to another paired watch: activate for the new one
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["type"] as? String == "pairRequest" else {
            replyHandler(["error": "Unknown request"])
            return
        }
        Task {
            replyHandler(await self.pair())
        }
    }

    // MARK: - Pairing

    private func pair() async -> [String: Any] {
        // Copy primitives off the Realm object before any await (Realm objects are thread-confined)
        guard let config = Store.serverConfig else {
            return ["error": "Log in to your server in the Audiobookshelf app on your iPhone first"]
        }
        let address = config.address
        let serverName = config.name
        let username = config.username

        AbsLogger.info(message: "WatchPairingService: watch requested pairing for \(serverName)")

        guard let requestUrl = URL(string: "\(address)/auth/device-code/request") else {
            return ["error": "Invalid server address"]
        }
        var request = URLRequest(url: requestUrl)
        request.httpMethod = "POST"

        let code: DeviceCodeResponse
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                return ["error": status == 404 ? "Server does not support device pairing" : "Server error \(status) requesting a pairing code"]
            }
            code = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        } catch {
            AbsLogger.error(message: "WatchPairingService: device code request failed: \(error.localizedDescription)", error: error)
            return ["error": "Could not reach the server from the iPhone"]
        }

        // Authorize with the phone's own login (refreshes the phone's token on 401)
        let authorized = await withCheckedContinuation { continuation in
            ApiClient.postResourceWithTokenRefresh(endpoint: "api/device-code/authorize", parameters: ["userCode": code.userCode], decodable: AuthorizeResponse.self) { response in
                continuation.resume(returning: response?.success == true)
            }
        }
        guard authorized else {
            return ["error": "The iPhone could not authorize the watch"]
        }

        AbsLogger.info(message: "WatchPairingService: authorized device code for watch")
        return [
            "serverAddress": address,
            "serverName": serverName,
            "username": username,
            "deviceCode": code.deviceCode
        ]
    }
}
