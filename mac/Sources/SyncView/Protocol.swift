import Foundation

/// Protocolo SyncView v1 (TCP, big-endian).
/// Todo pacote: [tipo u8][tamanho u32][payload].
enum Proto {
    static let port: UInt16 = 52020
    static let version: UInt16 = 1
    static let magic: [UInt8] = Array("SYNV".utf8)

    // Tablet → Mac
    static let hello: UInt8 = 0x01
    static let requestKeyframe: UInt8 = 0x02
    static let ping: UInt8 = 0x03
    static let bye: UInt8 = 0x04     // o usuário fechou o app no tablet
    static let pointer: UInt8 = 0x10
    static let scroll: UInt8 = 0x11

    // Mac → Tablet
    static let streamStart: UInt8 = 0x81
    static let codecConfig: UInt8 = 0x82
    static let frame: UInt8 = 0x83
    static let pong: UInt8 = 0x84
    static let status: UInt8 = 0x85  // texto exibido no tablet (ex.: falta permissão)

    static let codecH264: UInt8 = 0
    static let codecHEVC: UInt8 = 1

    static func packet(_ type: UInt8, _ payload: Data) -> Data {
        var d = Data(capacity: payload.count + 5)
        d.append(type)
        d.appendBE(UInt32(payload.count))
        d.append(payload)
        return d
    }
}

struct Hello {
    var width: Int
    var height: Int
    var refreshRate: Double
    var densityDpi: Int
    var supportsHEVC: Bool
    var diagonalInches: Double
    var deviceName: String
}

extension Data {
    mutating func appendBE(_ v: UInt16) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    mutating func appendBE(_ v: UInt32) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
    mutating func appendBE(_ v: UInt64) { Swift.withUnsafeBytes(of: v.bigEndian) { append(contentsOf: $0) } }
}

/// Leitor sequencial de payload.
struct Reader {
    let data: Data
    var offset: Int = 0
    init(_ data: Data) { self.data = data }

    var remaining: Int { data.count - offset }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw ProtoError.short }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }
    mutating func u16() throws -> UInt16 { UInt16(try u8()) << 8 | UInt16(try u8()) }
    mutating func u32() throws -> UInt32 { UInt32(try u16()) << 16 | UInt32(try u16()) }
    mutating func u64() throws -> UInt64 { UInt64(try u32()) << 32 | UInt64(try u32()) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func bytes(_ n: Int) throws -> Data {
        guard remaining >= n else { throw ProtoError.short }
        defer { offset += n }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + n))
    }
    mutating func rest() -> Data { (try? bytes(remaining)) ?? Data() }
}

enum ProtoError: Error { case short, badMagic, badVersion }

extension Hello {
    /// magic(4) version(u16) width(u32) height(u32) refresh(f32) dpi(u32)
    /// hevc(u8) diagonal(f32) nome(utf8 resto)
    static func parse(_ payload: Data) throws -> Hello {
        var r = Reader(payload)
        guard Array(try r.bytes(4)) == Proto.magic else { throw ProtoError.badMagic }
        guard try r.u16() == Proto.version else { throw ProtoError.badVersion }
        let w = Int(try r.u32()), h = Int(try r.u32())
        let hz = Double(try r.f32())
        let dpi = Int(try r.u32())
        let hevc = try r.u8() != 0
        let diag = Double(try r.f32())
        let name = String(data: r.rest(), encoding: .utf8) ?? "Tablet"
        return Hello(width: w, height: h, refreshRate: hz, densityDpi: dpi,
                     supportsHEVC: hevc, diagonalInches: diag, deviceName: name)
    }
}
