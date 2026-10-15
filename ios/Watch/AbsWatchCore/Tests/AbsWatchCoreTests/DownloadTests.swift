import Foundation
import Testing
@testable import AbsWatchCore

private func track(_ index: Int, start: Double, duration: Double, size: Int64, ext: String = "mp3") -> AudioTrack {
    AudioTrack(index: index, startOffset: start, duration: duration, title: nil, contentUrl: "/api/items/li1/file/\(index)",
               mimeType: nil, metadata: .init(filename: nil, ext: ".\(ext)", size: size))
}

private let mb: Int64 = 1 << 20

/// Two 1 h mp3 tracks of 60 MiB each (1 MiB per minute).
private func book(scope: DownloadScope = .full, windowStart: Double = 0) -> DownloadedItem {
    DownloadedItem(libraryItemId: "li1", episodeId: nil, isPodcast: false, title: "Book", author: nil, duration: 7200, chapters: [],
                   tracks: [track(2, start: 3600, duration: 3600, size: 60 * mb), track(1, start: 0, duration: 3600, size: 60 * mb)],
                   scope: scope, windowStart: windowStart)
}

@Suite struct DownloadedItemTests {
    @Test func fullScopePlansEveryByteInPlaybackOrder() {
        let plans = book().plan()
        #expect(plans.map(\.trackIndex) == [1, 2])
        #expect(plans.allSatisfy { $0.ranges == [0..<60 * mb] })
        #expect(DownloadedItem.plannedBytes(plans) == 120 * mb)
    }

    @Test func aheadScopePlansTheWindowFromItsStart() {
        let plans = book(scope: .ahead(seconds: 1800), windowStart: 3000).plan()
        // 10 min of track 1, 20 min of track 2
        #expect(plans.map(\.trackIndex) == [1, 2])
    }

    @Test func playableEndRunsThroughCompleteTracks() {
        let item = book()
        let end = item.playableEnd(from: 100) { _ in ByteRangeIndex([0..<60 * mb]) }
        #expect(end == 7200)
    }

    @Test func playableEndStopsBeforeTheEdgeOfAPartialTrack() {
        let item = book()
        // Track 1 complete, track 2 has its first 30 MiB (30 min)
        let end = item.playableEnd(from: 100) { $0.index == 1 ? ByteRangeIndex([0..<60 * mb]) : ByteRangeIndex([0..<30 * mb]) }
        #expect(end > 3600 + 29 * 60)
        #expect(end < 3600 + 30 * 60)
    }

    @Test func aheadDownloadIsPlayableFromTheListeningPosition() {
        // 20 h m4b of 600 MiB, listening at 5 h, next hour planned from 1 min before
        let item = DownloadedItem(libraryItemId: "li1", episodeId: nil, isPodcast: false, title: "Book", author: nil, duration: 72000, chapters: [],
                                  tracks: [track(1, start: 0, duration: 72000, size: 600 * mb, ext: "m4b")],
                                  scope: .ahead(seconds: 3600), windowStart: 18000 - 60)
        let present = ByteRangeIndex(item.plan()[0].ranges)
        let end = item.playableEnd(from: 18000) { _ in present }
        #expect(end > 18000 + 55 * 60)
    }

    @Test func nothingIsPlayableInAHole() {
        let item = book()
        let present = ByteRangeIndex([0..<mb, 40 * mb..<60 * mb])
        #expect(item.playableEnd(from: 20 * 60) { _ in present } == 20 * 60)
        // Inside the downloaded part, but too close to its start to trust the bitrate estimate
        #expect(item.playableEnd(from: 40 * 60 + 1) { _ in present } == 40 * 60 + 1)
        #expect(item.playableEnd(from: 45 * 60) { _ in present } == 3600)
    }

    @Test func mp4NeedsItsTailForTheIndex() {
        let item = DownloadedItem(libraryItemId: "li1", episodeId: nil, isPodcast: false, title: "Book", author: nil, duration: 3600, chapters: [],
                                  tracks: [track(1, start: 0, duration: 3600, size: 60 * mb, ext: "m4b")], scope: .full, windowStart: 0)
        #expect(item.playableEnd(from: 0) { _ in ByteRangeIndex([0..<30 * mb]) } == 0)
        #expect(item.playableEnd(from: 0) { _ in ByteRangeIndex([0..<30 * mb, 59 * mb..<60 * mb]) } > 25 * 60)
    }

    @Test func presentBytesCountsOnlyPlannedRanges() {
        let plans = [WindowPlanner.TrackPlan(trackIndex: 1, ranges: [0..<10 * mb])]
        let present = DownloadedItem.presentBytes(plans) { _ in ByteRangeIndex([5 * mb..<20 * mb]) }
        #expect(present == 5 * mb)
    }

    @Test func storeRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "dl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DownloadStore(root: root)
        var item = book(scope: .ahead(seconds: 3600), windowStart: 120)
        item.position = 300
        try store.save(item)
        let loaded = store.loadAll()
        #expect(loaded.map(\.id) == [item.id])
        #expect(loaded.first?.position == 300)
        #expect(loaded.first?.scope == .ahead(seconds: 3600))
        #expect(loaded.first?.tracks == item.tracks)
        store.delete(key: item.id)
        #expect(store.loadAll().isEmpty)
    }
}

extension StubbedNetwork {
@Suite struct LocalSessionTests {
    private let credentials = Credentials(serverAddress: URL(string: "https://abs.example.com")!, serverName: nil, username: nil, accessToken: "a1", refreshToken: "r1")
    private let directory = FileManager.default.temporaryDirectory.appending(path: "ls-\(UUID().uuidString)")

    init() {
        StubProtocol.requests = []
        StubProtocol.handler = nil
    }

    private func client() -> AbsClient {
        let tokens = TokenManager(credentials: credentials, store: MemoryStore(credentials), session: StubProtocol.session())
        return AbsClient(tokens: tokens, deviceId: "watch-test", clientVersion: "0", session: StubProtocol.session())
    }

    private func json(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @Test func uploadsTheSessionWithDeviceInfo() async throws {
        nonisolated(unsafe) var sent: [String: Any] = [:]
        StubProtocol.handler = { request in
            #expect(request.url?.path == "/api/session/local")
            sent = self.json(request)
            return (200, Data("OK".utf8))
        }
        let store = LocalSessionStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sync = LocalSessionSync(session: LocalSession(item: book(), startTime: 60), client: client(), store: store, model: "Watch")
        await sync.addListened(30)
        #expect(await sync.sync(currentTime: 90) == .synced)

        #expect(sent["libraryItemId"] as? String == "li1")
        #expect(sent["mediaType"] as? String == "book")
        #expect(sent["playMethod"] as? Int == PlayMethod.local)
        #expect(sent["currentTime"] as? Double == 90)
        #expect(sent["timeListening"] as? Double == 30)
        #expect((sent["deviceInfo"] as? [String: Any])?["deviceId"] as? String == "watch-test")
        #expect((sent["date"] as? String)?.count == 10)
    }

    @Test func keepsSessionsOnDiskUntilTheServerHasThem() async throws {
        StubProtocol.handler = { _ in (502, Data()) }
        let store = LocalSessionStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sync = LocalSessionSync(session: LocalSession(item: book(), startTime: 0), client: client(), store: store, model: "Watch")
        await sync.addListened(120)
        await sync.close(currentTime: 120)

        let pending = store.all()
        #expect(pending.count == 1)
        #expect(pending.first?.isClosed == true)
        #expect(pending.first?.timeListening == 120)

        StubProtocol.handler = { _ in (200, Data("OK".utf8)) }
        #expect(await store.uploadPending(client: client(), model: "Watch") == 1)
        #expect(store.all().isEmpty)
    }

    @Test func doesNotUploadTheActiveSession() async throws {
        StubProtocol.handler = { _ in (200, Data("OK".utf8)) }
        let store = LocalSessionStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = LocalSession(item: book(), startTime: 0)
        try store.save(session)
        #expect(await store.uploadPending(client: client(), model: "Watch", excluding: session.id) == 0)
        #expect(store.all().count == 1)
    }

    @Test func dropsSessionsForDeletedItems() async throws {
        StubProtocol.handler = { _ in (500, Data("Media item not found".utf8)) }
        let store = LocalSessionStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(LocalSession(item: book(), startTime: 0))
        await store.uploadPending(client: client(), model: "Watch")
        #expect(store.all().isEmpty)
    }
}
}
