import Foundation

public enum RelayProtocol {
    public static let service = "_relay-screen._tcp"
    public static let port: UInt16 = 47221
    public static let frameLimit = 8 * 1024 * 1024
    public static let controlLimit = 32 * 1024
    public static var clock: UInt64 { UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000) }
}

public enum RelayError: LocalizedError {
    case protocolViolation, credentials, timeout, video(Int32), disconnected, message(String)

    public var errorDescription: String? {
        switch self {
        case .protocolViolation: "Incompatible or invalid Relay message."
        case .credentials: "Relay could not verify this device’s identity or access its credentials."
        case .timeout: "The connection timed out. Check Wi-Fi, Local Network access and the Mac’s firewall."
        case .video(let status): "Video processing failed (\(status))."
        case .disconnected: "Connection closed."
        case .message(let text): text
        }
    }
}

public enum Quality: String, Codable, CaseIterable, Identifiable, Sendable {
    case dataSaver, balanced, high, ultra, native
    public var id: Self { self }
    public var title: String {
        switch self {
        case .dataSaver: "Data Saver"
        case .balanced: "Balanced"
        case .high: "High"
        case .ultra: "Ultra"
        case .native: "Native"
        }
    }
    public var fps: Int { self == .dataSaver ? 15 : (self == .ultra || self == .native ? 60 : 30) }
    public var bitrate: Int {
        switch self {
        case .dataSaver: 750_000
        case .balanced: 2_200_000
        case .high: 4_500_000
        case .ultra: 8_000_000
        case .native: 16_000_000
        }
    }
    public var lower: Quality? {
        let list = Self.allCases
        guard let index = list.firstIndex(of: self), index > 0 else { return nil }
        return list[index - 1]
    }

    public func dimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        let target = switch self {
        case .dataSaver: 480.0
        case .balanced: 720.0
        case .high, .ultra: 1080.0
        case .native: Double(min(width, height))
        }
        let scale = min(1, target / Double(max(1, min(width, height))), 4096 / Double(max(1, max(width, height))))
        return (max(2, Int(Double(width) * scale) & ~1), max(2, Int(Double(height) * scale) & ~1))
    }
}

public struct DisplayInfo: Codable, Equatable, Identifiable, Sendable {
    public let id: UInt32
    public let name: String
    public let width: Int
    public let height: Int
    public init(id: UInt32, name: String, width: Int, height: Int) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
    }
}

public struct VideoConfig: Codable, Equatable, Sendable {
    public let generation: UUID
    public let width: Int
    public let height: Int
    public let sps: Data
    public let pps: Data

    public init(generation: UUID, width: Int, height: Int, sps: Data, pps: Data) {
        self.generation = generation
        self.width = width
        self.height = height
        self.sps = sps
        self.pps = pps
    }
}

public struct StreamStats: Codable, Equatable, Sendable {
    public var captured: Int
    public var encoded: Int
    public var dropped: Int
    public var bitrate: Int
    public init(captured: Int, encoded: Int, dropped: Int, bitrate: Int) {
        self.captured = captured
        self.encoded = encoded
        self.dropped = dropped
        self.bitrate = bitrate
    }
}

public enum Control: Codable, Sendable {
    case hello
    case challenge(Data)
    case identify(key: Data, signature: Data, name: String)
    case codeRequired
    case pair(String)
    case awaitingApproval
    case authorized(name: String, tunnel: RelayInvite? = nil)
    case denied(String)
    case catalog(displays: [DisplayInfo], selected: UInt32?, quality: Quality)
    case start
    case stop
    case paused(String)
    case quality(Quality)
    case display(UInt32)
    case keyframe
    case config(VideoConfig)
    case stats(StreamStats)
    case ping(UInt64)
    case pong(sent: UInt64, remote: UInt64)
    case receipt(UInt64)
}

public struct VideoFrame: Sendable {
    public let sequence: UInt64
    public let timestampMicros: UInt64
    public let keyframe: Bool
    public let bytes: Data

    public init(sequence: UInt64, timestampMicros: UInt64, keyframe: Bool, bytes: Data) {
        self.sequence = sequence
        self.timestampMicros = timestampMicros
        self.keyframe = keyframe
        self.bytes = bytes
    }
}

public enum Packet: Sendable {
    case control(Control)
    case video(VideoFrame)
}

public enum Wire {
    public static let headerSize = 6
    public static func encode(_ packet: Packet) throws -> Data {
        let kind: UInt8
        var payload: Data
        switch packet {
        case .control(let control):
            kind = 1
            payload = try JSONEncoder().encode(control)
        case .video(let frame):
            kind = 2
            guard frame.bytes.count <= RelayProtocol.frameLimit - 17 else { throw RelayError.protocolViolation }
            payload = Data(capacity: 17 + frame.bytes.count)
            payload.append(integerBytes(frame.sequence))
            payload.append(integerBytes(frame.timestampMicros))
            payload.append(frame.keyframe ? 1 : 0)
            payload.append(frame.bytes)
        }
        let limit = kind == 1 ? RelayProtocol.controlLimit : RelayProtocol.frameLimit
        guard !payload.isEmpty, payload.count <= limit else { throw RelayError.protocolViolation }
        var data = Data(capacity: headerSize + payload.count)
        data.append(contentsOf: [1, kind])
        data.append(integerBytes(UInt32(payload.count)))
        data.append(payload)
        return data
    }

    public static func header(_ data: Data) throws -> (kind: UInt8, length: Int) {
        guard data.count == headerSize, data.first == 1 else { throw RelayError.protocolViolation }
        let kind = data[data.startIndex + 1]
        let length = Int(integer(data.dropFirst(2), as: UInt32.self))
        guard (kind == 1 && (1...RelayProtocol.controlLimit).contains(length))
            || (kind == 2 && (18...RelayProtocol.frameLimit).contains(length)) else {
            throw RelayError.protocolViolation
        }
        return (kind, length)
    }

    public static func decode(kind: UInt8, payload: Data) throws -> Packet {
        if kind == 1, payload.count <= RelayProtocol.controlLimit {
            return .control(try JSONDecoder().decode(Control.self, from: payload))
        }
        guard kind == 2, (18...RelayProtocol.frameLimit).contains(payload.count) else {
            throw RelayError.protocolViolation
        }
        let flag = payload[payload.startIndex + 16]
        guard flag <= 1 else { throw RelayError.protocolViolation }
        return .video(VideoFrame(
            sequence: integer(payload.prefix(8), as: UInt64.self),
            timestampMicros: integer(payload.dropFirst(8).prefix(8), as: UInt64.self),
            keyframe: flag == 1,
            bytes: Data(payload.dropFirst(17))
        ))
    }

    private static func integer<T: FixedWidthInteger>(_ data: Data, as: T.Type) -> T {
        data.reduce(T.zero) { ($0 << 8) | T($1) }
    }

    private static func integerBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
