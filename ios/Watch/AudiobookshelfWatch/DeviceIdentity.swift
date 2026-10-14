import Foundation

enum DeviceIdentity {
    /// Stable per-install device id, so the server does not close the phone's session when the watch starts one.
    static var deviceId: String {
        let key = "deviceId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "watch-" + UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    static var model: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
