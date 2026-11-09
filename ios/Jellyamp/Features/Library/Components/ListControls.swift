import SwiftUI
import JellyampCore

// MARK: - Sort menu

/// A sort option that can name itself in the UI.
protocol TitledSortOption: LibrarySortOption {
    var title: String { get }
}

extension AlbumSortOption: TitledSortOption {
    var title: String {
        switch self {
        case .name: return String(localized: "Name")
        case .artist: return String(localized: "Artist")
        case .year: return String(localized: "Year")
        case .recentlyAdded: return String(localized: "Recently Added")
        case .random: return String(localized: "Random")
        }
    }
}

extension ArtistSortOption: TitledSortOption {
    var title: String {
        switch self {
        case .name: return String(localized: "Name")
        case .recentlyAdded: return String(localized: "Recently Added")
        case .random: return String(localized: "Random")
        }
    }
}

extension TrackSortOption: TitledSortOption {
    var title: String {
        switch self {
        case .title: return String(localized: "Title")
        case .album: return String(localized: "Album")
        case .artist: return String(localized: "Artist")
        case .recentlyAdded: return String(localized: "Recently Added")
        case .mostPlayed: return String(localized: "Most Played")
        case .year: return String(localized: "Year")
        case .duration: return String(localized: "Duration")
        case .random: return String(localized: "Random")
        }
    }
}

extension PlaylistSortOption: TitledSortOption {
    var title: String {
        switch self {
        case .name: return String(localized: "Name")
        case .recentlyAdded: return String(localized: "Recently Added")
        }
    }
}

/// The entries of a sort menu: one button per option, the active one marked
/// with its direction. Choosing the active option again flips the direction.
/// Put it inside a `Menu` (optionally next to other entries).
struct SortMenuItems<Option: TitledSortOption>: View {
    @Binding var selection: SortSelection<Option>

    var body: some View {
        Section("Sort By") {
            ForEach(Array(Option.allCases), id: \.self) { option in
                Button {
                    selection.select(option)
                } label: {
                    if option == selection.option {
                        Label(option.title, systemImage: icon(for: option))
                    } else {
                        Text(option.title)
                    }
                }
                .accessibilityLabel(Text(accessibilityLabel(for: option)))
            }
        }
    }

    private func icon(for option: Option) -> String {
        guard option.supportsDirection else { return "checkmark" }
        return selection.direction == .ascending ? "chevron.up" : "chevron.down"
    }

    private func accessibilityLabel(for option: Option) -> String {
        guard option == selection.option else { return option.title }
        guard option.supportsDirection else { return String(localized: "\(option.title), selected") }
        return selection.direction == .ascending
            ? String(localized: "\(option.title), ascending. Activate to reverse.")
            : String(localized: "\(option.title), descending. Activate to reverse.")
    }
}

/// Toolbar button with a sort menu.
struct SortMenu<Option: TitledSortOption>: View {
    @Binding var selection: SortSelection<Option>

    var body: some View {
        Menu {
            SortMenuItems(selection: $selection)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .accessibilityLabel(Text("Sort"))
        .accessibilityValue(Text(selection.option.title))
    }
}

// MARK: - A–Z index

/// Resolves a letter to a server offset and restarts a list there; keeps
/// track of the active letter and cancels a lookup that is superseded.
@MainActor
final class AlphabetJumpController: ObservableObject {
    /// The letter the list currently starts at; nil = from the beginning.
    @Published private(set) var activeLetter: String?
    @Published private(set) var isResolving = false
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - resolve: looks up the server offset of the letter.
    ///   - apply: restarts the list at that offset.
    func jump(to letter: String, resolve: @escaping (String) async throws -> Int, apply: @escaping (Int) async -> Void) {
        task?.cancel()
        isResolving = true
        task = Task { @MainActor in
            do {
                let offset = try await resolve(letter)
                guard !Task.isCancelled else { return }
                self.isResolving = false
                self.activeLetter = offset == 0 ? nil : letter
                await apply(offset)
            } catch {
                guard !Task.isCancelled else { return }
                self.isResolving = false
                ToastCenter.shared.showError(String(localized: "Could not jump to \(letter)"), error: error)
            }
        }
    }

    /// Back to the start of the list.
    func reset(apply: @escaping (Int) async -> Void) {
        task?.cancel()
        isResolving = false
        guard activeLetter != nil else { return }
        activeLetter = nil
        task = Task { @MainActor in await apply(0) }
    }

    /// Forget the letter without reloading (the list was reloaded for
    /// another reason, e.g. a new sort order).
    func clear() {
        task?.cancel()
        isResolving = false
        activeLetter = nil
    }
}

/// Horizontal A–Z strip. Lists here are paged from the server, so a letter
/// does not scroll — it restarts the list at the first item from that letter
/// on. A horizontal strip (rather than the classic thin edge index) keeps
/// every letter a 44-point target and works at any text size.
struct AlphabetJumpBar: View {
    @ObservedObject var controller: AlphabetJumpController
    let select: (String) -> Void
    let reset: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if controller.activeLetter != nil {
                    Button(action: reset) {
                        Label("All", systemImage: "arrow.uturn.backward")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 10)
                            .frame(minHeight: 44)
                    }
                    .accessibilityLabel(Text("Show from the beginning"))
                }
                ForEach(AlphabetIndex.letters, id: \.self) { letter in
                    Button {
                        select(letter)
                    } label: {
                        Text(letter)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(letter == controller.activeLetter ? Color.black : Color.primary)
                            .frame(minWidth: 36, minHeight: 32)
                            .background {
                                if letter == controller.activeLetter {
                                    RoundedRectangle(cornerRadius: 8).fill(Color.white)
                                }
                            }
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(letter == AlphabetIndex.symbols ? "Jump to the beginning" : "Jump to \(letter)"))
                    .accessibilityAddTraits(letter == controller.activeLetter ? .isSelected : [])
                }
                if controller.isResolving {
                    ProgressView().padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, 8)
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Alphabet index"))
    }
}
