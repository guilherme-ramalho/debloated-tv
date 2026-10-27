import Foundation

public enum RemoteFailure: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

/// The small protobuf subset used by the Android TV Remote v2 protocol.
public enum Wire {
    public struct Field {
        public let number: Int
        public let integer: UInt64?
        public let bytes: Data?
    }
    public static func varint(_ value: UInt64) -> Data {
        var value = value, result = Data()
        repeat {
            var byte = UInt8(value & 127)
            value >>= 7
            if value != 0 { byte |= 128 }
            result.append(byte)
        } while value != 0
        return result
    }
    public static func int(_ field: Int, _ value: UInt64) -> Data { varint(UInt64(field << 3)) + varint(value) }
    public static func bytes(_ field: Int, _ value: Data) -> Data {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(value.count)) + value
    }
    public static func string(_ field: Int, _ value: String) -> Data { bytes(field, Data(value.utf8)) }
    public static func readVarint(_ bytes: [UInt8], _ offset: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < bytes.count else { throw RemoteFailure.message("Incomplete protocol value") }
            let byte = bytes[offset]; offset += 1
            if shift == 63 && byte > 1 { throw RemoteFailure.message("Invalid protocol value") }
            value |= UInt64(byte & 127) << shift
            if byte & 128 == 0 { return value }
        }
        throw RemoteFailure.message("Invalid protocol value")
    }
    public static func fields(_ data: Data) throws -> [Field] {
        let data = Array(data)
        var offset = 0, result = [Field]()
        while offset < data.count {
            let tag = try readVarint(data, &offset)
            let number = Int(tag >> 3)
            guard number > 0 else { throw RemoteFailure.message("Invalid protocol field") }
            switch tag & 7 {
            case 0: result.append(Field(number: number, integer: try readVarint(data, &offset), bytes: nil))
            case 2:
                let length = try readVarint(data, &offset)
                guard length <= UInt64(data.count - offset) else { throw RemoteFailure.message("Truncated protocol message") }
                let end = offset + Int(length)
                result.append(Field(number: number, integer: nil, bytes: Data(data[offset..<end])))
                offset = end
            case 1, 5:
                let length = tag & 7 == 1 ? 8 : 4
                guard length <= data.count - offset else { throw RemoteFailure.message("Truncated protocol message") }
                offset += length
            default: throw RemoteFailure.message("Unsupported protocol field")
            }
        }
        return result
    }
    public static func number(_ field: Int, in data: Data) throws -> UInt64 {
        try fields(data).first(where: { $0.number == field })?.integer ?? 0
    }
}

/// Handles split length prefixes, fragmented messages, and several messages in one TCP read.
public struct FrameDecoder {
    private var buffer = Data()
    private let maximum: Int
    public init(maxFrameSize: Int = 65536) { maximum = min(4_194_304, max(1, maxFrameSize)) }
    public mutating func append(_ incoming: Data) throws -> [Data] {
        guard buffer.count + incoming.count <= maximum * 2 + 10 else { throw RemoteFailure.message("Protocol buffer limit exceeded") }
        buffer.append(incoming)
        var result = [Data]()
        while !buffer.isEmpty {
            let bytes = Array(buffer.prefix(5))
            guard let last = bytes.firstIndex(where: { $0 & 128 == 0 }) else {
                if bytes.count == 5 { throw RemoteFailure.message("Invalid frame length") }
                break
            }
            var offset = 0
            let size = try Wire.readVarint(bytes, &offset)
            guard size > 0 && size <= maximum else { throw RemoteFailure.message("Invalid frame size") }
            let prefix = last + 1
            guard buffer.count >= prefix + Int(size) else { break }
            result.append(Data(buffer.dropFirst(prefix).prefix(Int(size))))
            buffer.removeFirst(prefix + Int(size))
        }
        return result
    }
}

public enum TVKey: UInt64 {
    case home = 3, back = 4, up = 19, down = 20, left = 21, right = 22, select = 23
    case volumeUp = 24, volumeDown = 25, power = 26, playPause = 85, play = 126, pause = 127, mute = 164, settings = 176, inputs = 178
}

/// Only an explicit wake action may survive reconnection, once and for at most 30 seconds.
public struct WakeRequest {
    private var deadline: Date?
    public init() {}
    public mutating func begin(now: Date = Date()) { deadline = now.addingTimeInterval(30) }
    public mutating func cancel() { deadline = nil }
    public mutating func consume(powerIsOn: Bool, now: Date = Date()) -> TVKey? {
        defer { deadline = nil }
        guard !powerIsOn, deadline.map({ now < $0 }) ?? false else { return nil }
        return .power
    }
}
