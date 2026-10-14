import Foundation

/// Watch side of the device-code login (server fork endpoints /auth/device-code/*).
/// The iPhone requests and authorizes the code with its own login and only passes the device code over;
/// the watch then polls for a session of its own, so the phone's tokens never leave the phone.
public enum DevicePairing {
    /// What the iPhone sends to the watch.
    public struct PhoneGrant: Sendable, Equatable {
        public let serverAddress: URL
        public let serverName: String?
        public let username: String?
        public let deviceCode: String

        public init(serverAddress: URL, serverName: String?, username: String?, deviceCode: String) {
            self.serverAddress = serverAddress
            self.serverName = serverName
            self.username = username
            self.deviceCode = deviceCode
        }

        /// Parses the WatchConnectivity reply of the iPhone app.
        public init(reply: [String: Any]) throws {
            if let error = reply["error"] as? String { throw PairingError.phone(error) }
            guard let address = (reply["serverAddress"] as? String).flatMap(URL.init(string:)),
                  let deviceCode = reply["deviceCode"] as? String
            else { throw PairingError.phone("Unexpected reply from iPhone") }
            self.init(serverAddress: address, serverName: reply["serverName"] as? String, username: reply["username"] as? String, deviceCode: deviceCode)
        }
    }

    public enum PairingError: LocalizedError, Equatable {
        case phone(String)
        case expired
        case timedOut
        case server(Int)

        public var errorDescription: String? {
            switch self {
            case .phone(let message): return message
            case .expired: return "Pairing code expired, try again"
            case .timedOut: return "Server did not confirm the pairing in time"
            case .server(let status): return "Server error \(status) while pairing"
            }
        }
    }

    private struct PollStatus: Decodable {
        let status: String?
    }

    /// Polls until the server hands out the watch's own tokens.
    public static func pollForCredentials(grant: PhoneGrant, session: URLSession = .shared, interval: Duration = .seconds(2), timeout: Duration = .seconds(120)) async throws -> Credentials {
        var request = URLRequest(url: grant.serverAddress.appending(path: "auth/device-code/poll"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["deviceCode": grant.deviceCode])

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200:
                if let user = try? JSONDecoder().decode(LoginResponse.self, from: data).user,
                   let accessToken = user.accessToken, let refreshToken = user.refreshToken {
                    return Credentials(serverAddress: grant.serverAddress, serverName: grant.serverName,
                                       username: user.username ?? grant.username, accessToken: accessToken, refreshToken: refreshToken)
                }
                guard (try? JSONDecoder().decode(PollStatus.self, from: data))?.status == "pending" else {
                    throw PairingError.server(status)
                }
            case 410:
                throw PairingError.expired
            case 429:
                break // rate limited, keep polling
            default:
                throw PairingError.server(status)
            }
            try await Task.sleep(for: interval)
        }
        throw PairingError.timedOut
    }
}
