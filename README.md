# VXTube — Native SwiftUI iOS app

This repository is the native SwiftUI migration of the supplied Flutter `watch_tube` project. It includes an Xcode project, the app icon, the SwiftSoup package dependency, and a GitHub Actions workflow that builds the iOS app on every push and pull request to `main` or `master`.

## Open locally

1. Install Xcode 16.4 or a newer Xcode version with the iOS 18 SDK.
2. Open `VXTube.xcodeproj`.
3. Let Xcode resolve the Swift Package Manager dependency **SwiftSoup**.
4. Select the `VXTube` scheme and an iPhone simulator or device.
5. For a physical device, choose your Apple Development Team under **Signing & Capabilities**. The bundle identifier is `com.vxtube.app`; change it if you use your own identifier.

The app's minimum deployment target is iOS 18.0 because the interface uses native iOS 18 scroll APIs.

## GitHub Actions build

The workflow is at `.github/workflows/ios-build.yml`. Push this folder to a GitHub repository, then open **Actions → iOS Build**. It resolves SwiftSoup and compiles a Release build for generic iOS devices without signing. The workflow uploads:

- `VXTube-unsigned-app.zip` — the compiled `.app` bundle.
- `xcodebuild.log` — the build log.

The artifact is intentionally unsigned; it is not directly installable on an iPhone. To install it or distribute through TestFlight/App Store, configure Apple signing in Xcode or add a signing/export workflow with your Apple Developer certificate and provisioning profile.

## Source configuration

The default source URL and scraper selectors are copied from the supplied Flutter `lib/video_repository.dart` and `lib/scraper.dart` configuration. The default is `https://x-fetish.tube`.

To change the content source, edit `VIDEO_SOURCE_BASE_URL` in the app target's `Info.plist`. The scraper also reads these optional Info.plist string keys:

| Key | Default |
|---|---|
| `VIDEO_HOME_PATH` | `/` |
| `VIDEO_PAGE_PATH_TEMPLATE` | `/video/{page}/` |
| `VIDEO_SEARCH_PATH_TEMPLATE` | `/search/{query}/{page}/` |
| `VIDEO_CATEGORY_PATH_TEMPLATE` | `/categories/{slug}/{page}/` |
| `VIDEO_CARD_SELECTOR` | `.thumbs__list .item.thumb, .thumb-spot, article[data-video], .video-card, .video-item` |
| `VIDEO_ANCHOR_SELECTOR` | `a[href]` |
| `VIDEO_IMAGE_SELECTOR` | `img` |
| `VIDEO_TITLE_SELECTOR` | `[itemprop="name"], .thumb-spot__title, .thumb__title, .video-title, .title, h2, h3` |
| `VIDEO_DURATION_SELECTOR` | `.duration, [data-duration]` |
| `VIDEO_VIEWS_SELECTOR` | `.views, [data-views]` |
| `VIDEO_LIKES_SELECTOR` | `.rating, .likes, .thumb-spot__rating, [data-rating], [data-likes]` |
| `VIDEO_DESCRIPTION_SELECTOR` | `meta[property=og:description], meta[name=description]` |
| `VIDEO_PATH_PATTERN` | `/video/` |
| `VIDEO_EXCLUDE_PATH_PATTERN` | `/albums?/&#124;/galleries/&#124;/gallery/&#124;/photos?/&#124;/pictures?/` |
| `VIDEO_RELATED_CARD_SELECTOR` | `.related .item.thumb, .related-videos .item.thumb, .related .video-card, .related .video-item` |
| `VIDEO_STREAM_URL_PATTERN` | `(?:video_url&#124;file&#124;src)\s*[:=]\s*["']([^"']+)["']` |
| `VIDEO_DETAIL_TITLE_PATTERN` | `(?:video_title&#124;title)\s*[:=]\s*["']([^"']*)["']` |
| `VIDEO_PREVIEW_PATTERN` | `(?:preview_url1?&#124;poster)\s*[:=]\s*["']([^"']+)["']` |
| `VIDEO_CATEGORIES` | empty (source-detected categories are used where available) |

## Migrated feature map

| Flutter source | Native implementation |
|---|---|
| `home_page.dart`, `widgets/home_hero.dart`, `widgets/video_grid.dart`, `widgets/category_bar.dart`, `widgets/continue_row.dart` | `HomeView.swift`, `HomeViewModel.swift`, `HomeComponents.swift` |
| `scraper.dart`, `video_repository.dart`, `models.dart` | `CatalogRepository.swift`, `Models+Services.swift` |
| `widgets/search_overlay.dart`, `search_history.dart` | `AppLibraryScreens.swift` (`SearchScreen`, `SearchHistory`) |
| `reels_page.dart` | `ReelsView.swift`, `ReelsViewModel.swift`, `ReelsData.swift`, `ReelPlayer.swift` |
| `player_page.dart`, `playback_source.dart`, `stream_resolver.dart`, `playback_launcher.dart` | `PlayerScreen.swift`, `PlayerViewModel.swift`, `PlayerEngine.swift`, `PlayerServices.swift`, `CatalogRepository.swift` |
| `video_details_page.dart`, `model_page.dart`, `album_page.dart` | `VideoDetailsView.swift`, `DetailsViewModel.swift`, `AppLibraryScreens.swift` |
| `favorites_store.dart`, `history_store.dart`, `playback_progress.dart`, `download_store.dart` | `Models+Services.swift` |
| `favorite_models_store.dart`, album/photo storage | `AppLibraryScreens.swift`, `PhotoAlbumsStore.swift` |
| `app_settings.dart`, `app_theme.dart`, `mini_player.dart` | `PlayerServices.swift`, `MiniPlayerBar.swift`, `HomeView.swift` |
| `photo_saver.dart`, `save_video_to_photos.dart` | `ReelsData.swift`, `PhotoAlbumsStore.swift` |

## Verification and known gaps

- All Swift files pass the Swift parser in this workspace (`scripts/verify-swift-syntax.sh`).
- This build environment is Linux and does not include Xcode, the iOS SDK, simulator runtimes, or Apple signing tools. An actual iOS compile, simulator launch, and device test could not be performed here; the GitHub Actions macOS runner performs the first real Xcode build.
- The Swift app has native AVPlayer playback, playback quality selection, resume progress, mini-player, and Picture in Picture. The Flutter `widget_sync.dart` / `native_bridge.dart` also call into platform-side WidgetKit and Live Activity methods; the original upload did not include the iOS Runner/Widget Extension native implementation, so those WidgetKit/Live Activity surfaces are not recreated in this target yet.
- The exact source site's HTML, cookies, and video stream responses can change. Validate scraping, playback, and download flows against the selected source on a device before release.
- The iOS app uses SwiftUI and AVKit rather than Flutter widgets or the Flutter media player. Small animation and layout differences from Flutter are expected; the native feature coverage is mapped above.

## Social-style redesign and fixes in this update

The interface now leans into the interaction patterns of current social apps: compact media cards, layered material surfaces, rounded chips, stronger typography, a floating translucent dock, and full-screen Reels controls. It remains an original VXTube design rather than a pixel-for-pixel copy of Instagram, TikTok, or Telegram.

- Home, Library, and Settings remain horizontally swipeable using native paged `TabView` navigation.
- Search and Reels open as full-screen destinations from the bottom dock.
- The dock uses `ultraThinMaterial`, a spring-animated selection capsule, SF Symbols, haptics, and drag-to-select.
- Video cards are now real SwiftUI `Button` targets, with the favorite action layered separately so tapping a related video opens its Details route reliably.
- Model profile Videos/Photos selection uses the same native capsule treatment instead of the legacy segmented control.
- Reels top controls now reserve at least 64 pt above the video for notch / Dynamic Island devices and keep a higher z-order; Back, Sound, and Show/Hide controls remain visible above the video.
- Reels clear-mode preference uses a new key, so an old saved hide-UI choice does not hide the controls on first launch of this update.
- Details, search, cards, settings, metadata rows, category pills and mini-player share one rounded, material-based visual language.

## Playback and metadata fixes

- Match Flutter `launchPlayer`: network playback resolves a fresh direct stream from the video detail page instead of trusting a listing-card preview URL.
- If the first AVPlayer load fails, the player retries once after resolving the detail page again.
- Stream discovery prioritizes explicit `video_url` / `video_alt_url` fields, handles escaped URLs, excludes preview/trailer/thumb resources, and only selects AVPlayer-compatible MP4/HLS/MOV/M4V or `/get_file/` resources.
- Playback source setup primes the site's cookie jar and applies User-Agent, Referer, Origin, Accept, and any available cookies to AVFoundation.
- Duration, view count and rating parsing now follows the Flutter scraper's DOM-parent and card-text fallbacks. Regexes without a capture group also return their full match instead of silently returning no value.
- AVPlayer duration is observed after the item becomes ready, including HLS streams whose duration is initially indefinite.

## Verification

- `bash scripts/verify-swift-syntax.sh` passes for all Swift source files.
- The metadata normalization regex was checked against plain counts, comma-separated counts, K/M suffixes and non-breaking spaces.
- This workspace does not contain Xcode or the iOS SDK, so a real iOS compile, simulator test and live playback test could not be performed here. GitHub Actions performs the first real Xcode build on a macOS runner.
- Source-site HTML, anti-hotlink rules, signed URLs and cookies can change. Confirm playback and metadata on an actual device with a live connection before release.

The project targets iOS 18.0 and uses SwiftUI + AVKit. The GitHub Actions artifact is unsigned; Apple signing is still required for direct device installation or distribution.
