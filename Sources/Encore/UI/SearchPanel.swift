import SwiftUI

/// Drives the search field + suggestion panel (recent searches when empty,
/// live suggestions and rich results while typing, keyboard navigation).
@MainActor
final class SearchController: ObservableObject {
    static let shared = SearchController()

    @Published var visible = false
    /// The search field's frame in window coordinates, so the dropdown can match it.
    @Published var fieldFrame: CGRect = .zero
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var loading = false
    @Published var highlighted: Int? = nil
    @Published private(set) var recents: [String] = Persist.load("recentSearches", as: [String].self) ?? []

    private var task: Task<Void, Never>?
    private var model: AppModel { .shared }

    enum Entry: Identifiable, Hashable {
        case recent(String), suggestion(String), item(MediaItem)
        var id: String {
            switch self {
            case .recent(let s): return "r:" + s
            case .suggestion(let s): return "s:" + s
            case .item(let i): return "i:" + i.id
            }
        }
    }

    /// Everything currently shown, in order, for keyboard navigation.
    var entries: [Entry] {
        if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty { return recents.map(Entry.recent) }
        return suggestions.prefix(6).map(Entry.suggestion) + items.prefix(5).map(Entry.item)
    }

    func queryChanged(_ q: String) {
        highlighted = nil
        task?.cancel()
        let text = q.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { suggestions = []; items = []; loading = false; return }
        loading = true
        task = Task {
            try? await Task.sleep(nanoseconds: 140_000_000)   // debounce while typing
            guard !Task.isCancelled else { return }
            let result = try? await InnerTube.shared.suggestions(text)
            guard !Task.isCancelled, text == model.searchText.trimmingCharacters(in: .whitespaces) else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                suggestions = result?.0 ?? []
                items = result?.1 ?? []
                loading = false
            }
        }
    }

    func move(_ delta: Int) {
        let n = entries.count
        guard n > 0 else { return }
        if let h = highlighted { highlighted = (h + delta + n) % n } else { highlighted = delta > 0 ? 0 : n - 1 }
    }

    /// Return key: chosen entry if one is highlighted, otherwise search the text.
    func commit() {
        if let h = highlighted, h < entries.count { choose(entries[h]) } else { submit(model.searchText) }
    }

    func choose(_ e: Entry) {
        switch e {
        case .recent(let s), .suggestion(let s): submit(s)
        case .item(let item):
            visible = false
            remember(model.searchText)
            model.open(item)
        }
    }

    func submit(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        model.searchText = q
        model.submittedSearch = q
        model.showNowPlaying = false
        model.selection = .search
        remember(q)
        visible = false
        highlighted = nil
    }

    func remember(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        recents.removeAll { $0.caseInsensitiveCompare(t) == .orderedSame }
        recents.insert(t, at: 0)
        if recents.count > 12 { recents.removeLast(recents.count - 12) }
        Persist.save(recents, "recentSearches")
    }

    func forget(_ q: String) { recents.removeAll { $0 == q }; Persist.save(recents, "recentSearches") }
    func clearRecents() { recents = []; Persist.save(recents, "recentSearches") }
}

struct SearchField: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var search = SearchController.shared
    @FocusState private var focused: Bool
    @State private var appearedAt = Date()

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12.5, weight: .semibold))
            TextField("Songs, artists, lyrics…", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { search.commit() }
                .onKeyPress(.downArrow) { search.visible = true; search.move(1); return .handled }
                .onKeyPress(.upArrow) { search.move(-1); return .handled }
                .onKeyPress(.escape) {
                    if search.visible { search.visible = false } else { model.searchText = ""; focused = false }
                    return .handled
                }
            if search.loading {
                ProgressView().controlSize(.mini)
            } else if !model.searchText.isEmpty {
                Button { model.searchText = ""; focused = true } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 13.5))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { SearchController.shared.fieldFrame = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, f in SearchController.shared.fieldFrame = f }
        })
        .background(Capsule().fill(Color.primary.opacity(focused ? 0.13 : 0.08)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(focused ? 0.22 : 0.07), lineWidth: 0.8))
        .shadow(color: .black.opacity(focused ? 0.25 : 0), radius: 10, y: 4)
        .animation(.easeOut(duration: 0.15), value: focused)
        .onChange(of: model.focusSearch) { if model.focusSearch { focused = true; model.focusSearch = false } }
        // macOS focuses the first text field when the window opens; only a real
        // click/⌘F should open the panel, so ignore focus in the first moments.
        .onAppear { appearedAt = Date(); DispatchQueue.main.async { focused = false } }
        .onChange(of: focused) { if focused && Date().timeIntervalSince(appearedAt) > 1.2 { search.visible = true } }
        .onChange(of: model.searchText) {
            search.queryChanged(model.searchText)
            if focused && model.searchText != model.submittedSearch { search.visible = true }
        }
        .onChange(of: search.visible) { if !search.visible { focused = false } }
    }
}

/// The floating suggestions panel under the search field.
struct SearchPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var search = SearchController.shared

    var body: some View {
        let entries = search.entries
        VStack(alignment: .leading, spacing: 2) {
            if model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack {
                    Text("Recent Searches").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if !search.recents.isEmpty {
                        Button("Clear") { search.clearRecents() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
                if search.recents.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "sparkle.magnifyingglass").font(.system(size: 22)).foregroundStyle(.secondary)
                        Text("Search songs, artists, albums, playlists and podcasts.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(18)
                }
            } else if entries.isEmpty && !search.loading {
                Text("No suggestions").font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
            }
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                if case .item = e, i > 0, case .suggestion = entries[i - 1] {
                    Divider().padding(.vertical, 4).padding(.horizontal, 8)
                }
                SearchEntryRow(entry: e, query: model.searchText, highlighted: search.highlighted == i)
                    .onHover { if $0 { search.highlighted = i } }
            }
        }
        .padding(8)
        // Frosted glass, the same width as the search field above it.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.3), radius: 28, y: 14)
    }
}

struct SearchEntryRow: View {
    let entry: SearchController.Entry
    let query: String
    let highlighted: Bool
    @ObservedObject private var search = SearchController.shared

    var body: some View {
        HStack(spacing: 10) {
            switch entry {
            case .recent(let s):
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary).frame(width: 22)
                Text(s).lineLimit(1)
                Spacer()
                if highlighted {
                    Button { search.forget(s) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
                }
            case .suggestion(let s):
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).frame(width: 22)
                Text(bolded(s)).lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up.left").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            case .item(let item):
                Artwork(url: item.thumbnail, cornerRadius: item.kind == .artist ? 16 : 6, symbol: item.kind == .artist ? "person.fill" : "music.note", size: 32)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(subtitle(item)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if item.kind.isPlayable {
                    Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(highlighted ? .primary : .tertiary)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(highlighted ? Color.accentColor.opacity(0.28) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { search.choose(entry) }
    }

    private func subtitle(_ item: MediaItem) -> String {
        let kind = item.kind == .unknown ? "" : item.kind.rawValue.capitalized
        let rest = item.kind == .artist ? "" : item.artistLine
        return [kind, rest].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Typed part normal, YouTube-style completion in bold.
    private func bolded(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty, s.lowercased().hasPrefix(q), q.count < s.count {
            let start = a.characters.index(a.startIndex, offsetBy: q.count)
            a[start..<a.endIndex].font = .system(size: 13, weight: .bold)
        } else {
            a.font = .system(size: 13, weight: .semibold)
        }
        return a
    }
}
