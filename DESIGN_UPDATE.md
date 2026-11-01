# VXTube — iOS 27 Inspired Visual Refresh

## UI / UX
- Updated card and metadata hierarchy toward modern social-video interfaces: cleaner thumbnails, concise metadata, rounded surfaces and a vivid indigo/blue-violet accent.
- Kept the floating native glass dock and drag-to-select behavior. Home, Library and Settings remain horizontally swipeable as in the Flutter information architecture.
- Made video cards proper buttons and moved the favorite action into a separate overlay hit target, improving navigation from related videos and model pages.
- Replaced the remaining model-profile segmented picker with animated material capsules.
- Reels top bar now renders above the video layer with at least 64 pt safe-area padding and z-index for notch / Dynamic Island devices. It contains Back, For You, Sound and Show/Hide controls.
- Reels controls default to visible on this update even if an earlier build had persisted clear mode.

## Playback fixes
- Network playback now resolves the stream from the video detail page before opening AVPlayer, matching Flutter's `launchPlayer` behavior. Listing-card preview URLs are not trusted as final streams.
- AVPlayer gets one automatic detail-page refresh attempt after a failed initial load.
- Stream candidates prioritize `video_url` / `video_alt_url`, then media sources and metadata. Escaped URLs are decoded; preview/trailer/thumb resources are excluded. Unsupported WebM/MKV/MPEG-DASH candidates are not selected for native AVPlayer.
- Playback headers include User-Agent, Referer, Origin, Accept and available HTTP cookies after priming the configured source and detail page.
- Metadata parsing now follows the Flutter scraper's icon-parent and card-text fallbacks for duration/views/likes, and handles regex patterns without capture groups.
- AVPlayer and ReelPlayer observe duration updates so HLS durations can appear after initial readiness.

## Validation limits
- `bash scripts/verify-swift-syntax.sh` passes.
- Regex normalization was smoke-tested locally for K/M suffixes, comma counts and non-breaking spaces.
- Xcode/iOS SDK is unavailable in this workspace. The GitHub Actions job runs the real Xcode build; runtime video playback still needs a real-device test against the live source.


## Liquid Glass visual refresh
- Reduced the featured artwork height so more of the feed is visible without scrolling.
- Added a translucent, high-contrast detail surface over the featured artwork so titles and actions stay readable across bright thumbnails and both system appearances.
- Refined the feature title typography, category selection gradient and continuous card corners to create a consistent iOS 27-inspired visual language while keeping the app's iOS 18 deployment target.
- Kept playback, routing, accessibility actions and the existing theme setting intact.
- The GitHub Actions workflow packages the unsigned Release build as `artifacts/VXTube.ipa`; signing is still needed for direct device installation.


## Playback and navigation hardening
- Direct HTTP(S) stream URLs are preserved by the playback launcher instead of being discarded before detail-page resolution.
- Provider and per-video HTTP headers are merged into `PlaybackSource` and passed through `AVURLAssetHTTPHeaderFieldsKey`; AVPlayer status failures and failed-to-end errors are logged for diagnosis and the existing reconnect flow can retry.
- Model identifiers and model URLs are normalized to the source's model route. Invalid model routes now return a recoverable error rather than silently loading the global album catalog.
- Model, album and photo responses support nested JSON collection wrappers as well as HTML fallbacks; request failures map to user-facing messages with retry controls.
- Search, model and album browsing use native draggable sheets. The oversized selected-tab capsule was replaced by a compact continuous-corner glass bar with small selection dots.
- Model video, album and photo grids show redacted placeholders while loading. New installations default to the OLED-friendly system dark appearance, while the existing theme setting remains available.
