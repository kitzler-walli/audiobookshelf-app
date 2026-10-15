# Apple Watch app

Standalone watchOS app (target `AudiobookshelfWatch` in `ios/App/App.xcodeproj`), embedded in the iOS app and able to
run without the iPhone nearby: it streams over the watch's own LTE or plays downloads offline, and reports progress
to the server like the iPhone app.
`AbsWatchCore` (Swift package) holds the code that does not depend on the device: pairing and token handling,
the API client, progress reporting, byte range bookkeeping, sparse track files and download planning.

## Pairing

The watch never sees the phone's tokens. Tapping **Pair with iPhone** on the watch:
1. asks the iPhone app over WatchConnectivity (`WatchPairingService` in the iOS app),
2. which requests a device code from the server (`/auth/device-code/request`, server fork) and authorizes it with
   the phone's own login (`/api/device-code/authorize`),
3. and replies with the server address and device code only; the watch polls `/auth/device-code/poll` and gets a
   server session of its own (access token 1 h, refresh token 30 days, renewed on every refresh).

## Downloads

A book can be downloaded whole, or as **Next hour / Next 2 hours**: a window from the listening position that moves
along while listening (topped up every minute of playback when online). Podcast episodes are downloaded whole
(swipe on an episode).

- Track files are sparse files (`SparseTrackFile`): full size, but only downloaded ranges take space. A JSON manifest
  next to each file records the present ranges. Byte positions of a time window are estimated from the bitrate, with
  margins and the container headers always included (`WindowPlanner`).
- `TrackDownloader` fetches 4 MiB range chunks of `/api/items/:id/file/:ino` with the watch's token. While the app is
  open or playing it uses a default URLSession (fast); otherwise the jobs move to a background session, which
  continues while the app is suspended but is scheduled slowly by watchOS (fastest on the charger).
- A partly downloaded file "ends" where its bytes end; AVPlayer reports a normal end of item there, without an error.
  Local playback therefore pauses at every item end (`actionAtItemEnd = .pause`) and compares the position with the
  track length: at a real end it advances, at a gap it fetches the next 10 min with priority and continues, or stops
  with "End of download" when offline.
- Downloaded items are played as local sessions (`POST /api/session/local`, like the iPhone app's downloads). Every
  change is saved to disk first and uploaded every 15 s when online; sessions that could not be uploaded are sent when
  the app comes back to the front. The server keeps its own progress when it is newer.
- Playback starts at the newer of the watch's and the server's position (the server is asked for 4 s at most).

## Setup

- Target: `ruby ios/Watch/scripts/add-watch-target.rb` recreates it if an upstream merge overwrites `project.pbxproj`.
- Unit tests: `cd ios/Watch/AbsWatchCore && swift test`.
- Install without Xcode: `npm ci && npm run sync`, then `ios/distribution/build-ota.sh` builds a Release Testing
  (Ad Hoc) ipa and the install page into `~/Downloads/audiobookshelf-ota` for upload to `https://cdn.kw.at/audiobookshelf`.

Pair Bluetooth headphones first; long-form audio does not play on the watch speaker. **Settings → Log** shows what
the app did (downloads, sessions, uploads).

## Findings from the Phase 0 spike

- `AVAssetResourceLoader` is unavailable on watchOS, so AVPlayer cannot be fed from a custom byte-range cache.
  Streaming uses the public session track URL directly; offline playback uses sparse local files instead.
- On the watch, AVPlayer plays a sparse file up to the end of its downloaded part and reports a normal end of item.
- Background URLSession downloads work but are slow; foreground downloads are much faster.
- `MPNowPlayingSession` is unavailable on watchOS; Now Playing goes through `MPNowPlayingInfoCenter` only.
- `WKWatchOnly` and `WKRunsIndependentlyOfCompanionApp` must not both be set; the app is embedded in the iOS app
  and uses `WKRunsIndependentlyOfCompanionApp`.
