import Foundation

/// An HTTP request as the demo backend sees it, independent of how it
/// arrived (the loopback socket or the in-process `DemoTransport`).
public struct DemoHTTPRequest: Sendable {
    public var method: String
    /// Decoded path without the leading slash, e.g. `Items/abc/Images/Primary`.
    public var path: String
    public var query: [(name: String, value: String)]
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [(name: String, value: String)] = [], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// From a request line target (`/Items?ids=…`). Nil if it is not a
    /// usable origin-form target.
    public init?(method: String, target: String, headers: [String: String] = [:], body: Data = Data()) {
        guard target.hasPrefix("/") else { return nil }
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts[0])
        guard let path = rawPath.removingPercentEncoding else { return nil }
        var query: [(name: String, value: String)] = []
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&", omittingEmptySubsequences: true) {
                let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                // Like ASP.NET (Jellyfin): "+" in a query is a space.
                let name = Self.decodeQueryComponent(String(keyValue[0]))
                let value = keyValue.count > 1 ? Self.decodeQueryComponent(String(keyValue[1])) : ""
                query.append((name, value))
            }
        }
        self.init(
            method: method,
            path: String(path.drop(while: { $0 == "/" })),
            query: query,
            headers: headers,
            body: body
        )
    }

    private static func decodeQueryComponent(_ text: String) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    /// Query parameter by name. Jellyfin matches parameter names without
    /// regard to case (`userId`, `UserId`).
    public func parameter(_ name: String) -> String? {
        let wanted = name.lowercased()
        return query.first { $0.name.lowercased() == wanted }?.value
    }

    func list(_ name: String, separator: Character = ",") -> [String] {
        (parameter(name) ?? "")
            .split(separator: separator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func flag(_ name: String) -> Bool? {
        parameter(name).map { $0.lowercased() == "true" }
    }

    func integer(_ name: String) -> Int? {
        parameter(name).flatMap { Int($0) }
    }

    var pathComponents: [String] {
        path.split(separator: "/").map(String.init)
    }
}

public struct DemoHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json(_ object: Any, status: Int = 200) -> DemoHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return DemoHTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    /// A bare JSON value (`true`, a number): `JSONSerialization` wants a
    /// container at the top on some platforms.
    static func jsonFragment(_ text: String) -> DemoHTTPResponse {
        DemoHTTPResponse(status: 200, headers: ["Content-Type": "application/json; charset=utf-8"], body: Data(text.utf8))
    }

    static let noContent = DemoHTTPResponse(status: 204)

    static func error(_ status: Int, _ message: String = "Error processing request.") -> DemoHTTPResponse {
        DemoHTTPResponse(status: status, headers: ["Content-Type": "text/plain"], body: Data(message.utf8))
    }

    static func file(_ data: Data, contentType: String) -> DemoHTTPResponse {
        DemoHTTPResponse(status: 200, headers: ["Content-Type": contentType, "Accept-Ranges": "bytes"], body: data)
    }

    /// Applies a `Range: bytes=…` request header to a 200 response that
    /// advertises `Accept-Ranges` (audio files): 206 with `Content-Range`,
    /// or 416 when the range lies outside the file. Other responses pass
    /// through unchanged.
    public func applyingRange(_ rangeHeader: String?) -> DemoHTTPResponse {
        guard status == 200, headers["Accept-Ranges"] == "bytes",
              let rangeHeader, let range = Self.parseRange(rangeHeader, length: body.count)
        else { return self }
        guard let range = range else {
            var failure = DemoHTTPResponse.error(416, "Requested range not satisfiable.")
            failure.headers["Content-Range"] = "bytes */\(body.count)"
            return failure
        }
        var partial = self
        partial.status = 206
        partial.headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(body.count)"
        let start = body.startIndex + range.lowerBound
        partial.body = body.subdata(in: start..<(start + range.count))
        return partial
    }

    /// `nil`: not a byte range we understand (ignore the header).
    /// `.some(nil)`: a byte range, but unsatisfiable.
    static func parseRange(_ header: String, length: Int) -> ClosedRange<Int>?? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = trimmed.dropFirst(6)
        // Only single ranges; a multi-range request gets the whole file.
        guard !spec.contains(",") else { return nil }
        let bounds = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty {
            // Suffix range: the last N bytes.
            guard let suffix = Int(bounds[1]) else { return nil }
            guard suffix > 0, length > 0 else { return .some(nil) }
            return .some(max(0, length - suffix)...(length - 1))
        }
        guard let first = Int(bounds[0]) else { return nil }
        guard first < length else { return .some(nil) }
        if bounds[1].isEmpty {
            return .some(first...(length - 1))
        }
        guard let last = Int(bounds[1]) else { return nil }
        guard last >= first else { return nil }
        return .some(first...min(last, length - 1))
    }

    static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 416: return "Range Not Satisfiable"
        case 422: return "Unprocessable Entity"
        default: return status >= 500 ? "Internal Server Error" : "Unknown"
        }
    }
}

/// HTTP/1.1 on the wire, just enough for the demo server: one request per
/// connection, `Content-Length` bodies, no chunked encoding.
enum DemoHTTPWire {
    static let headerLimit = 64 * 1024
    /// Playlist cover uploads are the largest bodies the app sends.
    static let bodyLimit = 32 * 1024 * 1024

    enum ParseResult {
        /// More bytes are needed.
        case incomplete
        case invalid
        case request(DemoHTTPRequest)
    }

    static func parse(_ buffer: Data) -> ParseResult {
        let separator = Data([13, 10, 13, 10])
        guard let headerEnd = buffer.range(of: separator) else {
            return buffer.count > headerLimit ? .invalid : .incomplete
        }
        guard let head = String(data: buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound), encoding: .utf8) else {
            return .invalid
        }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let length = headers["content-length"].flatMap { Int($0) } ?? 0
        guard length >= 0, length <= bodyLimit else { return .invalid }
        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        guard let request = DemoHTTPRequest(
            method: String(requestLine[0]), target: String(requestLine[1]), headers: headers, body: body
        ) else { return .invalid }
        return .request(request)
    }

    /// Status line and headers of a response; the body follows unless the
    /// request was a HEAD.
    static func head(for response: DemoHTTPResponse) -> Data {
        var text = "HTTP/1.1 \(response.status) \(DemoHTTPResponse.reasonPhrase(for: response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Server"] = "JellyampDemo"
        for name in headers.keys.sorted() {
            text += "\(name): \(headers[name] ?? "")\r\n"
        }
        text += "\r\n"
        return Data(text.utf8)
    }
}
