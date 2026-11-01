# Flutter → Swift port audit

Source checkout: sibling `../../jee` at `ffea967` (read-only). Flutter source is authoritative. The complete broad search output is appended below so every matched Dart source location remains reviewable.

## Route, request and media parity observed in current Dart

| Dart implementation | Behavior confirmed | Swift implementation | Verification |
|---|---|---|---|
| `lib/video_repository.dart` `ScraperConfig.pageUri/searchUri/categoryUri` | `/video/{page}/`, `/search/{query}/{page}/`, `/categories/{slug}/{page}/`; first-page templates omit the page segment | `CatalogSourceConfiguration.pageURL/searchURL/categoryURL` | Static source comparison; not runtime tested |
| `lib/scraper.dart` `modelPage` and `lib/model_page.dart` | Model videos under `/models/<slug>/videos/`; model album route `/models/<slug>/albums/` | `VideoRepository.modelPage/albums` + `CatalogSourceConfiguration.url(base:path:)` | Static source comparison; path normalization added; no site request run |
| `lib/album_page.dart` album photo loader | `mode=async,function=get_block,block_id=album_view_album_view,load=more,from=<chunk>` | `VideoRepository.albumPhotos` | Existing implementation; static audit only |
| `lib/media_headers.dart` `pageHeaders/streamHeaders/imageHeaders/reelHeaders` | Page and media request headers are distinct; stream and image requests carry provider context | `pageHeaders`, `streamHeaders`, `imageHeaders(for:)`, `makeStreamAsset` | Static audit; no device network trace |
| `lib/playback_source.dart` `resolvePlaybackSource` and `lib/stream_resolver.dart` | Resolve final direct stream while preserving cookies and request headers | `NativeStreamResolver.resolveSource` and `makeStreamAsset` | Static audit; no live playback test |
| `lib/scraper.dart` `videoFromCard`, `videoDetails`, stream extraction helpers | CSS selector order, regex fallbacks, URL unescaping and quality ordering | `parseVideoPayload`, `parseDetail`, `parseStreamCandidates` in `CatalogRepository.swift` | Partial source mapping; exhaustive parity is not proven |
| `lib/widgets/search_overlay.dart` `SearchSort` | `relevant(null, 'Relevant')`, `longest('duration', 'Longest')` | Search chips send nil or `by=duration` | Static source comparison |
| `lib/app_theme.dart` | Light/dark palette, accent, gaps, radii, motion | `VXTheme`, `Gaps`, `Radii` in `Models+Services.swift` | Palette values copied; remaining scattered styles still need migration |

## Screen style source map

| Native screen | Flutter source reviewed for style and behavior |
|---|---|
| Home hero and home grid | `lib/home_page.dart`, `lib/widgets/home_hero.dart`, `lib/widgets/video_grid.dart`, `lib/widgets/video_card.dart`, `lib/widgets/video_meta.dart` |
| Floating navigation | `lib/widgets/bottom_bar.dart` |
| Video detail and model chip | `lib/video_details_page.dart`, `lib/model_page.dart` |
| Search | `lib/widgets/search_overlay.dart`, `lib/search_history.dart` |
| Library | `lib/widgets/library_view.dart`, `lib/favorites_store.dart`, `lib/favorite_models_store.dart`, `lib/history_store.dart`, `lib/download_store.dart` |
| Reels | `lib/reels_page.dart` (latest `lib/` implementation), `lib/reel_favorites.dart` |
| Settings and palette | `lib/app_settings.dart`, `lib/app_theme.dart` |

## Regex inventory and capture behavior

`rg` scan found 336 matching source lines across Dart files (operators and selectors included, not 336 unique regexes). The exact raw source locations are in the appendix. Patterns below are the scraper's primary extraction expressions; Dart default flags apply unless shown. Group numbering is 1-based for Dart `group(n)`; group 0 is the full match.

| Dart source / line | Pattern (raw Dart literal) | Flags | Capture used / purpose | Swift destination | Status |
|---|---|---|---|---|---|
| `lib/scraper.dart:854` | `^\s*(\d{1,3})\s*%` | default | group 1 rating prefix | `parseVideoPayload` | Needs fixture parity test |
| `lib/scraper.dart:855` | `(\d{1,3})\s*%` | default | group 1 rating | `parseVideoPayload` | Needs fixture parity test |
| `lib/scraper.dart:856` | `\b(\d{1,2}:\d{2}(?::\d{2})?)\b` | default | group 1 duration | `parseVideoPayload` | Needs fixture parity test |
| `lib/scraper.dart:857` | `(\d[\d,.]*\s*[KkMm]?)\s*views?\b` | default | group 1 view count | `parseVideoPayload` | Needs fixture parity test |
| `lib/scraper.dart:861` | `\b\d+\s+(?:second|minute|hour|day|week|month|year)s?(?:\s+ago)?\b` | default | whole match date | `parseVideoPayload` | Needs fixture parity test |
| `lib/scraper.dart:865` | `\b\d+\s+(?:photos?|pics?|pictures?|images?)\b` | default | whole match album indicator | `parseAlbums` | Needs fixture parity test |
| `lib/scraper.dart:1155` | dynamic `pattern` | case-insensitive, dotAll | group 1 first capture | `firstMatch` / extractor helpers | Needs each call-site mapping |
| `lib/scraper.dart:1165` | `\.(?:mp4|m3u8|webm|mkv|mov|m4v|mpd)(?:$|[/?#&])` | default | whole match playable extension | stream candidate filter | Needs fixture parity test |
| `lib/scraper.dart:1169` | `\.(?:jpe?g|png|gif|webp|svg|ico|css|js|json|vtt|srt|woff2?|ttf|html?)(?:$|[?#])` | default | whole match non-media extension | stream candidate filter | Needs fixture parity test |
| `lib/scraper.dart:1173` | `preview|trailer|teaser|sprite|screenshot|thumb` | case-insensitive | whole match preview marker | preview candidate filter | Needs fixture parity test |
| `lib/scraper.dart:1247` | `(video_(?:alt_)?url\d*)\s*[:=]\s*["']([^"']+)["']` | default | groups 1 and 2: key and URL | `parseStreamCandidates` | Needs fixture parity test |
| `lib/scraper.dart:1253` | `(video_(?:alt_)?url\d*)_text\s*[:=]\s*["']([^"']*)["']` | default | groups 1 and 2: key and quality text | `parseStreamCandidates` | Needs fixture parity test |
| `lib/photo_store.dart:459` | `HTTP (\d{3})` | default | group 1 status code | photo error handling | Not applicable to catalog parser |
| `lib/photo_store.dart:701-724` | filename cleanup / ` (\d+)\.[A-Za-z0-9]+/?$` | default | group 1 photo index | photo storage naming | Not yet mapped to Swift |
| `lib/download_store.dart:71,288,294,910` | safe file ID patterns | default | whole match / replacement | download store | Not yet mapped to Swift |
| `lib/reels_page.dart:103` | `^(\d+(?:\.\d+)?)\s*([kmb])?\s*(?:likes?)?$` | default | groups 1 number, 2 suffix | reel compact count | Not yet mapped to Swift |

## Function-to-function mapping

| Dart function / regex family | Swift function | Test name | Status |
|---|---|---|---|
| `ScraperConfig.pageUri/searchUri/categoryUri` | `pageURL/searchURL/categoryURL` | `CatalogURLTests` | No XCTest target exists; not run |
| `scraper.dart` card and page selectors | `parseVideoPayload`, `parseCard` | `ScraperFixtureTests.testVideoCardParsing` | Fixture absent; not run |
| `scraper.dart` stream regexes / quality ordering | `parseStreamCandidates`, `qualityFromLabel` | `ScraperFixtureTests.testStreamCandidatesAndQuality` | Fixture absent; not run |
| `model_page.dart` model videos/profile parsing | `modelPage`, `parseModelProfile` | `ScraperFixtureTests.testModelVideosAndProfile` | Fixture absent; not run |
| `album_page.dart` album/photo parsing | `albums`, `albumPhotos` | `ScraperFixtureTests.testAlbumPhotos` | Fixture absent; not run |
| `reels_page.dart` feed parsing | `reels`, `parseReel` | `ScraperFixtureTests.testReelsFeed` | Fixture absent; not run |
| `media_headers.dart` request builders | `pageHeaders`, `streamHeaders`, `imageHeaders` | `MediaHeaderTests` | No XCTest target; not run |

### Known gaps (not silently treated as parity)

- Flutter test fixtures did exist inline in `jee/test/scraper_test.dart` and `jee/test/models_test.dart`; representative fixtures have now been saved under `Tests/Fixtures/`. There is still no XCTest target in the one-target Xcode project, so those fixtures are not yet executed by XCTest.
- The scan appendix is a complete broad textual match list; selectors, JSON paths, request calls and each distinct regex call site still require a verified function-level mapping. This port audit is **incomplete** and must not be described as 1:1 complete.
- Swift uses `NSRegularExpression` and SwiftSoup helpers in `CatalogRepository.swift`, but the exhaustive one-function-per-Dart-function extraction layer and test target have not been added.

## Raw source search appendix

The following is the complete broad `rg` output over all Dart source files for the requested search family; it is preserved verbatim from `work/jee-full-inventory.txt`.

```text
.\model_avatar.dart:6:import '../media_headers.dart';
.\model_avatar.dart:56:  Map<String, String>? get _headers {
.\model_avatar.dart:101:                headers: _headers,
.\lib\offline_listing_cache.dart:30:    if (raw == null || raw.isEmpty || utf8.encode(raw).length > _maxStoredBytes) {
.\lib\offline_listing_cache.dart:35:      final decoded = jsonDecode(raw);
.\lib\offline_listing_cache.dart:133:            while (utf8.encode(snapshot).length > _maxStoredBytes &&
.\lib\offline_listing_cache.dart:138:            if (utf8.encode(snapshot).length > _maxStoredBytes &&
.\lib\offline_listing_cache.dart:148:            if (utf8.encode(snapshot).length <= _maxStoredBytes) {
.\lib\offline_album_cache.dart:30:        utf8.encode(raw).length > _maxStoredBytes) {
.\lib\offline_album_cache.dart:35:      final decoded = jsonDecode(raw);
.\lib\offline_album_cache.dart:193:            while (utf8.encode(snapshot).length > _maxStoredBytes &&
.\lib\offline_album_cache.dart:198:            if (utf8.encode(snapshot).length <= _maxStoredBytes) {
.\lib\widget_sync.dart:150:        ..headers['User-Agent'] =
.\lib\native_bridge.dart:74:    required Map<String, String> headers,
.\lib\native_bridge.dart:85:            'headers': headers,
.\lib\native_bridge.dart:94:          isFile ? null : PlaybackSource(url, headers),
.\lib\model_avatar.dart:6:import '../media_headers.dart';
.\lib\model_avatar.dart:56:  Map<String, String>? get _headers {
.\lib\model_avatar.dart:101:                headers: _headers,
.\lib\mini_player.dart:14:    required this.headers,
.\lib\mini_player.dart:23:  final Map<String, String>? headers;
.\lib\history_store.dart:36:        final decoded = jsonDecode(raw);
.\lib\favorite_models_store.dart:25:        final decoded = jsonDecode(raw);
.\lib\stream_resolver.dart:25:String _contextKey(Uri uri, Map<String, String> headers) {
.\lib\stream_resolver.dart:26:  final names = headers.keys.toList()..sort();
.\lib\stream_resolver.dart:33:      ..write(headers[name]);
.\lib\stream_resolver.dart:40:  Map<String, String> headers, {
.\lib\stream_resolver.dart:45:  final key = _contextKey(uri, headers);
.\lib\stream_resolver.dart:56:  final probe = _probe(uri, headers, maxHops, timeout).then((result) {
.\lib\stream_resolver.dart:77:  Map<String, String> headers,
.\lib\stream_resolver.dart:83:  final requestHeaders = <String, String>{...headers};
.\lib\stream_resolver.dart:88:        ..headers.addAll(<String, String>{
.\lib\stream_resolver.dart:93:      final location = response.headers['location'];
.\lib\favorites_store.dart:33:        final decoded = jsonDecode(raw);
.\lib\search_history.dart:19:      raw.trim().replaceAll(RegExp(r'\s+'), ' ');
.\lib\download_store.dart:16:import 'media_headers.dart';
.\lib\download_store.dart:71:  static final RegExp _safeFilePattern = RegExp(
.\lib\download_store.dart:131:        final decoded = jsonDecode(raw);
.\lib\download_store.dart:288:    final safe = entry.video.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
.\lib\download_store.dart:294:    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
.\lib\download_store.dart:313:      _safeFilePattern.hasMatch(value);
.\lib\download_store.dart:792:      final headers = <String, String>{...streamHeaders(uri, pageUrl)};
.\lib\download_store.dart:798:          userAgent: headers['User-Agent'] ?? '',
.\lib\download_store.dart:800:        if (cookie.isNotEmpty) headers['Cookie'] = cookie;
.\lib\download_store.dart:812:        finalUri = await resolveFinalStreamUri(uri, headers);
.\lib\download_store.dart:815:        headers.removeWhere(
.\lib\download_store.dart:843:        headers: headers,
.\lib\download_store.dart:910:    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
.\lib\download_store.dart:934:        ..headers.addAll(<String, String>{
.\lib\scraper.dart:80:  Uri get baseUri => Uri.parse(baseUrl);
.\lib\scraper.dart:87:      pagePathTemplate.replaceAll('{page}', safePage.toString()),
.\lib\scraper.dart:99:          .replaceAll('{query}', Uri.encodeComponent(query.trim()))
.\lib\scraper.dart:100:          .replaceAll('{page}', safePage.toString()),
.\lib\scraper.dart:112:          .replaceAll('{slug}', Uri.encodeComponent(_slugify(slug)))
.\lib\scraper.dart:113:          .replaceAll('{page}', safePage.toString()),
.\lib\scraper.dart:120:      .replaceAll(RegExp(r'\s+'), '-')
.\lib\scraper.dart:121:      .replaceAll(RegExp(r'[^a-z0-9_-]'), '');
.\lib\scraper.dart:148:  Map<String, String> get _headers => {
.\lib\scraper.dart:207:            return HttpDate.parse(value.trim());
.\lib\scraper.dart:229:        host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
.\lib\scraper.dart:239:      final requestHeaders = <String, String>{..._headers, ...?extraHeaders};
.\lib\scraper.dart:247:          ..headers.addAll(requestHeaders);
.\lib\scraper.dart:250:        final location = response.headers['location'];
.\lib\scraper.dart:286:            retryAfter: _retryAfter(response.headers['retry-after']),
.\lib\scraper.dart:309:            response.headers['content-type']?.toLowerCase() ?? '';
.\lib\scraper.dart:314:            : utf8.decode(bodyBytes, allowMalformed: true);
.\lib\scraper.dart:375:    final cards = document.querySelectorAll(selector);
.\lib\scraper.dart:416:    final document = html.parse(await _getDetailPage(uri, fresh: fresh));
.\lib\scraper.dart:418:    var anchors = document.querySelectorAll('.media-models a[href]');
.\lib\scraper.dart:420:      anchors = document.querySelectorAll('.media-info a[href*="/models/"]');
.\lib\scraper.dart:426:      final target = _resolveHttp(anchor.attributes['href'], uri);
.\lib\scraper.dart:431:      if (name.isEmpty) name = _collapse(anchor.attributes['title'] ?? '');
.\lib\scraper.dart:433:        name = base.pathSegments[1].replaceAll(RegExp(r'[-_]+'), ' ').trim();
.\lib\scraper.dart:442:    final base = _modelBase(Uri.parse(model.url)) ?? Uri.parse(model.url);
.\lib\scraper.dart:457:    final document = html.parse(body);
.\lib\scraper.dart:468:      final value = image.attributes[name]?.trim();
.\lib\scraper.dart:477:    final base = _modelBase(Uri.parse(model.url)) ?? Uri.parse(model.url);
.\lib\scraper.dart:489:    final albums = _albumsFrom(html.parse(body), uri, modelName: model.name);
.\lib\scraper.dart:504:    return _albumsFrom(html.parse(body), uri);
.\lib\scraper.dart:512:    var cards = document.querySelectorAll('.thumb--albums');
.\lib\scraper.dart:515:          .querySelectorAll(config.cardSelector)
.\lib\scraper.dart:516:          .where((c) => c.querySelector('a[href*="/albums/"]') != null)
.\lib\scraper.dart:525:          : card.querySelector('a[href]');
.\lib\scraper.dart:526:      final target = _resolveHttp(anchor?.attributes['href'], uri);
.\lib\scraper.dart:535:      final image = card.querySelector('img');
.\lib\scraper.dart:536:      var title = _collapse(anchor.attributes['title'] ?? '');
.\lib\scraper.dart:539:          card.querySelector('.thumb__title, .title')?.text ?? '',
.\lib\scraper.dart:542:      if (title.isEmpty) title = _collapse(image?.attributes['alt'] ?? '');
.\lib\scraper.dart:544:        title = segments.last.replaceAll(RegExp(r'[-_]+'), ' ').trim();
.\lib\scraper.dart:560:    final base = Uri.parse(album.url);
.\lib\scraper.dart:593:    final document = html.parse(body);
.\lib\scraper.dart:595:    var anchors = document.querySelectorAll('a.grid-item[href]');
.\lib\scraper.dart:597:      anchors = document.querySelectorAll(
.\lib\scraper.dart:605:      final image = anchor.querySelector('img');
.\lib\scraper.dart:607:      final full = _absoluteUrl(anchor.attributes['href'], uri);
.\lib\scraper.dart:619:    final match = RegExp(r'/sources/(.+?)/?$').firstMatch(path);
.\lib\scraper.dart:659:    final blocks = document.querySelectorAll(
.\lib\scraper.dart:664:        walk(jsonDecode(script.text));
.\lib\scraper.dart:674:        final element = document.querySelector(selector);
.\lib\scraper.dart:676:            element?.attributes['content'] ?? element?.attributes['href'];
.\lib\scraper.dart:679:            !RegExp(r'logo|/static/', caseSensitive: false).hasMatch(url)) {
.\lib\scraper.dart:687:        final match = RegExp(r'"image"\s*:\s*"([^"]+)"')
.\lib\scraper.dart:688:            .firstMatch(script.text);
.\lib\scraper.dart:690:          match?.group(1)?.replaceAll(r'\/', '/'),
.\lib\scraper.dart:700:      final raw = RegExp(r'"name"\s*:\s*"([^"]+)"');
.\lib\scraper.dart:702:        final match = raw.firstMatch(script.text);
.\lib\scraper.dart:725:      q.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ''),
.\lib\scraper.dart:740:            final base = _modelBase(Uri.parse(ref.url)) ?? Uri.parse(ref.url);
.\lib\scraper.dart:757:      final document = html.parse(await _get(uri));
.\lib\scraper.dart:759:      for (final anchor in document.querySelectorAll('a[href*="/models/"]')) {
.\lib\scraper.dart:760:        final target = _resolveHttp(anchor.attributes['href'], uri);
.\lib\scraper.dart:764:        if (name.isEmpty) name = _collapse(anchor.attributes['title'] ?? '');
.\lib\scraper.dart:767:            anchor.querySelector('img')?.attributes['alt'] ?? '',
.\lib\scraper.dart:771:          name = base.pathSegments[1].replaceAll(RegExp(r'[-_]+'), ' ');
.\lib\scraper.dart:777:            _imageSource(anchor.querySelector('img')),
.\lib\scraper.dart:842:  late final RegExp? _videoPathRe = _safeRegExp(config.videoPathPattern);
.\lib\scraper.dart:843:  late final RegExp? _excludePathRe = _safeRegExp(config.excludePathPattern);
.\lib\scraper.dart:845:  static RegExp? _safeRegExp(String pattern) {
.\lib\scraper.dart:848:      return RegExp(pattern, caseSensitive: false);
.\lib\scraper.dart:854:  static final RegExp _leadingLikeRe = RegExp(r'^\s*(\d{1,3})\s*%');
.\lib\scraper.dart:855:  static final RegExp _percentRe = RegExp(r'(\d{1,3})\s*%');
.\lib\scraper.dart:856:  static final RegExp _durationRe = RegExp(r'\b(\d{1,2}:\d{2}(?::\d{2})?)\b');
.\lib\scraper.dart:857:  static final RegExp _viewsRe = RegExp(
.\lib\scraper.dart:861:  static final RegExp _ageRe = RegExp(
.\lib\scraper.dart:865:  static final RegExp _photosRe = RegExp(
.\lib\scraper.dart:871:      value.replaceAll(RegExp(r'\s+'), ' ').trim();
.\lib\scraper.dart:891:    if (video != null && !video.hasMatch(path)) return false;
.\lib\scraper.dart:893:    if (excluded != null && excluded.hasMatch(path)) return false;
.\lib\scraper.dart:898:      _leadingLikeRe.hasMatch(text) || _viewsRe.hasMatch(text);
.\lib\scraper.dart:901:    var title = text.replaceFirst(RegExp(r'^\s*\d{1,3}\s*%\s*'), '');
.\lib\scraper.dart:902:    final duration = _durationRe.firstMatch(title)?.group(0);
.\lib\scraper.dart:904:    title = title.replaceAll(_viewsRe, '').replaceAll(_ageRe, '');
.\lib\scraper.dart:910:    final icon = element.querySelector(selector);
.\lib\scraper.dart:919:      : v.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '');
.\lib\scraper.dart:923:      raw.replaceAll(RegExp(r'views?', caseSensitive: false), ''),
.\lib\scraper.dart:927:    final match = RegExp(r'^(\d[\d.,\s\u00a0]*?)\s*([KkMmBb])?$')
.\lib\scraper.dart:928:        .firstMatch(text);
.\lib\scraper.dart:931:    final number = match.group(1)!.replaceAll(RegExp(r'[\s\u00a0]'), '');
.\lib\scraper.dart:935:      final value = double.tryParse(number.replaceAll(',', '.'));
.\lib\scraper.dart:939:    final count = int.tryParse(number.replaceAll(RegExp(r'[^\d]'), ''));
.\lib\scraper.dart:950:      ...element.querySelectorAll(config.anchorSelector),
.\lib\scraper.dart:955:      final uri = _resolveHttp(candidate.attributes['href'], pageUri);
.\lib\scraper.dart:964:        element.attributes['data-href'] ?? element.attributes['data-url'],
.\lib\scraper.dart:980:      final match = _leadingLikeRe.firstMatch(text);
.\lib\scraper.dart:989:          element.attributes['data-rating'] ??
.\lib\scraper.dart:990:          element.attributes['data-likes'];
.\lib\scraper.dart:991:      final match = raw == null ? null : _percentRe.firstMatch(raw);
.\lib\scraper.dart:997:            .firstMatch(_iconText(element, config.durationIconSelector) ?? '')
.\lib\scraper.dart:1003:              .firstMatch(_text(element, config.durationSelector) ?? '')
.\lib\scraper.dart:1008:      for (final node in element.querySelectorAll(
.\lib\scraper.dart:1012:        final match = _durationRe.firstMatch(value);
.\lib\scraper.dart:1021:        final match = _durationRe.firstMatch(text);
.\lib\scraper.dart:1031:      final markupDuration = RegExp(r'\d{1,2}:\d{2}(?::\d{2})?')
.\lib\scraper.dart:1032:          .firstMatch(element.innerHtml);
.\lib\scraper.dart:1035:    if (duration.isEmpty) duration = element.attributes['data-duration'] ?? '';
.\lib\scraper.dart:1037:    if (duration.isEmpty && _photosRe.hasMatch(cardText)) return null;
.\lib\scraper.dart:1044:        final match = _viewsRe.firstMatch(text);
.\lib\scraper.dart:1054:            element.attributes['data-views'] ??
.\lib\scraper.dart:1061:    final image = element.querySelector(config.imageSelector);
.\lib\scraper.dart:1063:        image?.attributes['data-src'] ??
.\lib\scraper.dart:1064:        image?.attributes['data-original'] ??
.\lib\scraper.dart:1065:        image?.attributes['data-lazy-src'] ??
.\lib\scraper.dart:1066:        image?.attributes['src'] ??
.\lib\scraper.dart:1067:        element.querySelector('video[poster]')?.attributes['poster'];
.\lib\scraper.dart:1071:        (anchor?.attributes['title'] ??
.\lib\scraper.dart:1072:                element.attributes['data-title'] ??
.\lib\scraper.dart:1073:                element.querySelector(config.titleSelector)?.text ??
.\lib\scraper.dart:1074:                image?.attributes['alt'] ??
.\lib\scraper.dart:1083:        element.attributes['data-id'] ?? '${videoPage.host}${videoPage.path}';
.\lib\scraper.dart:1088:          image?.attributes['data-preview'] ??
.\lib\scraper.dart:1090:                  .querySelector('[data-preview]')
.\lib\scraper.dart:1091:                  ?.attributes['data-preview'],
.\lib\scraper.dart:1107:      category: _collapse(element.attributes['data-category'] ?? 'Video')
.\lib\scraper.dart:1110:            _collapse(element.attributes['data-category'] ?? 'Video').length
.\lib\scraper.dart:1119:    return element.querySelector(selector)?.text.trim();
.\lib\scraper.dart:1124:        element.attributes['data-video-url'] ??
.\lib\scraper.dart:1125:        element.attributes['data-stream'] ??
.\lib\scraper.dart:1126:        element.querySelector('video source[src]')?.attributes['src'] ??
.\lib\scraper.dart:1127:        element.querySelector('video[src]')?.attributes['src'];
.\lib\scraper.dart:1155:      return RegExp(
.\lib\scraper.dart:1159:      ).firstMatch(text)?.group(1);
.\lib\scraper.dart:1165:  static final RegExp _mediaExtRe = RegExp(
.\lib\scraper.dart:1169:  static final RegExp _notMediaExtRe = RegExp(
.\lib\scraper.dart:1173:  static final RegExp _previewRe = RegExp(
.\lib\scraper.dart:1178:  static String _unescape(String value) => value
.\lib\scraper.dart:1180:      .replaceAll(r'\/', '/')
.\lib\scraper.dart:1181:      .replaceAll(r'\u0026', '&')
.\lib\scraper.dart:1182:      .replaceAll(r'\u003d', '=')
.\lib\scraper.dart:1183:      .replaceAll('&amp;', '&');
.\lib\scraper.dart:1189:    if (_notMediaExtRe.hasMatch(path)) return false;
.\lib\scraper.dart:1191:    return _mediaExtRe.hasMatch(withQuery) || path.contains('/get_file/');
.\lib\scraper.dart:1196:    final p = RegExp(r'(\d{3,4})\s*p').firstMatch(lower);
.\lib\scraper.dart:1197:    if (p != null) return int.parse(p.group(1)!);
.\lib\scraper.dart:1207:      return RegExp(pattern, caseSensitive: false, dotAll: true)
.\lib\scraper.dart:1208:          .allMatches(text)
.\lib\scraper.dart:1225:      final value = _unescape(raw);
.\lib\scraper.dart:1240:          preview: _previewRe.hasMatch(path),
.\lib\scraper.dart:1247:    for (final m in RegExp(
.\lib\scraper.dart:1250:    ).allMatches(body)) {
.\lib\scraper.dart:1253:    for (final m in RegExp(
.\lib\scraper.dart:1256:    ).allMatches(body)) {
.\lib\scraper.dart:1261:    for (final node in document.querySelectorAll(
.\lib\scraper.dart:1265:          node.attributes['label'] ??
.\lib\scraper.dart:1266:          node.attributes['title'] ??
.\lib\scraper.dart:1267:          node.attributes['res'] ??
.\lib\scraper.dart:1268:          node.attributes['size'] ??
.\lib\scraper.dart:1269:          node.attributes['data-res'] ??
.\lib\scraper.dart:1271:      add(node.attributes['src'], 1, label: label);
.\lib\scraper.dart:1280:      add(document.querySelector(selector)?.attributes['content'], 2);
.\lib\scraper.dart:1291:    final plain = body.replaceAll(r'\/', '/');
.\lib\scraper.dart:1338:    final document = html.parse(body);
.\lib\scraper.dart:1352:        document.querySelector('h1')?.text.trim() ??
.\lib\scraper.dart:1354:            .querySelector('meta[property="og:title"]')
.\lib\scraper.dart:1355:            ?.attributes['content']
.\lib\scraper.dart:1359:    final descriptionNode = document.querySelector(config.descriptionSelector);
.\lib\scraper.dart:1361:        descriptionNode?.attributes['content']?.trim().isNotEmpty == true
.\lib\scraper.dart:1362:        ? descriptionNode!.attributes['content']!.trim()
.\lib\scraper.dart:1368:              document.querySelector('video[poster]')?.attributes['poster'],
.\lib\scraper.dart:1431:    return scraper._videosFrom(html.parse(job.body), job.uri, job.selector);
.\lib\album_page.dart:8:import 'media_headers.dart';
.\lib\album_page.dart:198:    headers: null,
.\lib\album_page.dart:685:                      headers: loader.imageHeaders,
.\lib\album_page.dart:746:    final headers = loader.imageHeaders;
.\lib\album_page.dart:755:              thumb: NetworkImage(p.thumbUrl, headers: headers),
.\lib\album_page.dart:756:              full: NetworkImage(p.fullUrl, headers: headers),
.\lib\album_page.dart:817:                        headers: imageHeadersFor(album.url),
.\lib\widgets\video_artwork.dart:34:  static Map<String, String>? _headersFor(Video video) {
.\lib\widgets\video_artwork.dart:111:              headers: _headersFor(video),
.\lib\playback_source.dart:3:import 'media_headers.dart';
.\lib\playback_source.dart:8:  const PlaybackSource(this.url, this.headers);
.\lib\playback_source.dart:11:  final Map<String, String> headers;
.\lib\playback_source.dart:21:  var headers = streamHeaders(streamUri, pageUrl);
.\lib\playback_source.dart:31:      userAgent: headers['User-Agent'] ?? '',
.\lib\playback_source.dart:35:      headers = <String, String>{...headers, 'Cookie': cookie};
.\lib\playback_source.dart:45:      : await resolveFinalStreamUri(streamUri, headers, refresh: refresh);
.\lib\playback_source.dart:47:    headers = <String, String>{...headers}
.\lib\playback_source.dart:57:  return PlaybackSource(finalUri.toString(), headers);
.\lib\reel_favorites.dart:149:        final decoded = jsonDecode(raw);
.\test\scraper_test.dart:40:    expect(requestedUris[0], Uri.parse('https://videos.example.test/'));
.\test\scraper_test.dart:41:    expect(requestedUris[1], Uri.parse('https://videos.example.test/video/1/'));
.\test\scraper_test.dart:113:        headers: <String, String>{
.\test\scraper_test.dart:135:          return http.Response('', 503, headers: {'retry-after': '0'});
.\test\scraper_test.dart:159:              request.headers['Referer'],
.\test\scraper_test.dart:165:              headers: <String, String>{
.\test\scraper_test.dart:171:          expect(request.headers.containsKey('Referer'), isFalse);
.\test\scraper_test.dart:198:          headers: <String, String>{
.\lib\reels_page.dart:101:  final text = value.trim().toLowerCase().replaceAll(',', '');
.\lib\reels_page.dart:103:  final match = RegExp(
.\lib\reels_page.dart:105:  ).firstMatch(text);
.\lib\reels_page.dart:222:  static final Uri _api = Uri.parse(_kApiUrl);
.\lib\reels_page.dart:223:  static const Map<String, String> _headers = {
.\lib\reels_page.dart:231:      ..headers.addAll(_headers)
.\lib\reels_page.dart:232:      ..bodyBytes = utf8.encode(
.\lib\reels_page.dart:247:      ..headers.addAll(const {
.\lib\reels_page.dart:282:      headers: response.headers,
.\lib\reels_page.dart:298:        date = HttpDate.parse(value.trim());
.\lib\reels_page.dart:316:        retryAfter: _retryAfter(res.headers['retry-after']),
.\lib\reels_page.dart:319:    final json = jsonDecode(utf8.decode(res.bodyBytes));
.\lib\reels_page.dart:593:      Uri.parse(url),
.\lib\reels_page.dart:906:      final req = http.Request('GET', uri)..headers.addAll(_kMediaHeaders);
.\lib\reels_page.dart:1796:                            headers: _kMediaHeaders,
.\lib\widgets\model_avatar.dart:6:import '../media_headers.dart';
.\lib\widgets\model_avatar.dart:56:  Map<String, String>? get _headers {
.\lib\widgets\model_avatar.dart:95:            headers: _headers,
.\lib\playback_progress.dart:69:        final decoded = jsonDecode(raw);
.\test\photo_store_test.dart:47:    expect(request.headers['Referer'], 'https://x.example.test/');
.\test\photo_store_test.dart:213:            expect(request.headers['Cookie'], 'session=secret');
.\test\photo_store_test.dart:214:            expect(request.headers['Authorization'], 'Bearer secret');
.\test\photo_store_test.dart:215:            expect(request.headers['Referer'], 'https://x.example.test/');
.\test\photo_store_test.dart:219:              headers: <String, String>{
.\test\photo_store_test.dart:225:          expect(request.headers.containsKey('Cookie'), isFalse);
.\test\photo_store_test.dart:226:          expect(request.headers.containsKey('Authorization'), isFalse);
.\test\photo_store_test.dart:227:          expect(request.headers.containsKey('Referer'), isFalse);
.\test\photo_store_test.dart:234:        headers: <String, String>{
.\test\models_test.dart:17:    '<html><body>${ids.map((id) => _card.replaceAll('%ID%', id)).join()}</body></html>';
.\test\models_test.dart:123:            .replaceAll('%CARDS%', _card.replaceAll('%ID%', 'a')),
.\test\models_test.dart:151:          http.Response(_person().replaceAll('%CARDS%', ''), 200),
.\test\models_test.dart:207:                <img class="lazyload" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
.\test\models_test.dart:306:              <img src="data:image/gif;base64,AAAA" data-webp="https://storage4.example.test/contents/albums/main/200x150/0/37/29945.jpg"></a></div>
.\test\models_test.dart:309:      asyncHeaders.add(request.headers);
.\test\models_test.dart:430:                .replaceAll('%CARDS%', ''),
.\lib\photo_store.dart:11:import 'media_headers.dart';
.\lib\photo_store.dart:22:    RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,159}$').hasMatch(value);
.\lib\photo_store.dart:197:        final decoded = jsonDecode(raw);
.\lib\photo_store.dart:270:    Map<String, String>? headers,
.\lib\photo_store.dart:341:    final requestHeaders = headers ?? _defaultHeaders(album.url);
.\lib\photo_store.dart:441:    Map<String, String> headers, {
.\lib\photo_store.dart:450:          headers,
.\lib\photo_store.dart:459:        final match = RegExp(r'HTTP (\d{3})').firstMatch(error.message);
.\lib\photo_store.dart:484:    Map<String, String> headers,
.\lib\photo_store.dart:487:    var requestHeaders = <String, String>{...headers};
.\lib\photo_store.dart:493:        ..headers.addAll(requestHeaders);
.\lib\photo_store.dart:497:      final location = response.headers['location'];
.\lib\photo_store.dart:538:    Map<String, String> headers, {
.\lib\photo_store.dart:551:    final response = await _sendImageRequest(uri, headers);
.\lib\photo_store.dart:701:    var name = value.replaceAll(RegExp(r'\.[A-Za-z0-9]{2,5}/?$'), '');
.\lib\photo_store.dart:702:    name = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
.\lib\photo_store.dart:703:    name = name.replaceAll(RegExp(r'^_+|_+$'), '');
.\lib\photo_store.dart:724:    final match = RegExp(r'(\d+)\.[A-Za-z0-9]+/?$').firstMatch(id);
.\lib\preview_manager.dart:8:import 'media_headers.dart';
.\lib\preview_manager.dart:163:    var headers = streamHeaders(uri, pageUrl ?? video.pageUrl);
.\lib\preview_manager.dart:172:      headers = source.headers;
.\lib\preview_manager.dart:173:      playUri = Uri.parse(source.url);
.\lib\preview_manager.dart:180:        httpHeaders: headers,
.\lib\recent_videos_store.dart:30:        final decoded = jsonDecode(raw);
.\lib\player_page.dart:183:      _activeHeaders = adopted.headers;
.\lib\player_page.dart:335:      _activeHeaders = known.headers;
.\lib\player_page.dart:337:        Uri.parse(known.url),
.\lib\player_page.dart:338:        httpHeaders: known.headers,
.\lib\player_page.dart:364:    final finalUri = Uri.parse(source.url);
.\lib\player_page.dart:367:    _activeHeaders = source.headers;
.\lib\player_page.dart:370:      httpHeaders: source.headers,
.\lib\player_page.dart:491:        headers: _activeHeaders ?? const <String, String>{},
.\lib\player_page.dart:547:        headers: _activeHeaders,
.\reels_page.dart:101:  final text = value.trim().toLowerCase().replaceAll(',', '');
.\reels_page.dart:103:  final match = RegExp(
.\reels_page.dart:105:  ).firstMatch(text);
.\reels_page.dart:222:  static final Uri _api = Uri.parse(_kApiUrl);
.\reels_page.dart:223:  static const Map<String, String> _headers = {
.\reels_page.dart:231:      ..headers.addAll(_headers)
.\reels_page.dart:232:      ..bodyBytes = utf8.encode(
.\reels_page.dart:247:      ..headers.addAll(const {
.\reels_page.dart:282:      headers: response.headers,
.\reels_page.dart:298:        date = HttpDate.parse(value.trim());
.\reels_page.dart:316:        retryAfter: _retryAfter(res.headers['retry-after']),
.\reels_page.dart:319:    final json = jsonDecode(utf8.decode(res.bodyBytes));
.\reels_page.dart:593:      Uri.parse(url),
.\reels_page.dart:906:      final req = http.Request('GET', uri)..headers.addAll(_kMediaHeaders);
.\reels_page.dart:1796:                            headers: _kMediaHeaders,
.\lib\video_repository.dart:329:    final configuredUri = Uri.parse(scraper.config.baseUrl.trim());
.\lib\video_repository.dart:385:        request.headers.set(HttpHeaders.userAgentHeader, userAgent);
.\lib\video_repository.dart:386:        request.headers.set(HttpHeaders.acceptHeader, '*/*');
.\lib\video_repository.dart:390:          request.headers.set(HttpHeaders.cookieHeader, existingCookies);
.\lib\video_repository.dart:401:        final location = response.headers.value(HttpHeaders.locationHeader);
.\lib\video_repository.dart:439:        : rawDomain.replaceFirst(RegExp(r'^\.'), '');
.\lib\video_repository.dart:515:        value.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
```

## Follow-up parity fixes (2026-11-01)

| Flutter behavior | Swift change | Fixture | Status |
|---|---|---|---|
| `Scraper.searchPeople`: probe normalized and compact slugs before search-page discovery; fetch albums for exact slug matches | `searchPeople` now tries both profile routes first, treats search-page failure as non-fatal, and loads albums for up to two exact matches | `model-profile.html`, `model-albums.html` | Ported; XCTest not run (project has no test target) |
| `Scraper.videoModels`: `.media-models a[href]`, then `.media-info a[href*="/models/"]` only if empty | Selector order and fallback now match | Flutter inline model fixture | Ported |
| `Scraper._albumsFrom`: `.thumb--albums`, otherwise configured cards containing album links | Swift follows the same selector fallback and title/image-source priority | `model-albums.html` | Ported |
| `Scraper.albumPhotos`: `a.grid-item[href]`, then legacy gallery selectors only if empty | Swift follows fallback order | `album-photos.html` | Ported |
| `Scraper._parseCard`: duration probes icon, configured selector, `li`/duration nodes, card text, markup, `data-duration`; album cards without duration are omitted | Added these duration probes and album guard; video IDs omit query strings as Flutter does | `homepage-card.html` | Ported; not runtime-tested |
| `Scraper._extractStreams`: plain URL scan permits mp4/m3u8/webm, max 30; playable filters also allow mkv/mov/m4v/mpd | Aligned stream scan extensions/limit and playable extension filter | `video-detail.html` | Ported; no end-to-end player run |

The workflow now also runs on `codex/**` pushes so this PR branch produces a build artifact. The full broad Dart search appendix above is retained; it includes many unrelated stores and widgets. This remains a static inventory, not an exhaustive one-to-one executable mapping for every one of the 336 hits. The iOS project still has a single app target and no XCTest target; adding/running XCTest would require changing that project structure. Do not interpret fixtures alone as proof of parser parity.