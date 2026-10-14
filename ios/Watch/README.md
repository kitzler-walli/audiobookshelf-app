# Apple Watch app

Standalone watchOS app (target `AudiobookshelfWatch` in `ios/App/App.xcodeproj`), embedded in the iOS app and able to
run without the iPhone nearby. It currently still carries the Phase 0 spike screens.
`AbsWatchCore` (Swift package) holds the code that does not depend on the device: pairing and token handling,
byte range bookkeeping, sparse track files, the offline window planner and the API client.

## Pairing

The watch never sees the phone's tokens. Tapping **Pair with iPhone** on the watch:
1. asks the iPhone app over WatchConnectivity (`WatchPairingService` in the iOS app),
2. which requests a device code from the server (`/auth/device-code/request`, server fork) and authorizes it with
   the phone's own login (`/api/device-code/authorize`),
3. and replies with the server address and device code only; the watch polls `/auth/device-code/poll` and gets a
   server session of its own (access token 1 h, refresh token 30 days, renewed on every refresh).

## Setup

- Target: `ruby ios/Watch/scripts/add-watch-target.rb` recreates it if an upstream merge overwrites `project.pbxproj`.
- Unit tests: `cd ios/Watch/AbsWatchCore && swift test`.
- Install without Xcode: `npm ci && npm run sync`, then `ios/distribution/build-ota.sh` builds a Release Testing
  (Ad Hoc) ipa and the install page into `~/Downloads/audiobookshelf-ota` for upload to `https://cdn.kw.at/audiobookshelf`.

On the watch: **Pair with iPhone → Continue listening → pick a book → Start session**. The **Log** screen shows
everything the tests report. Pair Bluetooth headphones first; long-form audio does not play on the watch speaker.

## Tests

Run them with the phone switched off (or in flight mode) so the watch uses its own LTE.

| # | What | How | Record |
|---|------|-----|--------|
| 1 | Streaming over LTE | *Stream (default buffer)*, then *Stream (10 min buffer)*. Walk around, lower the wrist, turn the screen off. | Time to start, *Buffered* seconds for both buffer settings, whether audio continues with the screen off, stalls in the log |
| 2 | Sparse offline window | Pick *10 min*, *Download (foreground)*, wait for 100 %. Turn on flight mode, *Play local from start*, then *Play local near end*. | Plays from start? What happens at the window end (expected: "Cannot Decode" ~2 s before the edge)? *On disk* vs. *Downloaded* size |
| 3 | Background downloads | Pick *1 h*, *Download (background)*, leave the app and let the screen turn off for a few minutes. Repeat on charger + Wi-Fi. | Progress after returning, "woken for background downloads" in the log, total time on LTE vs. charger |

Already verified on the Mac (AVPlayer with a sparse AAC file): playback inside the window works, it stops with
"Cannot Decode" ~2 s before a hole, seeking into a hole fails immediately, and seeking back into the window recovers
without recreating the player item.

## Findings that changed the plan

- `AVAssetResourceLoader` is unavailable on watchOS, so AVPlayer cannot be fed from a custom byte-range cache.
  Streaming uses the public session track URL directly; offline playback uses sparse local files instead.
- `MPNowPlayingSession` is unavailable on watchOS; Now Playing goes through `MPNowPlayingInfoCenter` only.
- `WKWatchOnly` and `WKRunsIndependentlyOfCompanionApp` must not both be set. The spike is watch-only;
  the real app is embedded in the iOS app and uses `WKRunsIndependentlyOfCompanionApp`.
