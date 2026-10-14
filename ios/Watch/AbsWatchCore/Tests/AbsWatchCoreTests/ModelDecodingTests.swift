import Foundation
import Testing
@testable import AbsWatchCore

/// Shapes taken from the server's toOldJSONMinified / toOldJSONExpanded / toJSONForClient.
@Suite struct ModelDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    @Test func itemsInProgressWithBookAndPodcast() throws {
        let response = try decode(ItemsInProgressResponse.self, """
        {"libraryItems":[
          {"id":"li1","mediaType":"book","progressLastUpdate":1760000000000,
           "media":{"id":"b1","metadata":{"title":"Dune","authorName":"Frank Herbert","narratorName":""},"duration":75600.5,"numTracks":1}},
          {"id":"li2","mediaType":"podcast","progressLastUpdate":1760000000000,
           "media":{"id":"p1","metadata":{"title":"Some Podcast","author":"Host"},"numEpisodes":3},
           "recentEpisode":{"id":"ep1","title":"Episode 12","index":1,"publishedAt":1759000000000}}
        ]}
        """)
        let book = response.libraryItems[0]
        #expect(book.title == "Dune")
        #expect(book.authorName == "Frank Herbert")
        #expect(book.media?.duration == 75600.5)
        let podcast = response.libraryItems[1]
        #expect(podcast.isPodcast)
        #expect(podcast.title == "Episode 12")
        #expect(podcast.authorName == "Some Podcast")
        #expect(podcast.recentEpisode?.id == "ep1")
    }

    @Test func libraryItemsPageWithStringPaging() throws {
        // limit/page come back as strings; they are not decoded
        let page = try decode(LibraryItemsPage.self, """
        {"results":[{"id":"li1","mediaType":"book","media":{"metadata":{"title":"A","authorName":""},"duration":10}}],
         "total":120,"limit":"30","page":"0","minified":true}
        """)
        #expect(page.total == 120)
        #expect(page.results.first?.authorName == nil)
    }

    @Test func expandedBookWithProgressAndChapters() throws {
        let item = try decode(LibraryItemDetail.self, """
        {"id":"li1","mediaType":"book",
         "media":{"metadata":{"title":"Dune","subtitle":null,"authorName":"Frank Herbert","narratorName":"Scott Brick","seriesName":"Dune #1","descriptionPlain":"Desert planet."},
                  "duration":75600.5,"chapters":[{"id":0,"start":0,"end":600.2,"title":"Prologue"},{"id":1,"start":600.2,"end":1200,"title":"One"}],
                  "tracks":[]},
         "userMediaProgress":{"id":"mp1","userId":"u1","libraryItemId":"li1","episodeId":null,"mediaItemId":"b1","mediaItemType":"book",
                              "duration":75600.5,"progress":0.25,"currentTime":18900.1,"isFinished":false,"hideFromContinueListening":false,
                              "lastUpdate":1760000000000,"startedAt":1750000000000,"finishedAt":null}}
        """)
        #expect(item.narratorName == "Scott Brick")
        #expect(item.media.chapters?.count == 2)
        #expect(item.userMediaProgress?.currentTime == 18900.1)
        #expect(item.userMediaProgress?.remaining == 75600.5 - 18900.1)
    }

    @Test func expandedItemWithoutProgress() throws {
        let item = try decode(LibraryItemDetail.self, """
        {"id":"li1","mediaType":"podcast","media":{"metadata":{"title":"Pod","author":"Host"},
         "episodes":[{"id":"e1","title":"Old","duration":100,"publishedAt":1},{"id":"e2","title":"New","duration":200,"publishedAt":2}]},
         "userMediaProgress":null}
        """)
        #expect(item.userMediaProgress == nil)
        #expect(item.authorName == "Host")
        #expect(item.episodes.map(\.id) == ["e2", "e1"])
    }

    @Test func playbackSessionOrdersTracksByOffset() throws {
        let session = try decode(PlaybackSession.self, """
        {"id":"s1","libraryItemId":"li1","episodeId":null,"displayTitle":"Dune","displayAuthor":"Frank Herbert",
         "currentTime":700,"duration":1500,"playMethod":0,"mediaType":"book","timeListening":0,
         "chapters":[{"id":0,"start":0,"end":750,"title":"One"}],
         "audioTracks":[
           {"index":4,"startOffset":1000,"duration":500,"title":"c.mp3","contentUrl":"/api/items/li1/file/3","mimeType":"audio/mpeg","metadata":{"filename":"c.mp3","ext":".mp3","size":5000}},
           {"index":1,"startOffset":0,"duration":600,"title":"a.mp3","contentUrl":"/api/items/li1/file/1","mimeType":"audio/mpeg","metadata":{"filename":"a.mp3","ext":".mp3","size":6000}},
           {"index":2,"startOffset":600,"duration":400,"title":"b.mp3","contentUrl":"/api/items/li1/file/2","mimeType":"audio/mpeg","metadata":{"filename":"b.mp3","ext":".mp3","size":4000}}
         ]}
        """)
        #expect(session.sortedTracks.map(\.index) == [1, 2, 4])
        #expect(session.track(at: 700)?.index == 2)
        #expect(session.track(at: 1499)?.index == 4)
        #expect(session.audioTracks.first?.ext == "mp3")
    }
}
