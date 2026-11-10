import Foundation

/// Builds every CarPlay list page from model data.
///
/// All pages share three rules: rows never exceed the head unit's limits
/// (action rows and earlier sections are kept, the tail is cut), long
/// alphabetical lists get a letter index, and track rows carry their
/// `trackID` so the shell can mark the playing one.
public struct CarPlayListBuilder: Sendable {
    public var limits: CarPlayLimits
    public var strings: CarPlayStrings
    /// Alphabetical lists shorter than this stay unsectioned — an index bar
    /// for twenty rows is just clutter on a car display.
    public var indexThreshold: Int

    public init(limits: CarPlayLimits = .conservative, strings: CarPlayStrings = CarPlayStrings(), indexThreshold: Int = 40) {
        self.limits = limits
        self.strings = strings
        self.indexThreshold = indexThreshold
    }

    /// How a track row describes itself.
    public enum TrackStyle: Sendable {
        /// Inside one album: the artist is known, show the running time.
        case album
        /// Mixed sources (playlist, liked songs, genre): show artist and album.
        case mixed
    }

    // MARK: - Tab roots

    public func home(mixes: [MixDescriptor], recentAlbums: [Album], recentTracks: [Track], includeQuickPlay: Bool = true) -> CarPlayListModel {
        var sections: [CarPlaySection] = []
        if includeQuickPlay {
            sections.append(CarPlaySection(header: strings.quickPlay, items: [
                CarPlayItem(
                    id: "action.shuffleLiked",
                    title: strings.shuffleLikedSongs,
                    symbolName: "heart.fill",
                    action: .shuffleLikedSongs
                ),
            ]))
        }
        if !mixes.isEmpty {
            sections.append(CarPlaySection(header: strings.mixesForYou, items: mixes.map { mix in
                CarPlayItem(
                    id: "mix.\(mix.id)",
                    title: mix.title,
                    subtitle: mix.description ?? strings.songCount(mix.itemIDs.count),
                    symbolName: "waveform",
                    action: .playMix(id: mix.id)
                )
            }))
        }
        if !recentAlbums.isEmpty {
            sections.append(CarPlaySection(header: strings.recentlyAdded, items: recentAlbums.map(albumItem)))
        }
        if !recentTracks.isEmpty {
            let items = recentTracks.enumerated().map { index, track in
                trackItem(track, index: index, style: .mixed, idPrefix: "recent")
            }
            sections.append(CarPlaySection(header: strings.recentlyPlayed, items: items))
        }
        // The quick-play row alone is not content; without anything else the
        // tab shows the hint instead of a lonely button.
        let hasContent = !mixes.isEmpty || !recentAlbums.isEmpty || !recentTracks.isEmpty
        return finish(
            title: strings.home,
            sections: hasContent ? sections : [],
            emptyTitle: strings.nothingHere,
            emptySubtitle: strings.homeEmptyHint
        )
    }

    public func libraryRoot() -> CarPlayListModel {
        let rows: [(String, String, CarPlayDestination)] = [
            (strings.artists, "music.mic", .artists),
            (strings.albums, "square.stack", .albums),
            (strings.playlists, "music.note.list", .playlists),
            (strings.likedSongs, "heart.fill", .likedSongs),
            (strings.genres, "guitars", .genres),
        ]
        let items = rows.map { title, symbol, destination in
            CarPlayItem(
                id: "library.\(title)",
                title: title,
                symbolName: symbol,
                action: .browse(destination),
                showsDisclosure: true
            )
        }
        return finish(title: strings.library, sections: [CarPlaySection(items: items)], emptyTitle: strings.nothingHere)
    }

    /// Downloads tab: offline tracks grouped by album. Built purely from the
    /// local download index, so it is the tab that still works in a tunnel.
    public func downloads(tracks: [Track]) -> CarPlayListModel {
        guard !tracks.isEmpty else {
            return finish(
                title: strings.downloads,
                sections: [],
                emptyTitle: strings.noDownloads,
                emptySubtitle: strings.noDownloadsHint
            )
        }
        var order: [String] = []
        var groups: [String: [Track]] = [:]
        for track in tracks {
            let key = Self.downloadGroupKey(for: track)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(track)
        }
        let albumItems: [CarPlayItem] = order.compactMap { key in
            guard let group = groups[key], let first = group.first else { return nil }
            let title = first.albumName ?? strings.unknownAlbum
            return CarPlayItem(
                id: "download.\(key)",
                title: title,
                subtitle: "\(first.artistName) · \(strings.songCount(group.count))",
                artwork: CarPlayArtworkRef(itemID: first.albumID ?? first.id, imageTag: first.imageTag),
                symbolName: "arrow.down.circle.fill",
                action: .browse(.downloadedAlbum(key: key, title: title)),
                showsDisclosure: true
            )
        }
        .sorted { VoiceTextNormalizer.normalize($0.title) < VoiceTextNormalizer.normalize($1.title) }

        let actions = CarPlaySection(items: [
            CarPlayItem(id: "action.shuffleAll", title: strings.shuffleAll, symbolName: "shuffle", action: .shuffleAll),
        ])
        return finish(
            title: strings.downloads,
            sections: [actions, CarPlaySection(header: strings.albums, items: albumItems)],
            emptyTitle: strings.noDownloads,
            emptySubtitle: strings.noDownloadsHint
        )
    }

    /// Stable grouping key for a downloaded track's album.
    public static func downloadGroupKey(for track: Track) -> String {
        if let albumID = track.albumID { return "id:\(albumID)" }
        if let albumName = track.albumName { return "name:\(albumName)" }
        return "none"
    }

    /// The downloaded tracks of one album group in disc/track order.
    public static func downloadedTracks(in tracks: [Track], groupKey: String) -> [Track] {
        tracks
            .filter { downloadGroupKey(for: $0) == groupKey }
            .sorted { lhs, rhs in
                let left = (lhs.discNumber ?? 1, lhs.indexNumber ?? Int.max, lhs.title)
                let right = (rhs.discNumber ?? 1, rhs.indexNumber ?? Int.max, rhs.title)
                return left < right
            }
    }

    // MARK: - Library pages

    public func artists(_ artists: [Artist]) -> CarPlayListModel {
        let items = artists.map { artist in
            CarPlayItem(
                id: "artist.\(artist.id)",
                title: artist.name,
                artwork: CarPlayArtworkRef(itemID: artist.id, imageTag: artist.imageTag),
                symbolName: "music.mic",
                action: .browse(.artist(id: artist.id, name: artist.name)),
                showsDisclosure: true
            )
        }
        return alphabetical(title: strings.artists, items: items)
    }

    public func albums(_ albums: [Album], title: String? = nil) -> CarPlayListModel {
        alphabetical(title: title ?? strings.albums, items: albums.map(albumItem))
    }

    /// An artist page: play actions, then the albums newest first.
    public func artistDetail(name: String, albums: [Album]) -> CarPlayListModel {
        let actions = CarPlaySection(items: [
            CarPlayItem(id: "action.shuffleAll", title: strings.shuffleAll, symbolName: "shuffle", action: .shuffleAll),
            CarPlayItem(id: "action.radio", title: strings.startRadio, symbolName: "dot.radiowaves.left.and.right", action: .startRadio),
        ])
        let sorted = albums.sorted { lhs, rhs in
            let left = lhs.productionYear ?? Int.min
            let right = rhs.productionYear ?? Int.min
            if left != right { return left > right }
            return VoiceTextNormalizer.normalize(lhs.title) < VoiceTextNormalizer.normalize(rhs.title)
        }
        let albumItems = sorted.map { album in
            var item = albumItem(album)
            // On the artist's own page the artist name is redundant.
            item.subtitle = album.productionYear.map(String.init)
            return item
        }
        return finish(
            title: name,
            sections: [actions, CarPlaySection(header: strings.albums, items: albumItems)],
            emptyTitle: strings.nothingHere
        )
    }

    public func playlists(_ playlists: [Playlist]) -> CarPlayListModel {
        let items = playlists
            .sorted { VoiceTextNormalizer.normalize($0.name) < VoiceTextNormalizer.normalize($1.name) }
            .map { playlist in
                CarPlayItem(
                    id: "playlist.\(playlist.id)",
                    title: playlist.name,
                    subtitle: playlist.trackCount.map(strings.songCount),
                    artwork: CarPlayArtworkRef(itemID: playlist.id, imageTag: playlist.imageTag),
                    symbolName: "music.note.list",
                    action: .browse(.playlist(id: playlist.id, name: playlist.name)),
                    showsDisclosure: true
                )
            }
        return finish(title: strings.playlists, sections: [CarPlaySection(items: items)], emptyTitle: strings.nothingHere)
    }

    public func genres(_ genres: [Genre]) -> CarPlayListModel {
        let items = genres
            .filter { !$0.name.isEmpty }
            .map { genre in
                CarPlayItem(
                    id: "genre.\(genre.id)",
                    title: genre.name,
                    symbolName: "guitars",
                    action: .browse(.genre(id: genre.id, name: genre.name)),
                    showsDisclosure: true
                )
            }
        return alphabetical(title: strings.genres, items: items)
    }

    /// A page of tracks (album, playlist, liked songs, genre, offline album).
    /// `.playTrack(index:)` indexes into `tracks` as passed in, so the shell
    /// can queue the *whole* list even when the visible rows were truncated.
    public func trackList(
        title: String,
        tracks: [Track],
        style: TrackStyle,
        includeRadio: Bool = false,
        emptyTitle: String? = nil
    ) -> CarPlayListModel {
        guard !tracks.isEmpty else {
            return finish(title: title, sections: [], emptyTitle: emptyTitle ?? strings.nothingHere)
        }
        var actionItems = [
            CarPlayItem(id: "action.play", title: strings.play, symbolName: "play.fill", action: .playAll),
            CarPlayItem(id: "action.shuffle", title: strings.shuffle, symbolName: "shuffle", action: .shuffleAll),
        ]
        if includeRadio {
            actionItems.append(CarPlayItem(
                id: "action.radio",
                title: strings.startRadio,
                symbolName: "dot.radiowaves.left.and.right",
                action: .startRadio
            ))
        }
        let trackItems = tracks.enumerated().map { index, track in
            trackItem(track, index: index, style: style, idPrefix: "track")
        }
        return finish(
            title: title,
            sections: [
                CarPlaySection(items: actionItems),
                CarPlaySection(header: strings.songCount(tracks.count), items: trackItems),
            ],
            emptyTitle: emptyTitle ?? strings.nothingHere
        )
    }

    /// The Up Next page behind the Now Playing screen.
    public func queue(current: Track?, upNext: [Track]) -> CarPlayListModel {
        var sections: [CarPlaySection] = []
        if let current {
            var item = trackItem(current, index: 0, style: .mixed, idPrefix: "current")
            item.action = .none
            sections.append(CarPlaySection(header: strings.nowPlaying, items: [item]))
        }
        if !upNext.isEmpty {
            let items = upNext.enumerated().map { index, track -> CarPlayItem in
                var item = trackItem(track, index: index, style: .mixed, idPrefix: "upnext")
                item.action = .jumpToUpNext(index: index)
                // The same song can be queued twice; only the entry that is
                // actually playing (the "current" row) gets the indicator.
                item.trackID = nil
                return item
            }
            sections.append(CarPlaySection(header: strings.upNext, items: items))
        }
        return finish(title: strings.upNext, sections: sections, emptyTitle: strings.queueEmpty)
    }

    /// The only page shown while no account is connected.
    public func signedOut() -> CarPlayListModel {
        CarPlayListModel(title: "Jellyamp", sections: [], emptyTitle: strings.signedOutTitle, emptySubtitle: strings.signedOutHint)
    }

    // MARK: - Rows

    private func albumItem(_ album: Album) -> CarPlayItem {
        var subtitle = album.artistName
        if let year = album.productionYear {
            subtitle = subtitle.isEmpty ? String(year) : "\(subtitle) · \(year)"
        }
        return CarPlayItem(
            id: "album.\(album.id)",
            title: album.title,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            artwork: CarPlayArtworkRef(itemID: album.id, imageTag: album.imageTag),
            symbolName: "square.stack",
            action: .browse(.album(id: album.id, title: album.title)),
            showsDisclosure: true
        )
    }

    private func trackItem(_ track: Track, index: Int, style: TrackStyle, idPrefix: String) -> CarPlayItem {
        let subtitle: String
        switch style {
        case .album:
            let time = Self.formatDuration(track.duration)
            subtitle = track.artistName.isEmpty ? time : "\(track.artistName) · \(time)"
        case .mixed:
            if let album = track.albumName, !album.isEmpty, !track.artistName.isEmpty {
                subtitle = "\(track.artistName) — \(album)"
            } else {
                subtitle = track.artistName.isEmpty ? (track.albumName ?? "") : track.artistName
            }
        }
        return CarPlayItem(
            // The index keeps ids unique when a playlist contains a song twice.
            id: "\(idPrefix).\(index).\(track.id)",
            title: track.title,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            artwork: CarPlayArtworkRef(itemID: track.albumID ?? track.id, imageTag: track.imageTag),
            symbolName: "music.note",
            action: .playTrack(index: index),
            trackID: track.id
        )
    }

    /// "3:07", "1:02:45"; "0:00" for unknown or negative durations — the
    /// same text the phone's track rows show.
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        DurationText.clock(seconds)
    }

    // MARK: - Sectioning and limits

    /// Sorts rows by their article-less title and, for long lists, splits
    /// them into letter sections with index titles.
    private func alphabetical(title: String, items: [CarPlayItem]) -> CarPlayListModel {
        let sorted = items
            .map { (key: VoiceTextNormalizer.normalize($0.title), item: $0) }
            .sorted { lhs, rhs in
                if lhs.key != rhs.key { return lhs.key < rhs.key }
                return lhs.item.id < rhs.item.id
            }
            .map(\.item)
        // Cut first: sections built from rows that are dropped anyway would
        // waste the section budget.
        let visible = Array(sorted.prefix(limits.maximumItemCount))
        let wasCut = visible.count < sorted.count

        var sections: [CarPlaySection] = []
        if visible.count >= indexThreshold {
            for item in visible {
                var letter = VoiceTextNormalizer.indexLetter(item.title)
                // Only A–Z get their own section; other scripts share "#"
                // so the section budget is not spent on singletons.
                if letter != "#", !("A"..."Z").contains(letter) { letter = "#" }
                if let last = sections.indices.last, sections[last].indexTitle == letter {
                    sections[last].items.append(item)
                } else {
                    sections.append(CarPlaySection(header: letter, indexTitle: letter, items: [item]))
                }
            }
        }
        // Too few rows, or more letters than the head unit shows sections
        // for: fall back to one flat list rather than dropping letters.
        if sections.isEmpty || sections.count > limits.maximumSectionCount {
            sections = [CarPlaySection(items: visible)]
        }
        var model = finish(title: title, sections: sections, emptyTitle: strings.nothingHere)
        model.isTruncated = model.isTruncated || wasCut
        return model
    }

    /// Applies the limits: drops empty sections, keeps sections in order
    /// until the row budget is used up, and caps the section count.
    private func finish(title: String, sections: [CarPlaySection], emptyTitle: String, emptySubtitle: String? = nil) -> CarPlayListModel {
        var remaining = limits.maximumItemCount
        var kept: [CarPlaySection] = []
        var truncated = false
        for section in sections where !section.items.isEmpty {
            guard remaining > 0, kept.count < limits.maximumSectionCount else {
                truncated = true
                break
            }
            var copy = section
            if copy.items.count > remaining {
                copy.items = Array(copy.items.prefix(remaining))
                truncated = true
            }
            remaining -= copy.items.count
            kept.append(copy)
        }
        return CarPlayListModel(
            title: title,
            sections: kept,
            emptyTitle: emptyTitle,
            emptySubtitle: emptySubtitle,
            isTruncated: truncated
        )
    }
}
