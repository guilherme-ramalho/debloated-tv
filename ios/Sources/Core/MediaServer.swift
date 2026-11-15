import Foundation
import Network
import ImageIO
import UniformTypeIdentifiers

/// The byte range a request asks for, resolved against the file size (RFC 9110 single ranges; the TV's player asks
/// for "bytes=0-" first and then for later offsets while seeking).
public struct ByteRange: Equatable {
    public let start: Int
    public let end: Int
    public var length: Int { end - start + 1 }
    public init(start: Int, end: Int) { self.start = start; self.end = end }

    /// nil header → the whole file; nil result → unsatisfiable (416).
    public static func resolve(_ header: String?, size: Int) -> ByteRange? {
        guard size > 0 else { return nil }
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return ByteRange(start: 0, end: size - 1) }
        guard header.lowercased().hasPrefix("bytes="), !header.contains(",") else { return nil }
        let spec = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard spec.count == 2 else { return nil }
        if spec[0].isEmpty {
            guard let suffix = Int(spec[1]), suffix > 0 else { return nil }
            return ByteRange(start: max(0, size - suffix), end: size - 1)
        }
        guard let start = Int(spec[0]), start >= 0, start < size else { return nil }
        let end = spec[1].isEmpty ? size - 1 : min(Int(spec[1]) ?? -1, size - 1)
        guard end >= start else { return nil }
        return ByteRange(start: start, end: end)
    }
}

/// The request line and headers of one HTTP/1.1 request.
public struct HTTPRequestHead: Equatable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    /// nil until the blank line that ends the head has arrived.
    public static func parse(_ data: Data) -> HTTPRequestHead? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return HTTPRequestHead(method: "", path: "", headers: [:]) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return HTTPRequestHead(method: String(first[0]), path: String(first[1]), headers: headers)
    }
}

/// Serves the item on the TV to the TV's player over the home network, only while Show on TV is open. Each item
/// gets a random path; anything else gets 404. Files are read in 64 KB chunks as the player asks, never loaded whole.
public final class MediaServer: @unchecked Sendable {
    public struct Item { public let file: URL; public let contentType: String }
    private let queue = DispatchQueue(label: "tvremote.media-server", qos: .userInitiated)
    private var listener: NWListener?
    private var items: [String: Item] = [:]
    public private(set) var port: UInt16?
    private static let chunk = 65536
    /// Called (on the server's queue) for each request: method, whether the path is shared, the range asked.
    public var requestLog: ((String, Bool, String?) -> Void)?

    public init() {}

    /// Starts listening (once) and returns the port.
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (result: CheckedContinuation<UInt16, Error>) in
            queue.async { [self] in
                if let port { result.resume(returning: port); return }
                do {
                    let listener = try NWListener(using: .tcp)
                    self.listener = listener
                    var resumed = false
                    listener.stateUpdateHandler = { [weak self] state in
                        guard !resumed else { return }
                        switch state {
                        case .ready:
                            resumed = true
                            self?.port = listener.port?.rawValue
                            result.resume(returning: listener.port?.rawValue ?? 0)
                        case .failed(let error):
                            resumed = true
                            result.resume(throwing: error)
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
                    listener.start(queue: queue)
                } catch { result.resume(throwing: error) }
            }
        }
    }

    /// Makes a file reachable and returns its path ("/<random>/<name>"). Replaces whatever was shared before, so
    /// only the item on the TV (and the one prepared next) can be fetched.
    public func share(_ file: URL, contentType: String, keep: Int = 3) -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let path = "/\(token)/\(file.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "media")"
        queue.sync {
            items[path] = Item(file: file, contentType: contentType)
            order.append(path)
            while order.count > keep { items[order.removeFirst()] = nil }
        }
        return path
    }
    private var order: [String] = []
    private struct Folder { let url: URL; let requested: (String) -> Void }
    private var folders: [String: Folder] = [:]

    /// Shares a folder whose files appear over time (a converted video's playlist and segments) and returns its
    /// path ("/<random>/"). A file asked for before it exists is waited for up to 30 s; `requested` hears every
    /// name asked for, so the converter can follow the TV. Replaces the folder shared before.
    public func shareFolder(_ url: URL, requested: @escaping (String) -> Void) -> String {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let path = "/\(token)/"
        queue.sync { folders = [path: Folder(url: url, requested: requested)] }
        return path
    }

    public func stop() {
        queue.sync {
            listener?.cancel(); listener = nil; port = nil
            items = [:]; order = []; folders = [:]
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHead(connection, buffer: Data())
        queue.asyncAfter(deadline: .now() + 120) { connection.cancel() }   // no request lingers
    }
    private func readHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let head = HTTPRequestHead.parse(buffer) { self.respond(connection, head); return }
            if error != nil || complete || buffer.count > 16384 { connection.cancel(); return }
            self.readHead(connection, buffer: buffer)
        }
    }
    private func respond(_ connection: NWConnection, _ head: HTTPRequestHead) {
        guard head.method == "GET" || head.method == "HEAD" else { return finish(connection, status: "405 Method Not Allowed") }
        if let (folder, name) = folderFile(head.path) {
            requestLog?(head.method, true, name)
            folder.requested(name)
            let file = folder.url.appendingPathComponent(name)
            return waitFor(file, until: Date().addingTimeInterval(30)) { [weak self] ready in
                guard let self else { return }
                guard ready else { return self.finish(connection, status: "404 Not Found") }
                self.serveFile(connection, head, file, contentType: Self.contentType(name))
            }
        }
        requestLog?(head.method, items[head.path] != nil, head.headers["range"])
        guard let item = items[head.path] else { return finish(connection, status: "404 Not Found") }
        serveFile(connection, head, item.file, contentType: item.contentType)
    }
    private func folderFile(_ path: String) -> (Folder, String)? {
        guard let slash = path.dropFirst().firstIndex(of: "/") else { return nil }
        let prefix = String(path[...slash]), name = String(path[path.index(after: slash)...])
        guard let folder = folders[prefix], !name.isEmpty, !name.contains("/"), !name.contains(".."), !name.hasSuffix(".part") else { return nil }
        return (folder, name)
    }
    private func waitFor(_ file: URL, until deadline: Date, _ done: @escaping (Bool) -> Void) {
        if FileManager.default.fileExists(atPath: file.path) { return done(true) }
        guard Date() < deadline else { return done(false) }
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.waitFor(file, until: deadline, done) }
    }
    static func contentType(_ name: String) -> String {
        if name.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl" }
        if name.hasSuffix(".m4s") || name.hasSuffix(".mp4") { return "video/mp4" }
        return "application/octet-stream"
    }
    private func serveFile(_ connection: NWConnection, _ head: HTTPRequestHead, _ file: URL, contentType: String) {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              let handle = try? FileHandle(forReadingFrom: file) else { return finish(connection, status: "404 Not Found") }
        let asked = head.headers["range"]
        guard let range = ByteRange.resolve(asked, size: size) else {
            try? handle.close()
            return finish(connection, status: "416 Range Not Satisfiable", extra: "Content-Range: bytes */\(size)\r\n")
        }
        var response = asked == nil ? "HTTP/1.1 200 OK\r\n" : "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(range.start)-\(range.end)/\(size)\r\n"
        response += "Content-Type: \(contentType)\r\nContent-Length: \(range.length)\r\nAccept-Ranges: bytes\r\n"
        response += "Access-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil, head.method == "GET" else { try? handle.close(); connection.cancel(); return }
            do { try handle.seek(toOffset: UInt64(range.start)) } catch { try? handle.close(); connection.cancel(); return }
            self.stream(connection, handle, remaining: range.length)
        })
    }
    /// One chunk at a time, the next after the previous was handed to the network, so memory stays at one chunk.
    private func stream(_ connection: NWConnection, _ handle: FileHandle, remaining: Int) {
        guard remaining > 0, let data = try? handle.read(upToCount: min(Self.chunk, remaining)), !data.isEmpty else {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error == nil else { try? handle.close(); connection.cancel(); return }
            self?.stream(connection, handle, remaining: remaining - data.count)
        })
    }
    private func finish(_ connection: NWConnection, status: String, extra: String = "") {
        let response = "HTTP/1.1 \(status)\r\n\(extra)Content-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// This phone's address as the TV can reach it: the IPv4 address on the TV's own subnet, else the Wi-Fi one.
public enum LocalAddress {
    public struct Interface: Equatable { public let name: String; public let address: String; public let netmask: String
        public init(name: String, address: String, netmask: String) { self.name = name; self.address = address; self.netmask = netmask } }

    public static func pick(for tvHost: String, from interfaces: [Interface]) -> String? {
        let usable = interfaces.filter { !$0.address.hasPrefix("127.") && !$0.address.hasPrefix("169.254.") }
        if let tv = ipv4(tvHost), let same = usable.first(where: { interface in
            guard let address = ipv4(interface.address), let mask = ipv4(interface.netmask) else { return false }
            return address & mask == tv & mask
        }) { return same.address }
        return usable.first(where: { $0.name == "en0" })?.address
    }
    public static func current(for tvHost: String) -> String? { pick(for: tvHost, from: interfaces()) }

    static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 < 256 }) else { return nil }
        return parts[0] << 24 | parts[1] << 16 | parts[2] << 8 | parts[3]
    }
    static func interfaces() -> [Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), let mask = entry.ifa_netmask else { continue }
            result.append(Interface(name: String(cString: entry.ifa_name), address: text(address), netmask: text(mask)))
        }
        return result
    }
    private static func text(_ address: UnsafeMutablePointer<sockaddr>) -> String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        return String(cString: host)
    }
}

/// Photos for the TV: the TV's player refuses HEIC (CST-02), so every photo becomes a JPEG at most 3840 px on its
/// long side, upright. ImageIO's thumbnailer decodes straight to that size, so a 48 MP photo is never decoded in
/// full. No metadata is copied: location and camera details never reach the TV.
public enum PhotoPrep {
    public static let maxPixel = 3840
    /// What the app sends: the TV's Cast player draws at 1920 x 1080 (TCL: `wm size` 1920x1080), so larger photos
    /// look the same and only take longer to fetch and decode.
    public static let tvPixel = 1920

    public static func jpeg(from data: Data, maxPixel: Int = maxPixel, quality: Double = 0.85) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary) else {
            throw RemoteFailure.message(String(localized: "This photo couldn't be read."))
        }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RemoteFailure.message(String(localized: "This photo couldn't be prepared for the TV."))
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RemoteFailure.message(String(localized: "This photo couldn't be prepared for the TV.")) }
        return out as Data
    }
}
