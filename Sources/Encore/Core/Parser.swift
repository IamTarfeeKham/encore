import Foundation

/// Turns InnerTube renderer JSON into app models. Every function is tolerant:
/// unknown renderers are skipped, missing fields become nil.
enum Parser {

    // MARK: - Shared helpers

    static let typeLabels: [String: ItemKind] = [
        "song": .song, "video": .video, "album": .album, "single": .single, "ep": .ep,
        "playlist": .playlist, "artist": .artist, "episode": .episode, "podcast": .podcast,
        "profile": .artist, "station": .playlist,
    ]

    static func pageType(_ nav: JSON) -> String? {
        nav.browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType.string
    }

    static func videoType(_ nav: JSON) -> String? {
        nav.watchEndpoint.watchEndpointMusicSupportedConfigs.watchEndpointMusicConfig.musicVideoType.string
    }

    static func kind(forPageType p: String?, browseId: String?) -> ItemKind {
        switch p {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK": return .album
        case "MUSIC_PAGE_TYPE_PLAYLIST": return .playlist
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL", "MUSIC_PAGE_TYPE_LIBRARY_ARTIST": return .artist
        case "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE": return .podcast
        case "MUSIC_PAGE_TYPE_NON_MUSIC_AUDIO_TRACK_PAGE": return .episode
        default: break
        }
        guard let b = browseId else { return .unknown }
        if b.hasPrefix("MPREb") { return .album }
        if b.hasPrefix("VL") || b.hasPrefix("PL") || b.hasPrefix("RD") || b.hasPrefix("OLAK") { return .playlist }
        if b.hasPrefix("UC") || b.hasPrefix("MPLA") { return .artist }
        if b.hasPrefix("MPSP") { return .podcast }
        if b.hasPrefix("FEmusic_moods") { return .mood }
        return .unknown
    }

    static func kind(forVideoType t: String?) -> ItemKind {
        switch t {
        case "MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_UGC", "MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC": return .video
        case "MUSIC_VIDEO_TYPE_PODCAST_EPISODE": return .episode
        default: return .song
        }
    }

    struct RunInfo {
        var artists: [ArtistRef] = []
        var album: AlbumRef?
        var typeLabel: ItemKind?
        var duration: TimeInterval?
        var plainSegments: [String] = []
    }

    /// Interprets subtitle runs like "Song • Artist, Artist • Album • 3:21".
    static func runInfo(_ runs: [JSON]) -> RunInfo {
        var info = RunInfo()
        var segment = ""
        func flush() {
            let s = segment.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { info.plainSegments.append(s) }
            segment = ""
        }
        for (i, run) in runs.enumerated() {
            let text = run["text"].string ?? ""
            let nav = run.navigationEndpoint
            if let bid = nav.browseEndpoint.browseId.string {
                let k = kind(forPageType: pageType(nav), browseId: bid)
                if k == .artist { info.artists.append(ArtistRef(name: text, browseId: bid)); continue }
                if k == .album { info.album = AlbumRef(name: text, browseId: bid); continue }
            }
            if text.trimmingCharacters(in: .whitespaces) == "•" { flush(); continue }
            if i == 0, let k = typeLabels[text.lowercased()] { info.typeLabel = k; continue }
            if info.duration == nil, text.range(of: #"^\d{1,2}(:\d{2}){1,2}$"#, options: .regularExpression) != nil {
                info.duration = parseDuration(text); continue
            }
            segment += text
        }
        flush()
        return info
    }

    static func isExplicit(_ r: JSON) -> Bool {
        r.badges.array.contains { $0.musicInlineBadgeRenderer.icon.iconType.string == "MUSIC_EXPLICIT_BADGE" }
            || r.subtitleBadges.array.contains { $0.musicInlineBadgeRenderer.icon.iconType.string == "MUSIC_EXPLICIT_BADGE" }
    }

    static func menuPlaylist(_ r: JSON, icon: String) -> String? {
        for item in r.menu.menuRenderer.items.array {
            let m = item.menuNavigationItemRenderer
            if m.icon.iconType.string == icon {
                return m.navigationEndpoint.watchEndpoint.playlistId.string
                    ?? m.navigationEndpoint.watchPlaylistEndpoint.playlistId.string
            }
        }
        return nil
    }

    static func looksLikeMetadata(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("views") || l.contains("plays") || l.contains("subscribers") || l.contains("monthly")
            || l.contains("songs") || l.contains("tracks") || l.range(of: #"^\d{4}$"#, options: .regularExpression) != nil
    }

    // MARK: - Item renderers

    static func item(_ wrapper: JSON) -> MediaItem? {
        if wrapper.musicTwoRowItemRenderer.exists { return twoRow(wrapper.musicTwoRowItemRenderer) }
        if wrapper.musicResponsiveListItemRenderer.exists { return listItem(wrapper.musicResponsiveListItemRenderer) }
        if wrapper.musicNavigationButtonRenderer.exists { return navButton(wrapper.musicNavigationButtonRenderer) }
        if wrapper.musicMultiRowListItemRenderer.exists { return multiRow(wrapper.musicMultiRowListItemRenderer) }
        return nil
    }

    static func twoRow(_ r: JSON) -> MediaItem? {
        guard let title = r.title.text else { return nil }
        let nav = r.navigationEndpoint
        let subtitleRuns = r.subtitle.runs.array
        let info = runInfo(subtitleRuns)
        let subtitle = r.subtitle.text ?? ""
        let thumb = Thumbs.best(r.thumbnailRenderer)
        let playEP = r.thumbnailOverlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint

        if let vid = nav.watchEndpoint.videoId.string {
            var k = kind(forVideoType: videoType(nav))
            if r.aspectRatio.string?.contains("16_9") == true, k == .song { k = .video }
            var artists = info.artists
            if artists.isEmpty, let first = info.plainSegments.first, !looksLikeMetadata(first) {
                artists = [ArtistRef(name: first, browseId: nil)]
            }
            return MediaItem(id: vid, kind: k, title: title, subtitle: subtitle, thumbnail: thumb,
                             videoId: vid, playlistId: nav.watchEndpoint.playlistId.string,
                             artists: artists, album: info.album, duration: info.duration,
                             isExplicit: isExplicit(r), radioPlaylistId: menuPlaylist(r, icon: "MIX"))
        }
        if let bid = nav.browseEndpoint.browseId.string {
            var k = kind(forPageType: pageType(nav), browseId: bid)
            if k == .album, let t = info.typeLabel, t == .single || t == .ep { k = t }
            let pid = playEP.watchPlaylistEndpoint.playlistId.string
                ?? playEP.watchEndpoint.playlistId.string
                ?? (bid.hasPrefix("VL") ? String(bid.dropFirst(2)) : nil)
            return MediaItem(id: bid, kind: k, title: title, subtitle: subtitle, thumbnail: thumb,
                             playlistId: pid, browseId: bid, params: nav.browseEndpoint.params.string,
                             artists: info.artists, isExplicit: isExplicit(r),
                             radioPlaylistId: menuPlaylist(r, icon: "MIX"),
                             shufflePlaylistId: menuPlaylist(r, icon: "MUSIC_SHUFFLE"))
        }
        if let pid = nav.watchPlaylistEndpoint.playlistId.string {
            return MediaItem(id: pid, kind: .playlist, title: title, subtitle: subtitle, thumbnail: thumb,
                             playlistId: pid, browseId: "VL" + pid)
        }
        return nil
    }

    static func listItem(_ r: JSON) -> MediaItem? {
        let cols = r.flexColumns.array.map { $0.musicResponsiveListItemFlexColumnRenderer["text"] }
        guard let title = cols.first?.text, !title.isEmpty else { return nil }
        let titleNav = cols.first?.runs[0].navigationEndpoint ?? .null
        let overlayEP = r.overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer.playNavigationEndpoint
        var subRuns: [JSON] = []
        for (i, c) in cols.dropFirst().enumerated() {
            let runs = c.runs.array
            if runs.isEmpty { continue }
            if i > 0 && !subRuns.isEmpty { subRuns.append(.object(["text": .string(" • ")])) }
            subRuns.append(contentsOf: runs)
        }
        var info = runInfo(subRuns)
        let fixed = r.fixedColumns[0].musicResponsiveListItemFixedColumnRenderer["text"].text
        if info.duration == nil { info.duration = parseDuration(fixed) }
        let subtitle = subRuns.compactMap { $0["text"].string }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: " •"))
        let thumb = Thumbs.best(r.thumbnail)

        let videoId = r.playlistItemData.videoId.string
            ?? overlayEP.watchEndpoint.videoId.string
            ?? titleNav.watchEndpoint.videoId.string
            ?? r.navigationEndpoint.watchEndpoint.videoId.string

        if let vid = videoId {
            let vt = videoType(overlayEP).flatMap { $0 } ?? videoType(titleNav) ?? videoType(r.navigationEndpoint)
            var k = kind(forVideoType: vt)
            if vt == nil, let t = info.typeLabel, t == .video || t == .episode { k = t }
            var artists = info.artists
            if artists.isEmpty, let first = info.plainSegments.first, !looksLikeMetadata(first) {
                artists = first.components(separatedBy: CharacterSet(charactersIn: ",&"))
                    .map { ArtistRef(name: $0.trimmingCharacters(in: .whitespaces), browseId: nil) }
                    .filter { !$0.name.isEmpty }
            }
            return MediaItem(id: vid + (r.playlistItemData.playlistSetVideoId.string ?? ""),
                             kind: k, title: title, subtitle: subtitle, thumbnail: thumb,
                             videoId: vid, playlistId: overlayEP.watchEndpoint.playlistId.string,
                             artists: artists, album: info.album, duration: info.duration,
                             isExplicit: isExplicit(r), radioPlaylistId: menuPlaylist(r, icon: "MIX"),
                             setVideoId: r.playlistItemData.playlistSetVideoId.string)
        }

        let nav = r.navigationEndpoint.exists ? r.navigationEndpoint : titleNav
        guard let bid = nav.browseEndpoint.browseId.string else { return nil }
        var k = kind(forPageType: pageType(nav), browseId: bid)
        if k == .album, let t = info.typeLabel, t == .single || t == .ep { k = t }
        if k == .unknown, let t = info.typeLabel { k = t }
        let pid = overlayEP.watchPlaylistEndpoint.playlistId.string
            ?? (bid.hasPrefix("VL") ? String(bid.dropFirst(2)) : nil)
        return MediaItem(id: bid, kind: k, title: title, subtitle: subtitle, thumbnail: thumb,
                         playlistId: pid, browseId: bid, params: nav.browseEndpoint.params.string,
                         artists: info.artists, isExplicit: isExplicit(r),
                         radioPlaylistId: menuPlaylist(r, icon: "MIX"),
                         shufflePlaylistId: menuPlaylist(r, icon: "MUSIC_SHUFFLE"))
    }

    static func multiRow(_ r: JSON) -> MediaItem? {
        guard let title = r.title.text else { return nil }
        let nav = r.onTap
        let vid = nav.watchEndpoint.videoId.string
        let bid = r.title.runs[0].navigationEndpoint.browseEndpoint.browseId.string
        return MediaItem(id: vid ?? bid ?? title, kind: .episode, title: title, subtitle: r.subtitle.text ?? "",
                         thumbnail: Thumbs.best(r.thumbnail), videoId: vid, browseId: bid,
                         duration: nil)
    }

    static func navButton(_ r: JSON) -> MediaItem? {
        guard let title = r.buttonText.text else { return nil }
        let ep = r.clickCommand.browseEndpoint
        guard let bid = ep.browseId.string else { return nil }
        let color = r.solid.leftStripeColor.double.map { UInt32(truncatingIfNeeded: Int64($0)) }
        return MediaItem(id: bid + (ep.params.string ?? title), kind: .mood, title: title,
                         browseId: bid, params: ep.params.string, tileColor: color)
    }

    // MARK: - Shelves

    static func shelf(_ s: JSON) -> Shelf? {
        if s.musicCarouselShelfRenderer.exists || s.musicImmersiveCarouselShelfRenderer.exists {
            let r = s.musicCarouselShelfRenderer.exists ? s.musicCarouselShelfRenderer : s.musicImmersiveCarouselShelfRenderer
            let h = r.header.musicCarouselShelfBasicHeaderRenderer.exists
                ? r.header.musicCarouselShelfBasicHeaderRenderer : r.header.musicImmersiveCarouselShelfBasicHeaderRenderer
            let items = r.contents.array.compactMap(item)
            guard !items.isEmpty else { return nil }
            let isList = r.contents[0].musicResponsiveListItemRenderer.exists
            let isMood = r.contents[0].musicNavigationButtonRenderer.exists
            let more = h.moreContentButton.buttonRenderer.navigationEndpoint.browseEndpoint
            return Shelf(title: h.title.text ?? "", strapline: h.strapline.text,
                         thumbnail: Thumbs.best(h.thumbnail),
                         style: isMood ? .moods : (isList ? .quickPicks : .cards), items: items,
                         moreBrowseId: more.browseId.string ?? h.title.runs[0].navigationEndpoint.browseEndpoint.browseId.string,
                         moreParams: more.params.string ?? h.title.runs[0].navigationEndpoint.browseEndpoint.params.string)
        }
        if s.musicShelfRenderer.exists {
            let r = s.musicShelfRenderer
            let items = r.contents.array.compactMap(item)
            guard !items.isEmpty else { return nil }
            let more = r.bottomEndpoint.browseEndpoint.exists ? r.bottomEndpoint.browseEndpoint
                : r.title.runs[0].navigationEndpoint.browseEndpoint
            return Shelf(title: r.title.text ?? "", style: .list, items: items,
                         moreBrowseId: more.browseId.string, moreParams: more.params.string)
        }
        if s.musicPlaylistShelfRenderer.exists {
            let items = s.musicPlaylistShelfRenderer.contents.array.compactMap(item)
            return items.isEmpty ? nil : Shelf(title: "", style: .list, items: items)
        }
        if s.gridRenderer.exists {
            let r = s.gridRenderer
            let items = r.items.array.compactMap(item)
            guard !items.isEmpty else { return nil }
            let isMood = r.items[0].musicNavigationButtonRenderer.exists
            return Shelf(title: r.header.gridHeaderRenderer.title.text ?? "", style: isMood ? .moods : .cards, items: items)
        }
        if s.itemSectionRenderer.exists {
            // Wrapper: either around a shelf, or (newer responses) directly around items.
            let children = s.itemSectionRenderer.contents.array
            for c in children { if let sh = shelf(c) { return sh } }
            let items = children.compactMap(item)
            if !items.isEmpty {
                let isList = children.first?.musicResponsiveListItemRenderer.exists == true
                return Shelf(title: s.itemSectionRenderer.header.itemSectionHeaderRenderer.title.text ?? "",
                             style: isList ? .list : .cards, items: items)
            }
        }
        if s.musicCardShelfRenderer.exists {
            if let top = cardShelfItem(s.musicCardShelfRenderer) {
                var items = [top]
                items += s.musicCardShelfRenderer.contents.array.compactMap(item)
                return Shelf(title: s.musicCardShelfRenderer.header.musicCardShelfHeaderBasicRenderer.title.text ?? "Top result",
                             style: .list, items: items)
            }
        }
        return nil
    }

    static func cardShelfItem(_ r: JSON) -> MediaItem? {
        guard let title = r.title.text else { return nil }
        let nav = r.title.runs[0].navigationEndpoint.exists ? r.title.runs[0].navigationEndpoint : r.onTap
        let info = runInfo(r.subtitle.runs.array)
        let thumb = Thumbs.best(r.thumbnail)
        if let vid = nav.watchEndpoint.videoId.string {
            return MediaItem(id: vid, kind: info.typeLabel ?? kind(forVideoType: videoType(nav)), title: title,
                             subtitle: r.subtitle.text ?? "", thumbnail: thumb, videoId: vid,
                             artists: info.artists, album: info.album, duration: info.duration, isExplicit: isExplicit(r))
        }
        if let bid = nav.browseEndpoint.browseId.string {
            var k = kind(forPageType: pageType(nav), browseId: bid)
            if k == .album, let t = info.typeLabel, t == .single || t == .ep { k = t }
            return MediaItem(id: bid, kind: k, title: title, subtitle: r.subtitle.text ?? "", thumbnail: thumb,
                             playlistId: bid.hasPrefix("VL") ? String(bid.dropFirst(2)) : nil,
                             browseId: bid, artists: info.artists)
        }
        return nil
    }

    static func sectionContents(_ j: JSON) -> [JSON] {
        // Normal response
        let tabs = j.contents.singleColumnBrowseResultsRenderer.tabs.array
        if let selected = tabs.first(where: { $0.tabRenderer.selected.bool == true }) ?? tabs.first {
            let c = selected.tabRenderer.content.sectionListRenderer.contents.array
            if !c.isEmpty { return c }
        }
        let two = j.contents.twoColumnBrowseResultsRenderer
        if two.exists {
            return two.tabs[0].tabRenderer.content.sectionListRenderer.contents.array
                + two.secondaryContents.sectionListRenderer.contents.array
        }
        // Continuation responses
        let cont = j.continuationContents.sectionListContinuation.contents.array
        if !cont.isEmpty { return cont }
        let actions = j.onResponseReceivedActions.array.flatMap { $0.appendContinuationItemsAction.continuationItems.array }
        if !actions.isEmpty { return actions }
        return j.find("sectionListRenderer").contents.array
    }

    static func continuationToken(_ j: JSON) -> String? {
        if let t = j.find("nextContinuationData").continuation.string { return t }
        if let t = j.find("continuationCommand").token.string { return t }
        if let t = j.find("nextRadioContinuationData").continuation.string { return t }
        return nil
    }

    static func browsePage(_ j: JSON) -> BrowsePage {
        let shelves = sectionContents(j).compactMap(shelf)
        let title = j.header.musicHeaderRenderer.title.text
            ?? j.header.musicVisualHeaderRenderer.title.text
            ?? j.header.musicImmersiveHeaderRenderer.title.text ?? ""
        var chips: [Chip] = []
        for c in j.find("chipCloudRenderer").chips.array {
            let r = c.chipCloudChipRenderer
            guard let t = r["text"].text else { continue }
            let ep = r.navigationEndpoint.browseEndpoint
            chips.append(Chip(title: t, params: ep.params.string, browseId: ep.browseId.string,
                              isSelected: r.isSelected.bool ?? false))
        }
        // Only follow section-list continuations (not nested shelf ones) for pages.
        let token = j.find("sectionListRenderer").continuations[0].nextContinuationData.continuation.string
            ?? j.continuationContents.sectionListContinuation.continuations[0].nextContinuationData.continuation.string
        return BrowsePage(title: title, shelves: shelves, continuation: token, chips: chips)
    }

    // MARK: - Collections (album / playlist)

    static func collection(_ j: JSON, browseId: String) -> CollectionPage {
        var header = j.find("musicResponsiveHeaderRenderer")
        if !header.exists { header = j.find("musicDetailHeaderRenderer") }
        if !header.exists { header = j.find("musicImmersiveHeaderRenderer") }
        let editable = j.find("musicEditablePlaylistDetailHeaderRenderer").exists

        let title = header.title.text ?? ""
        let subtitle = header.subtitle.text ?? ""
        let second = header.secondSubtitle.text ?? ""
        var artists = runInfo(header.straplineTextOne.runs.array).artists
        if artists.isEmpty { artists = runInfo(header.subtitle.runs.array).artists }
        // Own playlists: the owner comes as plain text with no link.
        if artists.isEmpty, let owner = header.straplineTextOne.text ?? header.facepile.avatarStackViewModel["text"].content.string,
           !owner.isEmpty {
            artists = [ArtistRef(name: owner, browseId: nil)]
        }
        let desc = header.description.musicDescriptionShelfRenderer.description.text ?? header.description.text
        let thumb = Thumbs.best(header.thumbnail)

        // Tracks: the shelf inside secondaryContents (new layout) or the main content.
        var trackShelf = j.contents.twoColumnBrowseResultsRenderer.secondaryContents.sectionListRenderer.contents[0]
        if !trackShelf.exists { trackShelf = sectionContents(j).first(where: { $0.musicShelfRenderer.exists || $0.musicPlaylistShelfRenderer.exists }) ?? .null }
        let shelfR = trackShelf.musicShelfRenderer.exists ? trackShelf.musicShelfRenderer : trackShelf.musicPlaylistShelfRenderer
        var tracks = shelfR.contents.array.compactMap(item).filter { $0.videoId != nil }
        let token = shelfR.continuations[0].nextContinuationData.continuation.string
            ?? shelfR.contents.array.last?.continuationItemRenderer.continuationEndpoint.continuationCommand.token.string

        let isAlbum = browseId.hasPrefix("MPRE")
        let albumRef = isAlbum ? AlbumRef(name: title, browseId: browseId) : nil
        for i in tracks.indices {
            if tracks[i].thumbnail == nil { tracks[i].thumbnail = thumb }
            if tracks[i].artists.isEmpty { tracks[i].artists = artists }
            if tracks[i].album == nil, let a = albumRef { tracks[i].album = a }
        }

        let playlistId = j.find("watchPlaylistEndpoint").playlistId.string
            ?? tracks.first?.playlistId
            ?? (browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : nil)

        var radio: String?
        var shuffle: String?
        for b in header.buttons.array {
            if let m = b.menuRenderer.exists ? b.menuRenderer : nil {
                for it in m.items.array {
                    let r = it.menuNavigationItemRenderer
                    if r.icon.iconType.string == "MIX" { radio = r.navigationEndpoint.watchPlaylistEndpoint.playlistId.string ?? r.navigationEndpoint.watchEndpoint.playlistId.string }
                    if r.icon.iconType.string == "MUSIC_SHUFFLE" { shuffle = r.navigationEndpoint.watchPlaylistEndpoint.playlistId.string }
                }
            }
        }
        let others = sectionContents(j).filter { !$0.musicShelfRenderer.exists && !$0.musicPlaylistShelfRenderer.exists && !$0.musicResponsiveHeaderRenderer.exists }
            .compactMap(shelf)
        let saved = header.find("toggleButtonRenderer").isToggled.bool
        return CollectionPage(title: title, subtitle: subtitle, secondSubtitle: second, description: desc,
                              thumbnail: thumb, tracks: tracks, playlistId: playlistId, radioPlaylistId: radio,
                              shufflePlaylistId: shuffle, isAlbum: isAlbum, artists: artists, continuation: token,
                              otherShelves: others, isEditable: editable, isSaved: saved)
    }

    static func listContinuation(_ j: JSON) -> ([MediaItem], String?) {
        var items: [MediaItem] = []
        for r in j.findAll("musicResponsiveListItemRenderer") { if let i = listItem(r) { items.append(i) } }
        if items.isEmpty { for r in j.findAll("musicTwoRowItemRenderer") { if let i = twoRow(r) { items.append(i) } } }
        return (items, continuationToken(j))
    }

    // MARK: - Artist

    static func artist(_ j: JSON) -> ArtistPage {
        var h = j.header.musicImmersiveHeaderRenderer
        if !h.exists { h = j.header.musicVisualHeaderRenderer }
        if !h.exists { h = j.find("musicResponsiveHeaderRenderer") }
        let sub = h.subscriptionButton.subscribeButtonRenderer
        let shelves = sectionContents(j).compactMap(shelf)
        let thumb = Thumbs.best(h.thumbnail.exists ? h.thumbnail : h.foregroundThumbnail)
        return ArtistPage(name: h.title.text ?? "",
                          description: h.description.text,
                          thumbnail: thumb,
                          subscribers: sub.subscriberCountText.text ?? sub.longSubscriberCountText.text,
                          channelId: sub.channelId.string,
                          isSubscribed: sub.subscribed.bool ?? false,
                          shufflePlaylistId: h.playButton.buttonRenderer.navigationEndpoint.watchEndpoint.playlistId.string,
                          radioPlaylistId: h.startRadioButton.buttonRenderer.navigationEndpoint.watchEndpoint.playlistId.string,
                          shelves: shelves)
    }

    // MARK: - Search

    static func search(_ j: JSON) -> SearchResults {
        let contents = j.contents.tabbedSearchResultsRenderer.tabs[0].tabRenderer.content.sectionListRenderer.contents.array
        var top: MediaItem?
        var shelves: [Shelf] = []
        var loose: [MediaItem] = []
        for c in contents {
            if c.musicCardShelfRenderer.exists {
                top = cardShelfItem(c.musicCardShelfRenderer)
                let extra = c.musicCardShelfRenderer.contents.array.compactMap(item)
                if !extra.isEmpty { shelves.append(Shelf(title: "", style: .list, items: extra)) }
            } else if let s = shelf(c) {
                // Untitled single-item sections are individual results: pool them.
                if s.title.isEmpty { loose += s.items } else { shelves.append(s) }
            }
        }
        if !loose.isEmpty {
            // Group pooled results by type, in YouTube Music's usual order.
            let groups: [(String, (ItemKind) -> Bool)] = [
                ("Songs", { $0 == .song }), ("Videos", { $0 == .video }),
                ("Albums", { $0 == .album || $0 == .single || $0 == .ep }), ("Artists", { $0 == .artist }),
                ("Playlists", { $0 == .playlist }), ("Episodes & Podcasts", { $0 == .episode || $0 == .podcast }),
            ]
            var used = Set<String>()
            for (title, match) in groups {
                let items = loose.filter { match($0.kind) && !used.contains($0.id) }
                items.forEach { used.insert($0.id) }
                guard !items.isEmpty else { continue }
                let isCollection = items.first.map { $0.kind.isCollection || $0.kind == .artist } ?? false
                shelves.append(Shelf(title: title, style: isCollection ? .cards : .list, items: items))
            }
            let rest = loose.filter { !used.contains($0.id) }
            if !rest.isEmpty { shelves.append(Shelf(title: "More", style: .list, items: rest)) }
        }
        if contents.isEmpty {
            let (items, token) = listContinuation(j)
            return SearchResults(top: nil, shelves: [], items: items, continuation: token)
        }
        let items = top == nil ? shelves.flatMap(\.items) : []
        return SearchResults(top: top, shelves: shelves, items: items,
                             continuation: contents.last?.musicShelfRenderer.continuations[0].nextContinuationData.continuation.string
                                ?? j.find("continuationCommand").token.string)
    }

    static func suggestions(_ j: JSON) -> ([String], [MediaItem]) {
        var texts: [String] = []
        var items: [MediaItem] = []
        for section in j.contents.array {
            for c in section.searchSuggestionsSectionRenderer.contents.array {
                if let t = c.searchSuggestionRenderer.suggestion.text { texts.append(t) }
                if c.musicResponsiveListItemRenderer.exists, let i = listItem(c.musicResponsiveListItemRenderer) { items.append(i) }
            }
        }
        return (texts, items)
    }

    // MARK: - Watch queue

    static func panelTrack(_ r: JSON) -> Track? {
        guard let vid = r.videoId.string else { return nil }
        let info = runInfo(r.longBylineText.runs.exists ? r.longBylineText.runs.array : r.shortBylineText.runs.array)
        var artists = info.artists
        if artists.isEmpty, let s = r.shortBylineText.text { artists = [ArtistRef(name: s, browseId: nil)] }
        let vt = videoType(r.navigationEndpoint)
        return Track(videoId: vid, title: r.title.text ?? "", artists: artists, album: info.album,
                     thumbnail: Thumbs.best(r.thumbnail), duration: parseDuration(r.lengthText.text),
                     isExplicit: isExplicit(r), isVideo: kind(forVideoType: vt) == .video,
                     setVideoId: r.playlistSetVideoId.string)
    }

    static func watchQueue(_ j: JSON, playlistId: String?) -> WatchQueue {
        let tabs = j.contents.singleColumnMusicWatchNextResultsRenderer.tabbedRenderer.watchNextTabbedResultsRenderer.tabs.array
        var panel = tabs.first?.tabRenderer.content.musicQueueRenderer.content.playlistPanelRenderer ?? .null
        if !panel.exists { panel = j.continuationContents.playlistPanelContinuation }
        var tracks: [Track] = []
        for c in panel.contents.array {
            if c.playlistPanelVideoRenderer.exists, let t = panelTrack(c.playlistPanelVideoRenderer) {
                tracks.append(t)
            } else if c.playlistPanelVideoWrapperRenderer.exists {
                let w = c.playlistPanelVideoWrapperRenderer
                if var t = panelTrack(w.primaryRenderer.playlistPanelVideoRenderer) {
                    t.counterpartVideoId = w.counterpart[0].counterpartRenderer.playlistPanelVideoRenderer.videoId.string
                    tracks.append(t)
                }
            }
        }
        var lyrics: String?
        var related: String?
        for t in tabs {
            let b = t.tabRenderer.endpoint.browseEndpoint
            let pt = pageType(t.tabRenderer.endpoint)
            if pt == "MUSIC_PAGE_TYPE_TRACK_LYRICS" || b.browseId.string?.hasPrefix("MPLY") == true { lyrics = b.browseId.string }
            if pt == "MUSIC_PAGE_TYPE_TRACK_RELATED" || b.browseId.string?.hasPrefix("MPTR") == true { related = b.browseId.string }
        }
        let token = panel.continuations[0].nextRadioContinuationData.continuation.string
            ?? panel.continuations[0].nextContinuationData.continuation.string
        return WatchQueue(tracks: tracks, lyricsBrowseId: lyrics, relatedBrowseId: related,
                          continuation: token, playlistId: panel.playlistId.string ?? playlistId)
    }
}
