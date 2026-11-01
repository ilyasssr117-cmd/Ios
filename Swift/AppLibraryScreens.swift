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
    let onClose: () -> Void
    @State private var vm: SearchViewModel
    @State private var selectedModel: ModelRef?
    @State private var selectedAlbum: AlbumRef?
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(dependencies: AppDependencies, onOpen: @escaping (Video, [Video]) -> Void,
         onClose: @escaping () -> Void = {}) {
        self.dependencies = dependencies
        self.onOpen = onOpen
        self.onClose = onClose
        _vm = State(initialValue: SearchViewModel(repository: dependencies.repository))
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: sizeClass == .regular ? 3 : 2)
    }

    var body: some View {
        @Bindable var vm = vm
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Search")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .tracking(-1.0)
                        Text("Find videos, people and albums")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel", action: onClose)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.tint)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close search")
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                    TextField("Search videos, models, albums", text: $vm.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await vm.search() } }
                    if !vm.query.isEmpty {
                        Button { vm.query = ""; Task { await vm.search() } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 56)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.18)))
                .shadow(color: .black.opacity(0.05), radius: 16, y: 6)
                .padding(.horizontal, 16)

                SearchFilterBar(scope: $vm.scope, sortBy: $vm.sortBy)
                    .padding(.horizontal, 16)
                    .onChange(of: vm.scope) { _, _ in Task { await vm.search() } }
                    .onChange(of: vm.sortBy) { _, _ in Task { await vm.search() } }

                Group {
                    if vm.isLoading && vm.videos.isEmpty && vm.people.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 100)
                    } else if let error = vm.error {
                        ModernEmptyState(icon: "wifi.exclamationmark", title: "Search failed", message: error)
                            .padding(.top, 60)
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
            }
            .padding(.bottom, 110)
        }
        .background(VXTheme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedModel) { model in ModelBrowserView(model: model, dependencies: dependencies, onOpen: onOpen) }
        .sheet(item: $selectedAlbum) { album in AlbumBrowserView(album: album, dependencies: dependencies) }
        .task(id: vm.query) {
            guard !vm.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            await vm.search()
        }
    }

    @ViewBuilder private var recentSearches: some View {
        let history = SearchHistory.shared.items
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent searches").font(.headline)
                Spacer()
                if !history.isEmpty {
                    Button("Clear") { SearchHistory.shared.clear() }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                }
            }
            if history.isEmpty {
                ModernEmptyState(icon: "clock", title: "No recent searches", message: "Your searches will appear here.")
            } else {
                VStack(spacing: 8) {
                    ForEach(history, id: \.self) { item in
                        Button { vm.query = item; Task { await vm.search() } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 34, height: 34)
                                    .background(.thinMaterial, in: Circle())
                                Text(item).font(.body.weight(.medium)).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.left").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14).frame(minHeight: 58)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { Button(role: .destructive) { SearchHistory.shared.remove(item) } label: { Label("Delete", systemImage: "trash") } }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var results: some View {
        switch vm.scope {
        case .videos:
            if vm.videos.isEmpty {
                ModernEmptyState(icon: "magnifyingglass", title: "No videos found", message: "Try a different search.")
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(vm.videos) { video in VideoCard(video: video) { onOpen(video, vm.videos) } }
                }
                .padding(.horizontal, 16)
            }
        case .people:
            if vm.people.models.isEmpty {
                ModernEmptyState(icon: "person.crop.circle", title: "No models found", message: "Try another name.")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(vm.people.models) { model in
                        Button { selectedModel = model } label: {
                            HStack(spacing: 13) {
                                ModelAvatar(name: model.name, imageURL: model.imageURL, pageURL: model.url, size: 50)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.name).font(.headline).foregroundStyle(.primary)
                                    Text("Open profile").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        case .albums:
            if vm.people.albums.isEmpty {
                ModernEmptyState(icon: "photo.on.rectangle.angled", title: "No albums found", message: "Try another search.")
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(vm.people.albums) { album in
                        Button { selectedAlbum = album } label: {
                            HStack(spacing: 13) {
                                HeaderImage(url: URL(string: album.thumbnailURL ?? "") ?? URL(fileURLWithPath: "/"), maxPixel: 240)
                                    .frame(width: 84, height: 70)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(album.title).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                    if let model = album.modelName { Text(model).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                            }
                            .padding(10)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

private struct SearchFilterBar: View {
    @Binding var scope: SearchScope
    @Binding var sortBy: String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchScope.allCases) { value in
                    let selected = scope == value
                    Button {
                        Haptics.play(.selection)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { scope = value }
                    } label: {
                        Text(value.rawValue)
                            .font(.subheadline.weight(selected ? .semibold : .medium))
                            .foregroundStyle(selected ? .primary : .secondary)
                            .padding(.horizontal, 13).frame(height: 38)
                            .background(selected ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thinMaterial), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 24).padding(.horizontal, 2)
                if scope == .videos {
                    filter("Relevant", value: "relevant")
                    filter("By duration", value: "duration")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func filter(_ label: String, value: String) -> some View {
        let selected = sortBy == value
        return Button {
            Haptics.play(.selection)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { sortBy = value }
        } label: {
            Text(label).font(.subheadline.weight(selected ? .semibold : .medium))
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.horizontal, 13).frame(height: 38)
                .background(selected ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thinMaterial), in: Capsule())
        }
        .buttonStyle(.plain)
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

    private var accent: Color { .vxAccent }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Library")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .tracking(-1.0)
                    Text("Your saved videos, history and offline content")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                LibrarySectionPicker(selection: $segment)
                    .padding(.horizontal, 16)

                Group {
                    switch segment {
                    case .favorites:
                        if favorites.items.isEmpty {
                            ModernEmptyState(icon: "star.fill", title: "No favorites yet",
                                             message: "Save videos you want to watch later.",
                                             actionTitle: "Browse videos", actionIcon: "house.fill", action: onBrowse)
                                .padding(.top, 44)
                        } else {
                            videoList(favorites.items, emptyTitle: "No favorites yet", emptyMessage: "Save videos you want to watch later.")
                        }
                    case .history:
                        historyList
                    case .downloads:
                        downloadsList
                    case .models:
                        modelsList
                    }
                }
            }
            .padding(.bottom, 110)
        }
        .scrollClipDisabled()
        .background(VXTheme.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if let request { segment = request.segment } }
        .onChange(of: request?.token) { _, _ in if let request { segment = request.segment } }
        .sheet(item: $selectedModel) { model in ModelBrowserView(model: model, dependencies: dependencies, onOpen: onOpen) }
        .sheet(item: $selectedSavedAlbum) { album in OfflineAlbumBrowserView(albumID: album.id) }
    }

    @ViewBuilder private var historyList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HistoryFilterPicker(selection: $historyFilter)
                .padding(.horizontal, 16)
            let entries = history.items.filter { entry in
                switch historyFilter {
                case .all: true
                case .continuing: playbackProgress.resumePosition(for: entry.video.id) != nil
                case .watched: playbackProgress.isCompleted(entry.video.id)
                }
            }
            videoList(
                entries.map(\.video),
                emptyTitle: history.items.isEmpty ? "Nothing played yet" : (historyFilter == .watched ? "No watched videos" : "Nothing to continue"),
                emptyMessage: history.items.isEmpty ? "Videos you play will appear here." : "Try another filter to see more."
            )
        }
    }

    @ViewBuilder private func videoList(_ videos: [Video], emptyTitle: String, emptyMessage: String) -> some View {
        if videos.isEmpty {
            ModernEmptyState(icon: "play.slash", title: emptyTitle, message: emptyMessage, actionTitle: "Browse videos", action: onBrowse)
                .padding(.top, 44)
        } else {
            LazyVStack(spacing: 14) {
                ForEach(videos) { video in
                    LibraryVideoRow(video: video) { onOpen(video, videos) }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder private var downloadsList: some View {
        let list = downloads.items.values.sorted { $0.video.title.localizedCaseInsensitiveCompare($1.video.title) == .orderedAscending }
        if list.isEmpty {
            ModernEmptyState(icon: "arrow.down.circle", title: "No downloads", message: "Downloaded videos will be available offline.", actionTitle: "Browse videos", action: onBrowse)
                .padding(.top, 44)
        } else {
            LazyVStack(spacing: 12) {
                ForEach(list) { item in
                    LibraryDownloadRow(item: item,
                                       onPlay: { onOpen(item.video, list.map(\.video)) },
                                       onResume: { downloads.resume(item.id) },
                                       onPause: { Task { await downloads.pause(item.id) } })
                    .swipeActions {
                        Button(role: .destructive) { Task { await downloads.remove(item.id) } } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder private var modelsList: some View {
        let models = ModelFavoritesStore.shared.items
        if models.isEmpty {
            ModernEmptyState(icon: "person.crop.circle", title: "No saved models", message: "Save a model profile to find it here.")
                .padding(.top, 44)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(models) { model in
                    Button { selectedModel = model } label: {
                        HStack(spacing: 13) {
                            ModelAvatar(name: model.name, imageURL: model.imageURL, pageURL: model.url, size: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.name).font(.headline).foregroundStyle(.primary)
                                Text("Saved profile").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(14)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.18)))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { ModelFavoritesStore.shared.toggle(model) } label: { Label("Remove favorite", systemImage: "star.slash") }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder private var albumsList: some View {
        let albums = offlinePhotoStore.albums
        if albums.isEmpty {
            ModernEmptyState(icon: "photo.on.rectangle.angled", title: "No saved albums", message: "Download an album to keep its photos offline.")
                .padding(.top, 44)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(albums.count) albums · \(offlinePhotoStore.totalPhotos) photos")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 14) {
                    ForEach(albums) { album in
                        Button { selectedSavedAlbum = album } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                SavedAlbumCover(album: album, store: offlinePhotoStore)
                                    .frame(height: 155)
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                Text(album.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                                Text("\(album.photos.count) photos" + (album.modelName.map { " · \($0)" } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { Button("Delete offline album", role: .destructive) { offlinePhotoStore.removeAlbum(album.id) } }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct LibrarySectionPicker: View {
    @Binding var selection: LibrarySegment
    private let icons: [LibrarySegment: String] = [
        .favorites: "star.fill", .models: "person.2.fill", .history: "clock", .downloads: "arrow.down.circle.fill"
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibrarySegment.allCases, id: \.self) { value in
                    let selected = selection == value
                    Button {
                        Haptics.play(.selection)
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selection = value }
                    } label: {
                        Label(value.rawValue.capitalized, systemImage: icons[value] ?? "circle")
                            .font(.subheadline.weight(selected ? .semibold : .medium))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(selected ? Color.primary : Color.secondary)
                            .padding(.horizontal, 14)
                            .frame(height: 42)
                            .background(selected ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thinMaterial), in: Capsule(style: .continuous))
                            .overlay(Capsule(style: .continuous).strokeBorder(selected ? Color.white.opacity(0.28) : Color.primary.opacity(0.06), lineWidth: 0.8))
                            .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 12, y: 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct HistoryFilterPicker: View {
    @Binding var selection: HistoryLibraryFilter
    var body: some View {
        HStack(spacing: 6) {
            ForEach(HistoryLibraryFilter.allCases) { value in
                let selected = selection == value
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { selection = value }
                } label: {
                    Text(value.rawValue)
                        .font(.caption.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(selected ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.clear), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.thinMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.18)))
    }
}

private struct LibraryVideoRow: View {
    let video: Video
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ArtworkView(video: video)
                    .frame(width: 128, height: 82)
                    .overlay(alignment: .bottomTrailing) {
                        if !video.duration.isEmpty {
                            Text(video.duration)
                                .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .background(.black.opacity(0.68), in: Capsule())
                                .padding(6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(video.title).font(.system(.subheadline, design: .rounded).weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                    HStack(spacing: 8) {
                        if !video.likes.isEmpty { Label(video.likes, systemImage: "hand.thumbsup.fill").foregroundStyle(.tint) }
                        if !video.views.isEmpty { Label(video.views, systemImage: "eye") }
                    }
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
    }
}

private struct LibraryDownloadRow: View {
    let item: DownloadItem
    let onPlay: () -> Void
    let onResume: () -> Void
    let onPause: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(video: item.video)
                .frame(width: 118, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
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
            Button {
                switch item.status {
                case .done: onPlay()
                case .paused, .failed: onResume()
                case .downloading, .queued: onPause()
                }
            } label: {
                Image(systemName: item.status == .done ? "play.fill" : (item.status == .downloading || item.status == .queued ? "pause.fill" : "arrow.clockwise"))
                    .font(.subheadline.weight(.bold))
                    .frame(width: 38, height: 38)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(.white.opacity(0.16)))
    }
}

private struct ModernEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var actionIcon: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 58, height: 58)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 28)
            if let actionTitle, let action {
                Button(action: action) {
                    if let actionIcon { Label(actionTitle, systemImage: actionIcon) }
                    else { Text(actionTitle) }
                }
                    .buttonStyle(.borderedProminent)
                    .tint(.vxAccent)
                    .controlSize(.large)
                    .clipShape(Capsule(style: .continuous))
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
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
    @State private var cacheBytes = URLCache.shared.currentDiskUsage
    @Environment(HistoryStore.self) private var history
    @Environment(PlaybackProgress.self) private var progress
    @Environment(DownloadStore.self) private var downloads
    @State private var settings = AppSettings.shared

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Settings")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .tracking(-1.0)
                    Text("Personalize playback, appearance and storage")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                SettingsGroup(title: "Appearance", icon: "paintbrush.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Theme", systemImage: "circle.lefthalf.filled")
                            .font(.body.weight(.medium))
                            .padding(.horizontal, 15)
                        Picker("Theme", selection: Binding(get: { settings.themeMode }, set: settings.setThemeMode)) {
                            ForEach(AppThemeMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 15)
                        .padding(.bottom, 12)
                    }
                }

                SettingsGroup(title: "Playback & feedback", icon: "play.circle.fill") {
                    SettingsToggleRow(icon: "forward.end.fill", title: "Autoplay next video", subtitle: "Continue with the next one when a video ends", isOn: Binding(get: { settings.autoplayNext }, set: settings.setAutoplayNext))
                    SettingsDivider()
                    SettingsToggleRow(icon: "speaker.wave.2.fill", title: "Preview sound", subtitle: "Enable audio in video previews", isOn: Binding(get: { settings.previewSound }, set: settings.setPreviewSound))
                    SettingsDivider()
                    SettingsToggleRow(icon: "iphone.radiowaves.left.and.right", title: "Haptic feedback", subtitle: "Use subtle ticks for app actions", isOn: Binding(get: { settings.haptics }, set: settings.setHaptics))
                    SettingsDivider()
                    SettingsRow(icon: "sparkles.tv.fill", title: "Preferred quality", subtitle: "Default resolution for playback") {
                        Picker("Quality", selection: Binding(get: { settings.preferredQuality }, set: settings.setPreferredQuality)) {
                            Text("Auto").tag(0); Text("360p").tag(360); Text("480p").tag(480); Text("720p").tag(720); Text("1080p").tag(1080); Text("2160p / 4K").tag(2160)
                        }
                        .pickerStyle(.menu)
                        .tint(.vxAccent)
                    }
                }

                SettingsGroup(title: "Storage", icon: "externaldrive.fill") {
                    SettingsValueRow(icon: "arrow.down.circle.fill", title: "Completed downloads", value: "\(downloads.doneCount)")
                    SettingsDivider()
                    SettingsValueRow(icon: "photo.stack.fill", title: "Offline photo albums", value: "\(offlinePhotos.albums.count) · \(offlinePhotos.totalPhotos)")
                    SettingsDivider()
                    SettingsActionRow(title: "Clear cache (\(String(format: "%.1f MB", Double(cacheBytes) / 1_048_576)))") {
                        URLCache.shared.removeAllCachedResponses()
                        cacheBytes = URLCache.shared.currentDiskUsage
                    }
                    SettingsDivider()
                    SettingsActionRow(title: downloads.items.isEmpty ? "Delete all downloads · Nothing saved" : "Delete all downloads", role: .destructive) { showingClearDownloads = true }.disabled(downloads.items.isEmpty)
                    SettingsDivider()
                    SettingsActionRow(title: "Delete offline photo albums", role: .destructive) { showingClearOfflinePhotos = true }.disabled(offlinePhotos.albums.isEmpty)
                }

                SettingsGroup(title: "Privacy", icon: "hand.raised.fill") {
                    SettingsActionRow(title: "Clear watch history", role: .destructive) { showingClearHistory = true }.disabled(history.items.isEmpty)
                    SettingsDivider()
                    SettingsActionRow(title: "Clear search history", role: .destructive) { SearchHistory.shared.clear() }
                }

                SettingsGroup(title: "About", icon: "info.circle.fill") {
                    SettingsValueRow(icon: "play.rectangle.fill", title: "App", value: "VXTube")
                    SettingsDivider()
                    SettingsValueRow(icon: "swift", title: "Native platform", value: "SwiftUI · AVPlayer")
                }
            }
            .padding(.bottom, 110)
        }
        .background(VXTheme.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
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

private struct SettingsGroup<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title.uppercased(), systemImage: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
            VStack(spacing: 0) { content }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.9)
                }
                .shadow(color: .black.opacity(0.045), radius: 16, y: 7)
        }
        .padding(.horizontal, 16)
    }
}

private struct SettingsRow<Accessory: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let accessory: Accessory
    var body: some View {
        HStack(spacing: 13) {
            SettingsIcon(systemName: icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 10)
            accessory
        }
        .padding(.horizontal, 15).frame(minHeight: 58)
    }
}

private struct SettingsToggleRow: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 13) {
            SettingsIcon(systemName: icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().tint(.vxAccent)
        }
        .padding(.horizontal, 15).frame(minHeight: 58)
    }
}

private struct SettingsValueRow: View {
    let icon: String
    let title: String
    let value: String
    var body: some View {
        HStack(spacing: 13) {
            SettingsIcon(systemName: icon)
            Text(title).font(.body.weight(.medium))
            Spacer(minLength: 10)
            Text(value).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 15).frame(minHeight: 58)
    }
}

private struct SettingsActionRow: View {
    let title: String
    var role: ButtonRole? = nil
    let action: () -> Void
    var body: some View {
        Button(role: role, action: action) {
            HStack { Text(title).font(.body.weight(.medium)); Spacer() }
                .padding(.horizontal, 15).frame(minHeight: 58)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? .red : .primary)
    }
}

private struct SettingsIcon: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.tint)
            .frame(width: 34, height: 34)
            .background(Color.vxAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SettingsDivider: View {
    var body: some View { Divider().padding(.leading, 62) }
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
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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

                HStack(spacing: 6) {
                    modelScopeButton("Videos", symbol: "play.rectangle.fill", tag: 0)
                    modelScopeButton("Photos", symbol: "photo.stack.fill", tag: 1)
                }
                .padding(4)
                .background(.thinMaterial, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.8))
                .padding(.horizontal, 16)

                if selectedTab == 0 { videosContent } else { albumsContent }
            }
            .navigationTitle("Model").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $selectedAlbum) { album in
                AlbumBrowserView(album: album, dependencies: dependencies)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(32)
                    .presentationContentInteraction(.scrolls)
            }
            .task {
                // Fetch the model's video and album endpoints concurrently; each
                // grid can render its own skeleton while its request is pending.
                async let videos: Void = loadVideos()
                async let albums: Void = loadAlbums()
                _ = await (videos, albums)
            }
        }
    }

    private func modelScopeButton(_ title: String, symbol: String, tag: Int) -> some View {
        let selected = selectedTab == tag
        return Button {
            Haptics.play(.selection)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { selectedTab = tag }
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(selected ? .semibold : .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(selected ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(Color.clear),
                            in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var videosContent: some View {
        if videos.isEmpty && isLoadingVideos {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(0..<6, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.secondary.opacity(0.16))
                                .aspectRatio(16 / 9, contentMode: .fit)
                            Text("Loading video title").font(.subheadline.weight(.semibold))
                            Text("00:00 · 0 views").font(.caption)
                        }
                        .redacted(reason: .placeholder)
                    }
                }
                .padding(16)
            }
            .accessibilityLabel("Loading model videos")
        } else if videos.isEmpty, let videoError {
            ContentUnavailableView("Couldn’t load videos", systemImage: "wifi.exclamationmark", description: Text(videoError))
                .overlay(alignment: .bottom) { Button("Retry") { Task { await loadVideos() } }.buttonStyle(.borderedProminent).padding(.bottom, 30) }
        } else if videos.isEmpty {
            ContentUnavailableView("No videos", systemImage: "video.slash", description: Text("This model has no videos yet."))
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(videos) { video in
                        VideoCard(video: video) { openVideo(video) }
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
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(0..<6, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.secondary.opacity(0.16))
                                .aspectRatio(0.82, contentMode: .fit)
                            Text("Loading album title").font(.subheadline.weight(.semibold))
                        }
                        .redacted(reason: .placeholder)
                    }
                }
                .padding(16)
            }
            .accessibilityLabel("Loading model albums")
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
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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

    private func openVideo(_ video: Video) {
        let queue = videos
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            onOpen(video, queue)
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
            videoError = describeError(error, subject: "model videos").message
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
            albumError = describeError(error, subject: "model albums").message
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
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
                            ForEach(0..<9, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.secondary.opacity(0.16))
                                    .aspectRatio(3 / 4, contentMode: .fit)
                                    .redacted(reason: .placeholder)
                            }
                        }
                        .padding(5)
                    }
                    .accessibilityLabel("Loading album photos")
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
                                            .background(Color.black)
                                        if selectedIDs.contains(photo.id) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.title2).symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, Color.vxAccent).padding(6)
                                        } else if offlineStore.isSaved(album.id, photoID: photo.id) {
                                            Image(systemName: "arrow.down.circle.fill")
                                                .font(.title3).symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .green).padding(6)
                                        }
                                    }.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            loadError = describeError(error, subject: "album photos").message
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
                                        }.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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

