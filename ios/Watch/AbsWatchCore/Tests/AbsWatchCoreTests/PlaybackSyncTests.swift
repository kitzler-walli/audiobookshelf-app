import Foundation
import Testing
@testable import AbsWatchCore

extension StubbedNetwork {
@Suite struct PlaybackSyncTests {
    private let credentials = Credentials(serverAddress: URL(string: "https://abs.example.com")!, serverName: nil, username: nil, accessToken: "a1", refreshToken: "r1")

    init() {
        StubProtocol.requests = []
        StubProtocol.handler = nil
    }

    private func makeSync() -> PlaybackSync {
        let tokens = TokenManager(credentials: credentials, store: MemoryStore(credentials), session: StubProtocol.session())
        let client = AbsClient(tokens: tokens, deviceId: "watch-test", clientVersion: "0", session: StubProtocol.session())
        return PlaybackSync(client: client, sessionId: "s1", duration: 3600)
    }

    private func body(_ request: URLRequest) -> [String: Double] {
        guard let stream = request.httpBodyStream else { return (try? JSONDecoder().decode([String: Double].self, from: request.httpBody ?? Data())) ?? [:] }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return (try? JSONDecoder().decode([String: Double].self, from: data)) ?? [:]
    }

    @Test func syncsListenedTimeAndPosition() async {
        var sent: [String: Double] = [:]
        StubProtocol.handler = { request in
            #expect(request.url?.path == "/api/session/s1/sync")
            sent = self.body(request)
            return (200, Data("OK".utf8))
        }
        let reporter = makeSync()
        await reporter.addListened(12.5)
        #expect(await reporter.sync(currentTime: 100) == .synced)
        #expect(sent == ["currentTime": 100, "timeListened": 12.5, "duration": 3600])
        #expect(await reporter.unsyncedSeconds == 0)
    }

    @Test func keepsListenedTimeWhenSyncFails() async {
        StubProtocol.handler = { _ in (500, Data()) }
        let reporter = makeSync()
        await reporter.addListened(10)
        #expect(await reporter.sync(currentTime: 50) == .failed)
        await reporter.addListened(5)
        #expect(await reporter.unsyncedSeconds == 15)

        var sent: [String: Double] = [:]
        StubProtocol.handler = { request in
            sent = self.body(request)
            return (200, Data())
        }
        #expect(await reporter.sync(currentTime: 65) == .synced)
        #expect(sent["timeListened"] == 15)
    }

    @Test func reportsVanishedSessionAndCarriesTimeToNewOne() async {
        StubProtocol.handler = { _ in (404, Data("Not Found".utf8)) }
        let reporter = makeSync()
        await reporter.addListened(8)
        #expect(await reporter.sync(currentTime: 10) == .sessionGone)

        var path = ""
        StubProtocol.handler = { request in
            path = request.url?.path ?? ""
            return (200, Data())
        }
        await reporter.replaceSession(id: "s2")
        #expect(await reporter.sync(currentTime: 12) == .synced)
        #expect(path == "/api/session/s2/sync")
    }

    @Test func onlySyncsWhenDue() async {
        StubProtocol.handler = { _ in (200, Data()) }
        let reporter = makeSync()
        #expect(await reporter.syncIfDue(currentTime: 1) == .synced)
        #expect(await reporter.syncIfDue(currentTime: 2) == nil)
        #expect(StubProtocol.requests.count == 1)
    }

    @Test func closeSendsFinalProgress() async {
        var sent: [String: Double] = [:]
        StubProtocol.handler = { request in
            #expect(request.url?.path == "/api/session/s1/close")
            sent = self.body(request)
            return (200, Data())
        }
        let reporter = makeSync()
        await reporter.addListened(3)
        await reporter.close(currentTime: 200)
        #expect(sent == ["currentTime": 200, "timeListened": 3, "duration": 3600])
    }
}
}
