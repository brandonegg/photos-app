import CloudCore
import MediaCache
import Persistence
import SwiftUI

/// Search, the tab bar's search tab: a large title, Recents (past searches,
/// Recently Viewed, Recently Shared) with Clear, and suggestion chips; the system search
/// field (in the tab bar on iOS 26, under the title before). Results come from the metadata on
/// this phone at once (offline too), then from the server's smart search (by what's in the
/// photo) and face recognition, when the server has machine learning.
struct SearchScreen: View {
    let session: LibrarySession
    @Bindable var ui: LibraryUIState
    @State private var text = ""
    @State private var results: [TimelineItem] = []
    /// Matches by meaning from the server, after the local ones.
    @State private var smartResults: [TimelineItem] = []
    @State private var isSmartSearching = false
    @State private var people: [CloudPerson] = []
    @State private var searchedText = ""
    @State private var suggestions: [String] = []
    @State private var recentQueries = SearchHistory.queries
    @State private var viewed = SearchHistory.viewed
    @State private var shared = SearchHistory.shared
    @State private var path = NavigationPath()
    @State private var columns = 3
    @FocusState private var fieldFocused: Bool
    /// The bottom safe area (tab bar, or keyboard), cleared by the results grid.
    @State private var safeBottom: CGFloat = 0
    @State private var keyboardShown = false

    /// On iOS 26 the search field floats just above the keyboard, but isn't part of the safe
    /// area, so content laid out to the keyboard's top would sit under it. This clears it.
    private var fieldClearance: CGFloat {
        if #available(iOS 26.0, *), keyboardShown { 58 } else { 0 }
    }

    private enum Route: Hashable {
        case viewed, shared
        case person(CloudPerson)
    }

    /// Local matches first, then smart matches not already among them.
    private var combinedResults: [TimelineItem] {
        let ids = Set(results.map(\.id))
        return results + smartResults.filter { !ids.contains($0.id) }
    }

    private var matchingPeople: [CloudPerson] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard query.count >= 2 else { return [] }
        return people.filter { !$0.name.isEmpty && $0.name.lowercased().contains(query) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            // A real container, not a Group: a Group applies the modifiers below to each
            // branch, so the first letter (Home → results) would rebuild the field.
            ZStack(alignment: .top) {
                if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    home
                } else {
                    resultsView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background { Color(.systemBackground).ignoresSafeArea() }
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { safeBottom = $0 }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardShown = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardShown = false }
            .navigationTitle("Search")
            .searchable(text: $text, placement: Self.fieldPlacement, prompt: Text("Search your library…"))
            .searchFocused($fieldFocused)
            .autocorrectionDisabled()
            .onSubmit(of: .search) { SearchHistory.recordQuery(text); recentQueries = SearchHistory.queries }
            .navigationDestination(for: Route.self) { route in
                if case .person(let person) = route {
                    PersonScreen(person: person, session: session)
                } else {
                    let ids = route == .viewed ? viewed : shared
                    let byID = Dictionary(session.timeline.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    CollectionGridScreen(
                        title: route == .viewed ? String(localized: "Recently Viewed") : String(localized: "Recently Shared"),
                        items: ids.compactMap { byID[$0] }.reversed(), session: session
                    )
                }
            }
        }
        // Opening the tab starts typing (iOS 26 does it with the tab bar's field itself).
        .onAppear { fieldFocused = true }
        .task {
            let places = await session.topPlaces(limit: 2)
            let year = Calendar.current.component(.year, from: .now)
            suggestions = places.map { String(localized: "\($0)") } + [String(localized: "Videos in \(String(year))"), String(localized: "Favourites")]
            people = orderedPeople((try? await session.people()) ?? [])
        }
        .task(id: text) {
            let query = text
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { results = []; return }
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            results = await SearchEngine.search(query, in: session)
            smartResults = []
            searchedText = query
            // Then by meaning, from the server (needs its machine learning), once typing pauses.
            guard !SearchEngine.parse(query).words.isEmpty, session.connection != nil else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            isSmartSearching = true
            defer { isSmartSearching = false }
            let smart = (try? await session.smartSearch(query)) ?? []
            guard !Task.isCancelled else { return }
            smartResults = smart
        }
    }

    // MARK: Home (Recents and suggestions)

    private var home: some View {
        GeometryReader { geometry in
            ScrollView {
                homeContent
                    .frame(minHeight: geometry.size.height, alignment: .top)
            }
            // With the keyboard up, the suggestions stay just above the field (People and
            // Recents scroll up out of the way).
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
        }
        .safeAreaPadding(.bottom, fieldClearance)
    }

    private var homeContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !people.isEmpty {
                Text("People")
                    .font(.system(size: 22, weight: .bold))
                    .padding(.horizontal, 18)
                    .padding(.top, 22)
                peopleStrip(people.prefix(20).map { $0 })
                    .padding(.top, 10)
            }
            if hasRecents {
                HStack {
                    Text("Recents")
                        .font(.system(size: 22, weight: .bold))
                    Spacer()
                    Button("Clear") {
                        SearchHistory.clear()
                        withAnimation {
                            recentQueries = []
                            viewed = []
                            shared = []
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(Color(.secondarySystemFill), in: Capsule())
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
                .padding(.horizontal, 18)
                .padding(.top, 26)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(recentQueries.prefix(6), id: \.self) { query in
                            Button {
                                text = query
                            } label: {
                                RecentQueryCard(query: query, session: session)
                            }
                            .buttonStyle(.plain)
                        }
                        if let item = item(for: viewed.first) {
                            NavigationLink(value: Route.viewed) {
                                RecentCard(title: String(localized: "Recently Viewed"), item: item, pipeline: session.pipeline)
                            }
                            .buttonStyle(.plain)
                        }
                        if let item = item(for: shared.first) {
                            NavigationLink(value: Route.shared) {
                                RecentCard(title: String(localized: "Recently Shared"), item: item, pipeline: session.pipeline)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                .padding(.top, 12)
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        text = suggestion
                        SearchHistory.recordQuery(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.system(size: 17))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 22)
                            .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                    .glassSurface(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func peopleStrip(_ people: [CloudPerson]) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(people) { person in
                    NavigationLink(value: Route.person(person)) {
                        VStack(spacing: 5) {
                            PersonFaceView(personID: person.id, session: session, size: 64)
                            Text(person.displayName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                                .lineLimit(1)
                                .frame(width: 70)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    private var hasRecents: Bool {
        !recentQueries.isEmpty || item(for: viewed.first) != nil || item(for: shared.first) != nil
    }

    private func item(for id: String?) -> TimelineItem? {
        guard let id else { return nil }
        return session.timeline.items.last { $0.id == id }
    }

    // MARK: Results

    private var resultsView: some View {
        let results = combinedResults
        return VStack(alignment: .leading, spacing: 8) {
            if !matchingPeople.isEmpty {
                peopleStrip(matchingPeople)
                    .padding(.top, 12)
            }
            HStack(spacing: 8) {
                Text(results.isEmpty ? (isSmartSearching ? String(localized: "Searching…") : String(localized: "No Results")) : results.count == 1 ? String(localized: "1 Result") : String(localized: "\(results.count.formatted()) Results"))
                    .font(.system(size: 22, weight: .bold))
                if isSmartSearching { ProgressView() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            if results.isEmpty {
                Text("Try a place, a month or year, “videos”, a person, or what's in the photo (“dog on a beach”).")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                Spacer()
            } else {
                PhotoGridView(
                    snapshot: TimelineSnapshot(items: results, version: searchedText.hashValue &+ smartResults.count, isLoaded: true),
                    session: session, columns: $columns,
                    insets: UIEdgeInsets(top: 0, left: 0, bottom: safeBottom + fieldClearance + 12, right: 0),
                    opensAtTop: true
                )
                .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    /// In the tab bar on iOS 26; before, always under the title.
    private static var fieldPlacement: SearchFieldPlacement {
        if #available(iOS 26.0, *) { .automatic } else { .navigationBarDrawer(displayMode: .always) }
    }
}

/// A past search, shown with its newest result.
private struct RecentQueryCard: View {
    let query: String
    let session: LibrarySession
    @State private var item: TimelineItem?

    var body: some View {
        RecentCard(title: "“\(query)”", item: item, pipeline: session.pipeline)
            .task(id: query) { item = await SearchEngine.search(query, in: session).first }
    }
}

/// A square Recents card: a photo with its title at the bottom left.
private struct RecentCard: View {
    let title: String
    let item: TimelineItem?
    let pipeline: RemoteImagePipeline

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let item {
                PipelineImage(item: item, pipeline: pipeline, pixelSize: 500)
            } else {
                Color(.secondarySystemBackground)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(12)
        }
        .frame(width: 115, height: 115)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
