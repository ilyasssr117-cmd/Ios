import SwiftUI
import Observation
import UIKit

// MARK: - Persistent library collections

@MainActor @Observable
final class ModelFavoritesStore {
    static let shared = ModelFavoritesStore()
    private(set) var items: [ModelRef] = []
    private let key = "favorite_models_v1_swift"
    private init() {
        if let data = UserDefaults.standard.data(forKey: key), let values = try? JSONDecoder().decode([ModelRef].self, from: data) { items = values }
    }
    func isFavorite(_ model: ModelRef) -> Bool { items.contains(model) }
    @discardableResult func toggle(_ model: ModelRef) -> Bool {
        if let index = items.firstIndex(of: model) { items.remove(at: index); persist(); return false }
        items.insert(model, at: 0); items = Array(items.prefix(200)); persist(); return true
    }
    private func persist() { if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) } }
}

@MainActor @Observable
final class SavedAlbumsStore {
    static let shared = SavedAlbumsStore()
    private(set) var items: [AlbumRef] = []
    private let key = "saved_albums_v1_swift"
    private init() {
        if let data = UserDefaults.standard.data(forKey: key), let values = try? JSONDecoder().decode([AlbumRef].self, from: data) { items = values }
    }
    func isSaved(_ album: AlbumRef) -> Bool { items.contains(album) }
    @discardableResult func toggle(_ album: AlbumRef) -> Bool {
        if let index = items.firstIndex(of: album) { items.remove(at: index); persist(); return false }
        items.insert(album, at: 0); items = Array(items.prefix(200)); persist(); return true
    }
    private func persist() { if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) } }
}

// MARK: - Search

enum SearchScope: String, CaseIterable, Identifiable {
    case videos = "Videos", people = "Models", albums = "Albums"
    var id: String { rawValue }
}

@MainActor @Observable
final class SearchHistory {
    static let shared = SearchHistory()
    private let defaults = UserDefaults.standard
    private let key = "search_history_v1_swift"
    private(set) var items: [String]
    private init() { items = defaults.stringArray(forKey: key) ?? [] }
    func add(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        items.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        items.insert(q, at: 0); items = Array(items.prefix(30)); persist()
    }
    func remove(_ query: String) { items.removeAll { $0 == query }; persist() }
    func clear() { items.removeAll(); persist() }
    private func persist() { defaults.set(items, forKey: key) }
}

@MainActor @Observable
private final class SearchViewModel {
    var query = ""
    var scope: SearchScope = .videos
    var sortBy = "relevant"
    private(set) var videos: [Video] = []
    private(set) var people = PeopleSearchResult(models: [], albums: [])
    private(set) var isLoading = false
    private(set) var error: String?
    private let repository: VideoRepository
    private var requestID = UUID()
    init(repository: VideoRepository) { self.repository = repository }

    func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID(); requestID = id
        guard !text.isEmpty else { videos = []; people = PeopleSearchResult(models: [], albums: []); error = nil; isLoading = false; return }
        isLoading = true; error = nil
        do {
            switch scope {
            case .videos:
                let result = try await repository.searchVideos(query: text, page: 0, pageSize: 24, sortBy: sortBy == "relevant" ? nil : sortBy)
                guard requestID == id else { return }; videos = result
            case .people, .albums:
                let result = try await repository.searchPeople(text)
                guard requestID == id else { return }; people = result
            }
            if requestID == id { SearchHistory.shared.add(text); isLoading = false }
        } catch {
            guard requestID == id else { return }
            self.error = describeError(error, subject: "search results").message
            isLoading = false
        }
    }
}

struct SearchScreen: View {
    let dependencies: AppDependencies
    let onOpen: (Video, [Video]) -> Void
    @State private var vm: SearchViewModel
    @State private var selectedModel: ModelRef?
    @State private var selectedAlbum: AlbumRef?
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(dependencies: AppDependencies, onOpen: @escaping (Video, [Video]) -> Void) {
        self.dependencies = dependencies; self.onOpen = onOpen
        _vm = State(initialValue: SearchViewModel(repository: dependencies.repository))
    }

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 12), count: sizeClass == .regular ? 3 : 2) }

    var body: some View {
        @Bindable var vm = vm
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Videos, models, albums", text: $vm.query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).onSubmit { Task { await vm.search() } }
                if !vm.query.isEmpty {
                    Button { vm.query = ""; Task { await vm.search() } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                }
            }
            .padding(.horizontal, 14).frame(height: 48)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)

            Picker("Search type", selection: $vm.scope) {
                ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal, 16)
            .onChange(of: vm.scope) { _, _ in Task { await vm.search() } }

            if vm.scope == .videos {
                HStack {
                    Text("Sort by").font(.caption).foregroundStyle(.secondary)
                    Picker("Sort", selection: $vm.sortBy) {
                        Text("Relevant").tag("relevant")
                        Text("Most viewed").tag("views")
                        Text("Newest").tag("latest")
                        Text("Top rated").tag("rating")
                    }.pickerStyle(.menu).onChange(of: vm.sortBy) { _, _ in Task { await vm.search() } }
                    Spacer()
                }.padding(.horizontal, 16)
            }

            if vm.isLoading && vm.videos.isEmpty && vm.people.isEmpty {
                ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.error {
                ContentUnavailableView("Search failed", systemImage: "wifi.exclamationmark", description: Text(error))
            } else if vm.query.trimmingCharacters(in: .whitespaces).isEmpty {
                if vm.scope == .albums {
                    AllAlbumsCatalogView(dependencies: dependencies) { selectedAlbum = $0 }
                } else {
                    recentSearches
                }
            } else {
                results
            }
        }
        .padding(.top, 12)
        .background(Color(.systemBackground))
        .navigationTitle("Search").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedModel) { model in
            ModelBrowserView(model: model, dependencies: dependencies, onOpen: onOpen)
        }
        .sheet(item: $selectedAlbum) { album in
            AlbumBrowserView(album: album, dependencies: dependencies)
        }
        .task(id: vm.query) {
            guard !vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            await vm.search()
        }
    }

    @ViewBuilder private var recentSearches: some View {
        let history = SearchHistory.shared.items
        if history.isEmpty {
            ContentUnavailableView("Search videos and models", systemImage: "magnifyingglass", description: Text("Your recent searches will appear here."))
        } else {
            List {
                Section("Recent searches") {
                    ForEach(history, id: \.self) { item in
                        Button { vm.query = item; Task { await vm.search() } } label: {
                            Label(item, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                        }
                        .swipeActions { Button(role: .destructive) { SearchHistory.shared.remove(item) } label: { Label("Delete", systemImage: "trash") } }
                    }
                    Button("Clear search history", role: .destructive) { SearchHistory.shared.clear() }
                }
            }.listStyle(.insetGrouped)
        }
    }

    @ViewBuilder private var results: some View {
        switch vm.scope {
        case .videos:
            if vm.videos.isEmpty { ContentUnavailableView.search(text: vm.query) }
            else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(vm.videos) { video in VideoCard(video: video) { onOpen(video, vm.videos) } }
                    }.padding(16)
                }
            }
        case .people:
            if vm.people.models.isEmpty { ContentUnavailableView("No models found", systemImage: "person.crop.circle", description: Text("Try another name.")) }
            else {
                List(vm.people.models) { model in
                    Button { selectedModel = model } label: {
                        HStack(spacing: 12) {
                            ModelAvatar(name: model.name, imageURL: model.imageURL, pageURL: model.url, size: 48)
                            Text(model.name).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }.listStyle(.plain)
            }
        case .albums:
            if vm.people.albums.isEmpty { ContentUnavailableView("No albums found", systemImage: "photo.on.rectangle", description: Text("Try another search.")) }
            else {
                List(vm.people.albums) { album in
                    Button { selectedAlbum = album } label: {
                        HStack(spacing: 12) {
                            HeaderImage(url: URL(string: album.thumbnailURL ?? "") ?? URL(fileURLWithPath: "/"), maxPixel: 240)
                                .frame(width: 76, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading) { Text(album.title).foregroundStyle(.primary); if let model = album.modelName { Text(model).font(.caption).foregroundStyle(.secondary) } }
                            Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                }.listStyle(.plain)
            }
        }
    }
}

// MARK: - Library

private enum HistoryLibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case continuing = "Continue"
    case watched = "Watched"
    var id: String { rawValue }
}

struct LibraryView: View {
    let request: LibraryRequest?
    let dependencies: AppDependencies
    let onOpen: (Video, [Video]) -> Void
    let onBrowse: () -> Void
    @Environment(FavoritesStore.self) private var favorites
    @Environment(HistoryStore.self) private var history
    @Environment(PlaybackProgress.self) private var playbackProgress
    @Environment(DownloadStore.self) private var downloads
    @State private var segment: LibrarySegment = .favorites
    @State private var historyFilter: HistoryLibraryFilter = .all
    @State private var selectedModel: ModelRef?
    @State private var selectedSavedAlbum: SavedPhotoAlbum?
    @State private var offlinePhotoStore = OfflinePhotoAlbumsStore.shared

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LibrarySegment.allCases, id: \.self) { value in
                        Button { segment = value } label: {
                            Text(value.rawValue.capitalized)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(segment == value ? Color.vxAccent : Color(.secondarySystemBackground), in: Capsule())
                                .foregroundStyle(segment == value ? .white : .primary)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16)
            }.padding(.top, 12)
            Group {
                switch segment {
                case .favorites: videoList(favorites.items, emptyTitle: "No favorites yet", emptyMessage: "Save a video with the star button.")
                case .history: historyList
                case .downloads: downloadsList
                case .models: modelsList
                case .albums: albumsList
                }
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Library").navigationBarTitleDisplayMode(.inline)
        .onAppear { if let request { segment = request.segment } }
        .onChange(of: request?.token) { _, _ in if let request { segment = request.segment } }
        .sheet(item: $selectedModel) { model in ModelBrowserView(model: model, dependencies: dependencies, onOpen: onOpen) }
        .sheet(item: $selectedSavedAlbum) { album in OfflineAlbumBrowserView(albumID: album.id) }
    }

    @ViewBuilder private var historyList: some View {
        let entries = history.items.filter { entry in
            return switch historyFilter {
            case .all: true
            case .continuing: playbackProgress.resumePosition(for: entry.video.id) != nil
            case .watched: playbackProgress.isCompleted(entry.video.id)
            }
        }
        VStack(spacing: 10) {
            Picker("History filter", selection: $historyFilter) {
                ForEach(HistoryLibraryFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
            }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.top, 10)
            videoList(
                entries.map(\.video),
                emptyTitle: history.items.isEmpty ? "Nothing played yet" : (historyFilter == .watched ? "No watched videos" : "Nothing to continue"),
                emptyMessage: history.items.isEmpty ? "Videos you play will appear here." : "Try another history filter to see your videos."
            )
        }
    }

    @ViewBuilder private func videoList(_ videos: [Video], emptyTitle: String, emptyMessage: String) -> some View {
        if videos.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: "video.slash", description: Text(emptyMessage))
                .overlay(alignment: .bottom) { Button("Browse videos", action: onBrowse).buttonStyle(.borderedProminent).padding(.bottom, 35) }
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(videos) { video in
                        VideoCard(video: video) { onOpen(video, videos) }
                    }
                }.padding(16)
            }
        }
    }

    @ViewBuilder private var downloadsList: some View {
        let list = downloads.items.values.sorted { $0.video.title.localizedCaseInsensitiveCompare($1.video.title) == .orderedAscending }
        if list.isEmpty {
            ContentUnavailableView("No downloads", systemImage: "arrow.down.circle", description: Text("Downloaded videos will be available offline."))
                .overlay(alignment: .bottom) { Button("Browse videos", action: onBrowse).buttonStyle(.borderedProminent).padding(.bottom, 35) }
        } else {
            List {
                ForEach(list) { item in
                    HStack(spacing: 12) {
                        ArtworkView(video: item.video)
                            .frame(width: 104, height: 72).clipShape(RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.video.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            switch item.status {
                            case .done: Label("Available offline", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                            case .downloading: ProgressView(value: item.progress ?? 0).tint(.vxAccent)
                            case .queued: Text("Waiting to download").font(.caption).foregroundStyle(.secondary)
                            case .paused: Text("Paused").font(.caption).foregroundStyle(.secondary)
                            case .failed: Text("Download failed").font(.caption).foregroundStyle(.red)
                            }
                        }
                        Spacer(minLength: 0)
                        if item.status == .done {
                            Button { onOpen(item.video, list.map(\.video)) } label: { Image(systemName: "play.fill") }
                        } else if item.status == .paused || item.status == .failed {
                            Button { downloads.resume(item.id) } label: { Image(systemName: "arrow.clockwise") }
                        } else if item.status == .downloading || item.status == .queued {
                            Button { Task { await downloads.pause(item.id) } } label: { Image(systemName: "pause.fill") }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { Task { await downloads.remove(item.id) } } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }.listStyle(.plain)
        }
    }

    @ViewBuilder private var modelsList: some View {
        let models = ModelFavoritesStore.shared.items
        if models.isEmpty {
            ContentUnavailableView("No saved models", systemImage: "person.crop.circle", description: Text("Save a model profile to find it here."))
        } else {
            List(models) { model in
                HStack(spacing: 12) {
                    Button { selectedModel = model } label: {
                        HStack(spacing: 12) {
                            ModelAvatar(name: model.name, imageURL: model.imageURL, pageURL: model.url, size: 44)
                            Text(model.name).foregroundStyle(.primary)
                        }
                    }
                    Spacer()
                    Button { ModelFavoritesStore.shared.toggle(model) } label: { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                }
            }.listStyle(.plain)
        }
    }

    @ViewBuilder private var albumsList: some View {
        let albums = offlinePhotoStore.albums
        if albums.isEmpty {
            ContentUnavailableView("No saved albums yet", systemImage: "photo.on.rectangle", description: Text("Open an album and choose Download all to keep its photos offline."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("\(albums.count) albums · \(offlinePhotoStore.totalPhotos) photos")
                        .font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                        ForEach(albums) { album in
                            Button { selectedSavedAlbum = album } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    SavedAlbumCover(album: album, store: offlinePhotoStore)
                                        .frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 12))
                                    Text(album.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                                    Text("\(album.photos.count) photos" + (album.modelName.map { " · \($0)" } ?? ""))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete offline album", role: .destructive) { offlinePhotoStore.removeAlbum(album.id) }
                            }
                        }
                    }
                }.padding(16)
            }
        }
    }
}

private struct SavedAlbumCover: View {
    let album: SavedPhotoAlbum
    let store: OfflinePhotoAlbumsStore
    var body: some View {
        Group {
            if let photo = album.photos.first,
               let image = UIImage(contentsOfFile: store.fileURL(for: photo, in: album).path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack { Color(.secondarySystemBackground); Image(systemName: "photo.on.rectangle").font(.largeTitle).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
    }
}

// MARK: - Settings

struct SettingsView: View {
    @State private var showingClearHistory = false
    @State private var showingClearDownloads = false
    @State private var showingClearOfflinePhotos = false
    @State private var offlinePhotos = OfflinePhotoAlbumsStore.shared
    @Environment(HistoryStore.self) private var history
    @Environment(PlaybackProgress.self) private var progress
    @Environment(DownloadStore.self) private var downloads
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(get: { settings.themeMode }, set: settings.setThemeMode)) {
                    ForEach(AppThemeMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
            }
            Section("Playback & feedback") {
                Toggle("Autoplay next video", isOn: Binding(get: { settings.autoplayNext }, set: settings.setAutoplayNext))
                Toggle("Preview sound", isOn: Binding(get: { settings.previewSound }, set: settings.setPreviewSound))
                Toggle("Haptic feedback", isOn: Binding(get: { settings.haptics }, set: settings.setHaptics))
                Picker("Preferred quality", selection: Binding(get: { settings.preferredQuality }, set: settings.setPreferredQuality)) {
                    Text("Auto").tag(0); Text("360p").tag(360); Text("480p").tag(480); Text("720p").tag(720); Text("1080p").tag(1080); Text("2160p / 4K").tag(2160)
                }
            }
            Section("Storage & privacy") {
                LabeledContent("Completed downloads", value: "\(downloads.doneCount)")
                LabeledContent("Offline photo albums", value: "\(offlinePhotos.albums.count) · \(offlinePhotos.totalPhotos) photos")
                Button("Delete all downloads", role: .destructive) { showingClearDownloads = true }
                    .disabled(downloads.items.isEmpty)
                Button("Delete offline photo albums", role: .destructive) { showingClearOfflinePhotos = true }
                    .disabled(offlinePhotos.albums.isEmpty)
                Button("Clear watch history", role: .destructive) { showingClearHistory = true }
                    .disabled(history.items.isEmpty)
                Button("Clear search history", role: .destructive) { SearchHistory.shared.clear() }
            }
            Section("About") {
                LabeledContent("App", value: "VXTube")
                LabeledContent("Native platform", value: "SwiftUI · AVPlayer")
            }
        }
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear watch history?", isPresented: $showingClearHistory, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { history.clear(); progress.clearAll() }
        } message: { Text("This removes your watch history and saved resume positions.") }
        .confirmationDialog("Delete all downloads?", isPresented: $showingClearDownloads, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { Task { await downloads.removeAll() } }
        } message: { Text("All downloaded video files will be removed from this device.") }
        .confirmationDialog("Delete offline photo albums?", isPresented: $showingClearOfflinePhotos, titleVisibility: .visible) {
            Button("Delete all photo albums", role: .destructive) { offlinePhotos.clearAll() }
        } message: { Text("All locally saved album photos will be removed from this device. Photos already exported to the iOS Photos library will remain there.") }
    }
}

// MARK: - Model & album browsing

struct AllAlbumsCatalogView: View {
    let dependencies: AppDependencies
    let onSelect: (AlbumRef) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var albums: [AlbumRef] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var error: String?
    @State private var emptyPages = 0
    @State private var seen = Set<String>()

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14), count: sizeClass == .regular ? 3 : 2)
    }

    var body: some View {
        Group {
            if albums.isEmpty && isLoading {
                ProgressView("Loading albums…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if albums.isEmpty, let error {
                ContentUnavailableView("Couldn’t load albums", systemImage: "wifi.exclamationmark", description: Text(error))
                    .overlay(alignment: .bottom) { Button("Retry") { Task { await load(reset: true) } }.buttonStyle(.borderedProminent).padding(.bottom, 30) }
            } else if albums.isEmpty {
                ContentUnavailableView("No albums found", systemImage: "photo.on.rectangle", description: Text("There are no albums to browse right now."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(albums) { album in
                            Button { onSelect(album) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HeaderImage(url: URL(string: album.thumbnailURL ?? "") ?? URL(fileURLWithPath: "/"), headers: imageHeaders(for: album.url), maxPixel: 520)
                                        .frame(maxWidth: .infinity).aspectRatio(0.82, contentMode: .fill).clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    Text(album.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                                    if let model = album.modelName, !model.isEmpty { Text(model).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            .onAppear { if album.id == albums.last?.id, hasMore { Task { await load() } } }
                        }
                    }.padding(16)
                    if isLoading { ProgressView().padding(16) }
                    if let error {
                        VStack(spacing: 8) {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                            Button("Retry") { Task { await load() } }.buttonStyle(.bordered)
                        }.padding()
                    }
                }
            }
        }
        .task { await load() }
    }

    private func load(reset: Bool = false) async {
        guard !isLoading, hasMore || reset else { return }
        isLoading = true
        error = nil
        if reset {
            albums.removeAll(); seen.removeAll(); page = 1; emptyPages = 0; hasMore = true
        }
        do {
            let result = try await dependencies.repository.albums(for: nil, page: page)
            let fresh = result.filter { seen.insert($0.id).inserted }
            albums.append(contentsOf: fresh)
            page += 1
            emptyPages = fresh.isEmpty ? emptyPages + 1 : 0
            hasMore = !result.isEmpty && emptyPages < 2
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }
}

struct ModelBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    let model: ModelRef
    let dependencies: AppDependencies
    let onOpen: (Video, [Video]) -> Void
    @State private var videos: [Video] = []
    @State private var albums: [AlbumRef] = []
    @State private var selectedAlbum: AlbumRef?
    @State private var selectedTab = 0
    @State private var profile: ModelProfile?
    @State private var isLoadingVideos = false
    @State private var isLoadingAlbums = false
    @State private var videoPage = 1
    @State private var albumPage = 1
    @State private var hasMoreVideos = true
    @State private var hasMoreAlbums = true
    @State private var videoError: String?
    @State private var albumError: String?
    @State private var videoSeen = Set<String>()
    @State private var albumSeen = Set<String>()

    private var columns: [GridItem] { [GridItem(.flexible()), GridItem(.flexible())] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ModelAvatar(name: profile?.name ?? model.name,
                                imageURL: profile?.imageURL ?? model.imageURL,
                                pageURL: model.url, size: 58)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile?.name ?? model.name).font(.headline).lineLimit(2)
                        Text(selectedTab == 0 ? "\(videos.count) videos" : "\(albums.count) albums")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { ModelFavoritesStore.shared.toggle(model) } label: {
                        Image(systemName: ModelFavoritesStore.shared.isFavorite(model) ? "star.fill" : "star")
                            .font(.title3).foregroundStyle(.yellow)
                    }
                }.padding(.horizontal, 16).padding(.top, 10)

                Picker("Model content", selection: $selectedTab) {
                    Text("Videos").tag(0)
                    Text("Photos").tag(1)
                }.pickerStyle(.segmented).padding(.horizontal, 16)

                if selectedTab == 0 { videosContent } else { albumsContent }
            }
            .navigationTitle("Model").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $selectedAlbum) { album in AlbumBrowserView(album: album, dependencies: dependencies) }
            .task {
                await loadVideos()
                await loadAlbums()
            }
        }
    }

    @ViewBuilder private var videosContent: some View {
        if videos.isEmpty && isLoadingVideos {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if videos.isEmpty, let videoError {
            ContentUnavailableView("Couldn’t load videos", systemImage: "wifi.exclamationmark", description: Text(videoError))
                .overlay(alignment: .bottom) { Button("Retry") { Task { await loadVideos() } }.buttonStyle(.borderedProminent).padding(.bottom, 30) }
        } else if videos.isEmpty {
            ContentUnavailableView("No videos", systemImage: "video.slash", description: Text("This model has no videos yet."))
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(videos) { video in
                        VideoCard(video: video) { onOpen(video, videos) }
                            .onAppear { if video.id == videos.last?.id, hasMoreVideos { Task { await loadVideos() } } }
                    }
                }.padding(16)
                if isLoadingVideos { ProgressView().padding(16) }
                if let videoError {
                    VStack(spacing: 8) {
                        Text("Couldn’t load more videos: \(videoError)").font(.caption).foregroundStyle(.secondary)
                        Button("Retry") { Task { await loadVideos() } }.buttonStyle(.bordered)
                    }.padding()
                }
            }
        }
    }

    @ViewBuilder private var albumsContent: some View {
        if albums.isEmpty && isLoadingAlbums {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if albums.isEmpty, let albumError {
            ContentUnavailableView("Couldn’t load albums", systemImage: "wifi.exclamationmark", description: Text(albumError))
                .overlay(alignment: .bottom) { Button("Retry") { Task { await loadAlbums() } }.buttonStyle(.borderedProminent).padding(.bottom, 30) }
        } else if albums.isEmpty {
            ContentUnavailableView("No photo albums", systemImage: "photo.on.rectangle", description: Text("This model has no photo albums."))
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(albums) { album in
                        Button { selectedAlbum = album } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HeaderImage(url: URL(string: album.thumbnailURL ?? "") ?? URL(fileURLWithPath: "/"), headers: imageHeaders(for: album.url), maxPixel: 480)
                                    .frame(maxWidth: .infinity).aspectRatio(0.82, contentMode: .fill).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                Text(album.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        .onAppear { if album.id == albums.last?.id, hasMoreAlbums { Task { await loadAlbums() } } }
                    }
                }.padding(16)
                if isLoadingAlbums { ProgressView().padding(16) }
                if let albumError {
                    VStack(spacing: 8) {
                        Text("Couldn’t load more albums: \(albumError)").font(.caption).foregroundStyle(.secondary)
                        Button("Retry") { Task { await loadAlbums() } }.buttonStyle(.bordered)
                    }.padding()
                }
            }
        }
    }

    private func loadVideos() async {
        guard !isLoadingVideos, hasMoreVideos else { return }
        isLoadingVideos = true; videoError = nil
        do {
            let result = try await dependencies.repository.modelPage(model, page: videoPage)
            if profile == nil { profile = result.profile }
            let fresh = result.videos.filter { videoSeen.insert($0.id).inserted }
            videos.append(contentsOf: fresh)
            videoPage += 1
            if result.videos.isEmpty || fresh.isEmpty { hasMoreVideos = false }
            isLoadingVideos = false
        } catch {
            videoError = error.localizedDescription
            isLoadingVideos = false
        }
    }

    private func loadAlbums() async {
        guard !isLoadingAlbums, hasMoreAlbums else { return }
        isLoadingAlbums = true; albumError = nil
        do {
            let result = try await dependencies.repository.albums(for: model, page: albumPage)
            let fresh = result.filter { albumSeen.insert($0.id).inserted }
            albums.append(contentsOf: fresh)
            albumPage += 1
            if result.isEmpty || fresh.isEmpty { hasMoreAlbums = false }
            isLoadingAlbums = false
        } catch {
            albumError = error.localizedDescription
            isLoadingAlbums = false
        }
    }
}

struct AlbumBrowserView: View {
    let album: AlbumRef
    let dependencies: AppDependencies
    @Environment(\.dismiss) private var dismiss
    @State private var photos: [AlbumPhoto] = []
    @State private var selectedIDs = Set<String>()
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var nextChunk = 0
    @State private var staleChunks = 0
    @State private var loadError: String?
    @State private var isSelecting = false
    @State private var isSaving = false
    @State private var notice: String?
    @State private var preview: AlbumPhoto?
    @State private var offlineStore = OfflinePhotoAlbumsStore.shared

    private var selectedPhotos: [AlbumPhoto] { photos.filter { selectedIDs.contains($0.id) } }
    private var albumHeaders: [String: String]? { imageHeaders(for: album.url) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("\(photos.count) photos" + (hasMore ? " · loading more" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if isSelecting {
                        Button("Select all") { selectedIDs = Set(photos.map(\.id)) }
                            .font(.caption.weight(.semibold))
                        Button("Cancel") { isSelecting = false; selectedIDs.removeAll() }
                            .font(.caption.weight(.semibold))
                    } else {
                        Button("Select") { isSelecting = true }
                            .font(.caption.weight(.semibold))
                    }
                }.padding(.horizontal, 16).padding(.vertical, 10)

                if photos.isEmpty && isLoading {
                    ProgressView("Loading photos…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if photos.isEmpty, let loadError {
                    ContentUnavailableView("Couldn’t load photos", systemImage: "wifi.exclamationmark", description: Text(loadError))
                        .overlay(alignment: .bottom) { Button("Retry") { Task { await loadNextChunk() } }.buttonStyle(.borderedProminent).padding(.bottom, 30) }
                } else if photos.isEmpty && !hasMore {
                    ContentUnavailableView("No photos", systemImage: "photo.on.rectangle", description: Text("This album appears to be empty."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                            ForEach(photos) { photo in
                                Button {
                                    if isSelecting {
                                        if !selectedIDs.insert(photo.id).inserted { selectedIDs.remove(photo.id) }
                                    } else { preview = photo }
                                } label: {
                                    ZStack(alignment: .topTrailing) {
                                        HeaderImage(url: URL(string: photo.thumbURL) ?? URL(fileURLWithPath: "/"), headers: albumHeaders, maxPixel: 420)
                                            .frame(maxWidth: .infinity).aspectRatio(3 / 4, contentMode: .fill).clipped()
                                            .background(Color(.secondarySystemBackground))
                                        if selectedIDs.contains(photo.id) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.title2).symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, Color.vxAccent).padding(6)
                                        } else if offlineStore.isSaved(album.id, photoID: photo.id) {
                                            Image(systemName: "arrow.down.circle.fill")
                                                .font(.title3).symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .green).padding(6)
                                        }
                                    }.clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .onLongPressGesture {
                                    if !isSelecting { isSelecting = true; selectedIDs.insert(photo.id) }
                                }
                                .onAppear {
                                    if photo.id == photos.last?.id, hasMore { Task { await loadNextChunk() } }
                                }
                            }
                        }.padding(5)
                        if isLoading { ProgressView().padding(20) }
                        if let loadError {
                            VStack(spacing: 8) {
                                Text(loadError).font(.caption).foregroundStyle(.secondary)
                                Button("Retry loading") { Task { await loadNextChunk() } }.buttonStyle(.bordered)
                            }.padding()
                        }
                    }
                }

                if isSelecting || !photos.isEmpty {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isSelecting ? "\(selectedIDs.count) selected" : (offlineStore.progressByAlbum[album.id].map { "Saving \($0.completed)/\($0.total)" } ?? "Save this album offline"))
                                .font(.caption.weight(.semibold))
                            if let progress = offlineStore.progressByAlbum[album.id] {
                                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                                    .tint(.vxAccent).frame(width: 100)
                            }
                        }
                        Spacer(minLength: 0)
                        Button {
                            Task { await downloadToOffline() }
                        } label: {
                            Label(isSelecting ? "Download selected" : "Download all", systemImage: "arrow.down.to.line")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving || (isSelecting && selectedIDs.isEmpty) || offlineStore.progressByAlbum[album.id] != nil)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.bar)
                }
            }
            .navigationTitle(album.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .task { await loadNextChunk() }
            .sheet(item: $preview) { photo in RemoteAlbumPhotoPreview(photo: photo, album: album, headers: albumHeaders) }
            .alert("Album", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) { notice = nil }
            } message: { Text(notice ?? "") }
        }
    }

    private func loadNextChunk() async {
        guard !isLoading, hasMore, nextChunk <= 400 else { return }
        isLoading = true; loadError = nil
        do {
            let chunk = try await dependencies.repository.albumPhotos(album, chunk: nextChunk)
            var seen = Set(photos.map(\.id))
            let fresh = chunk.filter { seen.insert($0.id).inserted }
            photos.append(contentsOf: fresh)
            nextChunk += 1
            staleChunks = fresh.isEmpty ? staleChunks + 1 : 0
            if chunk.isEmpty || staleChunks >= 3 || nextChunk > 400 { hasMore = false }
            isLoading = false
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    private func loadAllPhotos() async -> Bool {
        while hasMore {
            if isLoading {
                try? await Task.sleep(for: .milliseconds(80))
            } else {
                await loadNextChunk()
            }
            if loadError != nil { return false }
        }
        return true
    }

    private func downloadToOffline() async {
        guard !isSaving else { return }
        isSaving = true
        var chosen = selectedPhotos
        if !isSelecting {
            guard await loadAllPhotos() else { isSaving = false; return }
            chosen = photos
        }
        let summary = await offlineStore.savePhotos(chosen, from: album, modelName: album.modelName, headers: albumHeaders)
        isSaving = false
        isSelecting = false
        selectedIDs.removeAll()
        if summary.requested == 0 {
            notice = "These photos are already saved offline."
        } else {
            notice = "Saved \(summary.saved) of \(summary.requested) photos.\(summary.failed > 0 ? " \(summary.failed) failed." : "")"
        }
    }
}

private struct RemoteAlbumPhotoPreview: View {
    let photo: AlbumPhoto
    let album: AlbumRef
    let headers: [String: String]?
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else { ProgressView().tint(.white) }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() }.foregroundStyle(.white) }
            }
            .task(id: photo.fullURL) {
                guard let url = URL(string: photo.fullURL) else { return }
                image = await RemoteImageLoader.shared.image(url: url, headers: headers, maxPixel: 3000)
            }
        }
    }
}

struct OfflineAlbumBrowserView: View {
    let albumID: String
    @Environment(\.dismiss) private var dismiss
    @State private var store = OfflinePhotoAlbumsStore.shared
    @State private var selectedIDs = Set<String>()
    @State private var isSelecting = false
    @State private var preview: SavedPhotoAsset?
    @State private var notice: String?

    private var album: SavedPhotoAlbum? { store.album(albumID) }
    private var selectedURLs: [URL] {
        guard let album else { return [] }
        return album.photos.filter { selectedIDs.contains($0.id) }.map { store.fileURL(for: $0, in: album) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let album {
                    VStack(spacing: 0) {
                        HStack {
                            Text("\(album.photos.count) photos saved on this device").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button(isSelecting ? "Cancel" : "Select") {
                                isSelecting.toggle(); selectedIDs.removeAll()
                            }.font(.caption.weight(.semibold))
                            if isSelecting {
                                Button("All") { selectedIDs = Set(album.photos.map(\.id)) }.font(.caption.weight(.semibold))
                            }
                        }.padding(.horizontal, 16).padding(.vertical, 10)
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)], spacing: 4) {
                                ForEach(album.photos) { photo in
                                    let url = store.fileURL(for: photo, in: album)
                                    Button {
                                        if isSelecting {
                                            if !selectedIDs.insert(photo.id).inserted { selectedIDs.remove(photo.id) }
                                        } else { preview = photo }
                                    } label: {
                                        ZStack(alignment: .topTrailing) {
                                            LocalPhotoTile(url: url).aspectRatio(3 / 4, contentMode: .fill).clipped()
                                            if selectedIDs.contains(photo.id) {
                                                Image(systemName: "checkmark.circle.fill").font(.title2).symbolRenderingMode(.palette).foregroundStyle(.white, Color.vxAccent).padding(6)
                                            }
                                        }.clipShape(RoundedRectangle(cornerRadius: 6))
                                    }.buttonStyle(.plain)
                                }
                            }.padding(5)
                        }
                        if isSelecting {
                            HStack {
                                Text("\(selectedIDs.count) selected").font(.caption.weight(.semibold))
                                Spacer()
                                Button(role: .destructive) { deleteSelected() } label: { Label("Delete", systemImage: "trash") }
                                    .disabled(selectedIDs.isEmpty)
                                Button { Task { await saveSelectedToPhotos() } } label: { Label("Save to Photos", systemImage: "photo") }
                                    .buttonStyle(.borderedProminent).disabled(selectedIDs.isEmpty)
                            }.padding(12).background(.bar)
                        }
                    }
                } else {
                    ContentUnavailableView("Album not found", systemImage: "photo.on.rectangle")
                }
            }
            .navigationTitle(album?.title ?? "Saved album").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let album, !isSelecting {
                        Button(role: .destructive) { store.removeAlbum(album.id); dismiss() } label: { Image(systemName: "trash") }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(item: $preview) { photo in
                if let album {
                    LocalPhotoPreview(url: store.fileURL(for: photo, in: album), title: album.title)
                }
            }
            .alert("Photos", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("OK", role: .cancel) { notice = nil }
            } message: { Text(notice ?? "") }
        }
    }

    private func deleteSelected() {
        for id in selectedIDs { store.removePhoto(albumID: albumID, photoID: id) }
        selectedIDs.removeAll(); isSelecting = false
    }

    private func saveSelectedToPhotos() async {
        let urls = selectedURLs
        switch await PhotoSaver.saveImages(at: urls) {
        case .saved(let count): notice = "Saved \(count) photos to your Photos library."
        case .denied: notice = "Allow photo-library access in iOS Settings to save photos."
        case .failed(let count): notice = "Couldn’t save the selected photos (\(count))."
        }
    }
}

private struct LocalPhotoTile: View {
    let url: URL
    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFill() }
            else { ZStack { Color(.secondarySystemBackground); Image(systemName: "photo") .foregroundStyle(.secondary) } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
    }
}

private struct LocalPhotoPreview: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFit().background(.black) }
                else { ContentUnavailableView("Image unavailable", systemImage: "photo") }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

