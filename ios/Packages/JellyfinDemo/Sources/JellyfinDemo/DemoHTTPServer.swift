import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// Serves a `DemoBackend` over HTTP on the loopback interface, so that the
/// whole app — REST clients, `AsyncImage`, the streaming player, background
/// downloads — reaches the demo library through URLs like any server, with
/// no demo-specific code path anywhere else.
///
/// Deliberately small: plain BSD sockets (identical on iOS and Linux, where
/// the tests run it against a real `URLSession`), one thread per connection,
/// one request per connection. It only ever listens on 127.0.0.1.
public final class DemoHTTPServer: @unchecked Sendable {
    public enum ServerError: Error, Equatable {
        case socket(Int32)
        case bind(Int32)
        case listen(Int32)
    }

    private let backend: DemoBackend
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var boundPort: UInt16 = 0
    private var generation = 0

    public init(backend: DemoBackend) {
        self.backend = backend
    }

    deinit {
        stop()
    }

    /// The port being served, or nil while stopped.
    public var port: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return listener >= 0 ? boundPort : nil
    }

    public var baseURL: URL? {
        port.flatMap { URL(string: "http://127.0.0.1:\($0)") }
    }

    /// Starts listening on a free port (or keeps the current one) and
    /// returns the base URL. Safe to call repeatedly.
    @discardableResult
    public func start() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        if listener < 0 {
            let descriptor = try Self.makeListener(port: 0)
            listener = descriptor
            boundPort = Self.port(of: descriptor)
            generation += 1
            let current = generation
            Thread.detachNewThread { [weak self] in
                self?.acceptLoop(generation: current)
            }
        }
        return URL(string: "http://127.0.0.1:\(boundPort)")!
    }

    public func stop() {
        lock.lock()
        let descriptor = listener
        listener = -1
        generation += 1
        lock.unlock()
        if descriptor >= 0 {
            // Wakes the blocked accept() as well.
            _ = shutdown(descriptor, Int32(SHUT_RDWR))
            _ = systemClose(descriptor)
        }
    }

    // MARK: - Listening

    private static func makeListener(port: UInt16) throws -> Int32 {
        #if canImport(Darwin)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { throw ServerError.socket(errno) }
        var reuse: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        // 127.0.0.1 in network byte order: never reachable from other hosts.
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            _ = systemClose(descriptor)
            throw ServerError.bind(code)
        }
        guard listen(descriptor, 32) == 0 else {
            let code = errno
            _ = systemClose(descriptor)
            throw ServerError.listen(code)
        }
        return descriptor
    }

    private static func port(of descriptor: Int32) -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    private func acceptLoop(generation current: Int) {
        while true {
            lock.lock()
            let descriptor = listener
            let stillCurrent = generation == current
            let wantedPort = boundPort
            lock.unlock()
            guard stillCurrent, descriptor >= 0 else { return }

            let client = accept(descriptor, nil, nil)
            if client >= 0 {
                Thread.detachNewThread { [backend] in
                    Self.serve(client: client, backend: backend)
                }
                continue
            }
            let code = errno
            if code == EINTR || code == ECONNABORTED { continue }

            // The listening socket died underneath us. iOS reclaims the
            // sockets of a suspended app; when the app comes back the demo
            // must keep working on the same port, because the session's
            // base URL (and with it every image and stream URL) carries it.
            lock.lock()
            let stopped = generation != current
            lock.unlock()
            if stopped { return }
            _ = systemClose(descriptor)
            var replacement: Int32 = -1
            for _ in 0..<50 {
                if let fresh = try? Self.makeListener(port: wantedPort) {
                    replacement = fresh
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            lock.lock()
            if generation == current {
                listener = replacement
                lock.unlock()
                if replacement < 0 { return }
            } else {
                lock.unlock()
                if replacement >= 0 { _ = systemClose(replacement) }
                return
            }
        }
    }

    // MARK: - One connection

    private static func serve(client: Int32, backend: DemoBackend) {
        defer { _ = systemClose(client) }
        #if canImport(Darwin)
        // A client that hangs up mid-response must not kill the app.
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var request: DemoHTTPRequest?
        while request == nil {
            let count = chunk.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk[0..<count])
            // An HTTP request starts with a method name. Anything else — a
            // TLS handshake from a client trying https first — is hung up
            // on at once instead of after the read timeout.
            if let first = buffer.first, !(UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(first) { return }
            switch DemoHTTPWire.parse(buffer) {
            case .incomplete:
                continue
            case .invalid:
                write(DemoHTTPWire.head(for: .error(400, "Bad request.")), to: client)
                return
            case .request(let parsed):
                request = parsed
            }
        }
        guard let request else { return }
        let response = backend.respond(to: request)
        guard write(DemoHTTPWire.head(for: response), to: client) else { return }
        if request.method != "HEAD" {
            _ = write(response.body, to: client)
        }
        // Let the peer read everything before the socket goes away.
        _ = shutdown(client, Int32(SHUT_WR))
        var drain = [UInt8](repeating: 0, count: 512)
        _ = drain.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
    }

    @discardableResult
    private static func write(_ data: Data, to client: Int32) -> Bool {
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                let count = send(client, base.advanced(by: sent), raw.count - sent, flags)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }
}

/// `close(2)`, under a name that cannot be confused with a method.
private func systemClose(_ descriptor: Int32) -> Int32 {
    close(descriptor)
}
