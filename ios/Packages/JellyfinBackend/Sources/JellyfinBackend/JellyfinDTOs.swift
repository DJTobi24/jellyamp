import Foundation
import JellyampCore

/// Subset of Jellyfin's BaseItemDto we actually consume, mapped to Core
/// models. Field names follow the wire format (PascalCase).
struct BaseItemDto: Codable {
    struct MediaSource: Codable {
        struct MediaStream: Codable {
            var `Type`: String?
            var Codec: String?
            var SampleRate: Int?
            var BitDepth: Int?
        }
        var Container: String?
        var Bitrate: Int?
        var MediaStreams: [MediaStream]?
    }

    var Id: String
    var Name: String?
    var `Type`: String?
    var AlbumArtist: String?
    var AlbumArtists: [NameID]?
    var ArtistItems: [NameID]?
    var Album: String?
    var AlbumId: String?
    var IndexNumber: Int?
    var ParentIndexNumber: Int?
    var RunTimeTicks: Int64?
    var MediaSources: [MediaSource]?
    var NormalizationGain: Double?
    var UserData: UserData?
    var Genres: [String]?
    var ProductionYear: Int?
    var ImageTags: [String: String]?
    var AlbumPrimaryImageTag: String?
    var ChildCount: Int?

    struct NameID: Codable {
        var Name: String?
        var Id: String?
    }

    struct UserData: Codable {
        var IsFavorite: Bool?
        var PlayCount: Int?
    }
}

struct ItemsResponse: Codable {
    var Items: [BaseItemDto]
    var TotalRecordCount: Int?
}

enum DTOMapper {
    static func seconds(fromTicks ticks: Int64?) -> TimeInterval {
        Double(ticks ?? 0) / 10_000_000
    }

    static func track(from dto: BaseItemDto) -> Track {
        let source = dto.MediaSources?.first
        let audioStream = source?.MediaStreams?.first { $0.Type == "Audio" }
        return Track(
            id: dto.Id,
            title: dto.Name ?? "",
            artistName: dto.ArtistItems?.first?.Name ?? dto.AlbumArtist ?? "",
            artistID: dto.ArtistItems?.first?.Id,
            albumName: dto.Album,
            albumID: dto.AlbumId,
            indexNumber: dto.IndexNumber,
            discNumber: dto.ParentIndexNumber,
            duration: seconds(fromTicks: dto.RunTimeTicks),
            container: source?.Container,
            codec: audioStream?.Codec,
            bitrate: source?.Bitrate,
            sampleRate: audioStream?.SampleRate,
            bitDepth: audioStream?.BitDepth,
            normalizationGainDB: dto.NormalizationGain,
            isFavorite: dto.UserData?.IsFavorite ?? false,
            genres: dto.Genres ?? [],
            productionYear: dto.ProductionYear,
            imageTag: dto.ImageTags?["Primary"] ?? dto.AlbumPrimaryImageTag
        )
    }

    static func album(from dto: BaseItemDto) -> Album {
        Album(
            id: dto.Id,
            title: dto.Name ?? "",
            artistName: dto.AlbumArtists?.first?.Name ?? dto.AlbumArtist ?? "",
            artistID: dto.AlbumArtists?.first?.Id,
            productionYear: dto.ProductionYear,
            genres: dto.Genres ?? [],
            trackCount: dto.ChildCount,
            duration: dto.RunTimeTicks.map { Double($0) / 10_000_000 },
            isFavorite: dto.UserData?.IsFavorite ?? false,
            imageTag: dto.ImageTags?["Primary"],
            normalizationGainDB: dto.NormalizationGain
        )
    }

    static func artist(from dto: BaseItemDto) -> Artist {
        Artist(
            id: dto.Id,
            name: dto.Name ?? "",
            genres: dto.Genres ?? [],
            isFavorite: dto.UserData?.IsFavorite ?? false,
            imageTag: dto.ImageTags?["Primary"]
        )
    }
}
