// SMC.swift
// AppleSMC (System Management Controller) への IOKit 経由アクセス。
//
// 参考にした実装: vladkens/macmon (sources.rs), beltex/SMCKit, hholtmann/smcFanControl,
// agoodkind/macos-smc-fan (Apple Silicon のファン書き込み手順)。
//
// ・読み取りは root 不要。書き込みは root 必須 (thermalctl から使う)。
// ・Apple Silicon: "flt " は 4 バイト little-endian float。整数系 (ui8/ui16/ui32) は big-endian。
// ・Intel:         温度は "sp78" (符号付き 7.8 固定小数)、ファンは "fpe2" (14.2 固定小数)。

import Foundation

// MARK: - エラー

public enum SMCError: Error, CustomStringConvertible, Equatable {
    case serviceNotFound
    case openFailed(Int32)
    case callFailed(Int32)
    case keyNotFound(String)
    case writeBlocked(String)        // result 0x82: thermalmonitord 等により拒否
    case smcResult(UInt8, String)
    case invalidKey(String)
    case unsupportedType(String, String)

    public var description: String {
        switch self {
        case .serviceNotFound: return "AppleSMC サービスが見つかりません (仮想マシン?)"
        case .openFailed(let r): return "IOServiceOpen 失敗: \(r)"
        case .callFailed(let r): return "IOConnectCallStructMethod 失敗: \(r)"
        case .keyNotFound(let k): return "SMC キー '\(k)' は存在しません"
        case .writeBlocked(let k): return "SMC キー '\(k)' への書き込みが拒否されました (0x82)"
        case .smcResult(let code, let k): return "SMC エラー 0x\(String(code, radix: 16)) (key \(k))"
        case .invalidKey(let k): return "SMC キーは 4 文字です: '\(k)'"
        case .unsupportedType(let k, let t): return "未対応の SMC 型 '\(t)' (key \(k))"
        }
    }
}

#if canImport(IOKit)
import IOKit

// MARK: - C 互換レイアウト (AppleSMC の SMCKeyData_t と同じ 80 バイト)

struct SMCKeyDataVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCKeyDataPLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

public struct SMCKeyInfo: Equatable {
    public var dataSize: UInt32 = 0
    public var dataType: UInt32 = 0
    public var dataAttributes: UInt8 = 0

    public init(dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0) {
        self.dataSize = dataSize
        self.dataType = dataType
        self.dataAttributes = dataAttributes
    }

    /// FourCC の文字列表現 ("flt ", "sp78" など)
    public var typeString: String { SMC.fourCCString(dataType) }
}

struct SMCKeyData {
    // AppleSMC の SMCKeyData_t と同じ 80 バイト。Swift はネストした構造体の末尾パディングを
    // 再利用して詰めることがあるため、keyInfo はフラットに展開し、パディングを明示する。
    var key: UInt32 = 0                 // 0
    var vers = SMCKeyDataVersion()      // 4  (6 bytes)
    var pLimitData = SMCKeyDataPLimit() // 12 (16 bytes)
    var keyInfoDataSize: UInt32 = 0     // 28
    var keyInfoDataType: UInt32 = 0     // 32
    var keyInfoDataAttributes: UInt8 = 0 // 36
    var pad0: UInt8 = 0                 // 37
    var pad1: UInt8 = 0                 // 38
    var pad2: UInt8 = 0                 // 39
    var result: UInt8 = 0               // 40
    var status: UInt8 = 0               // 41
    var data8: UInt8 = 0                // 42
    var pad3: UInt8 = 0                 // 43
    var data32: UInt32 = 0              // 44
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = // 48 (32 bytes) -> 80
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    static let expectedSize = 80

    var keyInfo: SMCKeyInfo {
        get { SMCKeyInfo(dataSize: keyInfoDataSize, dataType: keyInfoDataType, dataAttributes: keyInfoDataAttributes) }
        set {
            keyInfoDataSize = newValue.dataSize
            keyInfoDataType = newValue.dataType
            keyInfoDataAttributes = newValue.dataAttributes
        }
    }

    var byteArray: [UInt8] {
        withUnsafeBytes(of: bytes) { Array($0) }
    }

    mutating func setBytes(_ array: [UInt8]) {
        withUnsafeMutableBytes(of: &bytes) { raw in
            for (i, b) in array.prefix(32).enumerated() { raw[i] = b }
        }
    }
}

// MARK: - SMC 接続

/// AppleSMC への接続。スレッドセーフではないので、呼び出し側で直列化すること。
public final class SMC {
    private var connection: io_connect_t = 0
    private var keyInfoCache: [UInt32: SMCKeyInfo] = [:]

    // AppleSMC のセレクタ / コマンド (smcFanControl 由来)
    private static let selectorHandleYPCEvent: UInt32 = 2
    private static let cmdReadKey: UInt8 = 5
    private static let cmdWriteKey: UInt8 = 6
    private static let cmdGetKeyFromIndex: UInt8 = 8
    private static let cmdGetKeyInfo: UInt8 = 9

    public static let resultKeyNotFound: UInt8 = 0x84
    public static let resultWriteBlocked: UInt8 = 0x82

    public init() throws {
        precondition(MemoryLayout<SMCKeyData>.size == SMCKeyData.expectedSize,
                     "SMCKeyData のレイアウトが AppleSMC と一致しません (\(MemoryLayout<SMCKeyData>.size) bytes)")
        let matching = IOServiceMatching("AppleSMC")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            throw SMCError.serviceNotFound
        }
        defer { IOObjectRelease(iterator) }

        var opened = false
        var device = IOIteratorNext(iterator)
        while device != 0 {
            defer { IOObjectRelease(device); device = IOIteratorNext(iterator) }
            // macmon と同じく、ユーザークライアントは AppleSMCKeysEndpoint を優先。
            // 古い Intel 機ではサービス名が AppleSMC のみなので、それも受け付ける。
            var nameBuf = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(device, &nameBuf)
            let name = String(cString: nameBuf)
            if name == "AppleSMCKeysEndpoint" || name == "AppleSMC" {
                let kr = IOServiceOpen(device, mach_task_self_, 0, &connection)
                if kr == KERN_SUCCESS {
                    opened = true
                    break
                } else if name == "AppleSMCKeysEndpoint" {
                    throw SMCError.openFailed(kr)
                }
            }
        }
        guard opened else { throw SMCError.serviceNotFound }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    // MARK: 低レベル呼び出し

    private func call(_ input: SMCKeyData, keyName: String) throws -> SMCKeyData {
        var input = input
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride
        let kr = IOConnectCallStructMethod(
            connection,
            Self.selectorHandleYPCEvent,
            &input,
            MemoryLayout<SMCKeyData>.stride,
            &output,
            &outputSize
        )
        guard kr == KERN_SUCCESS else { throw SMCError.callFailed(kr) }
        switch output.result {
        case 0: return output
        case Self.resultKeyNotFound: throw SMCError.keyNotFound(keyName)
        case Self.resultWriteBlocked: throw SMCError.writeBlocked(keyName)
        default: throw SMCError.smcResult(output.result, keyName)
        }
    }

    // MARK: キー名 <-> UInt32

    public static func fourCC(_ key: String) throws -> UInt32 {
        let bytes = Array(key.utf8)
        guard bytes.count == 4 else { throw SMCError.invalidKey(key) }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    public static func fourCCString(_ value: UInt32) -> String {
        let bytes = [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: 公開 API

    /// キーのメタ情報 (サイズ・型)。存在チェックにも使う。
    public func keyInfo(_ key: String) throws -> SMCKeyInfo {
        let id = try Self.fourCC(key)
        if let cached = keyInfoCache[id] { return cached }
        var input = SMCKeyData()
        input.key = id
        input.data8 = Self.cmdGetKeyInfo
        let out = try call(input, keyName: key)
        keyInfoCache[id] = out.keyInfo
        return out.keyInfo
    }

    public func hasKey(_ key: String) -> Bool {
        (try? keyInfo(key)) != nil
    }

    /// 生バイト列を読む。
    public func readBytes(_ key: String) throws -> (info: SMCKeyInfo, bytes: [UInt8]) {
        let info = try keyInfo(key)
        var input = SMCKeyData()
        input.key = try Self.fourCC(key)
        input.keyInfo = info
        input.data8 = Self.cmdReadKey
        let out = try call(input, keyName: key)
        return (info, Array(out.byteArray.prefix(Int(info.dataSize))))
    }

    /// 型を見て Double に変換して読む (温度・RPM・フラグ等の汎用読み取り)。
    public func readDouble(_ key: String) throws -> Double {
        let (info, bytes) = try readBytes(key)
        guard let value = SMC.decode(bytes: bytes, type: info.typeString) else {
            throw SMCError.unsupportedType(key, info.typeString)
        }
        return value
    }

    /// 生バイト列を書く。root 権限が必要。
    public func writeBytes(_ key: String, _ bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        var input = SMCKeyData()
        input.key = try Self.fourCC(key)
        input.keyInfo = info
        input.data8 = Self.cmdWriteKey
        input.setBytes(bytes)
        _ = try call(input, keyName: key)
    }

    /// 型に合わせてエンコードして書く。
    public func writeDouble(_ key: String, _ value: Double) throws {
        let info = try keyInfo(key)
        guard let bytes = SMC.encode(value: value, type: info.typeString, size: Int(info.dataSize)) else {
            throw SMCError.unsupportedType(key, info.typeString)
        }
        try writeBytes(key, bytes)
    }

    /// 全キー数 ("#KEY")
    public func keyCount() throws -> Int {
        let (_, bytes) = try readBytes("#KEY")
        return Int(SMC.bigEndianUInt(bytes))
    }

    /// インデックスからキー名を得る。
    public func keyName(at index: Int) throws -> String {
        var input = SMCKeyData()
        input.data8 = Self.cmdGetKeyFromIndex
        input.data32 = UInt32(index)
        let out = try call(input, keyName: "#\(index)")
        return Self.fourCCString(out.key)
    }

    /// 全キーを列挙 (診断用。数千キーあるので数秒かかる)。
    public func allKeys() throws -> [String] {
        let count = try keyCount()
        var keys: [String] = []
        keys.reserveCapacity(count)
        for i in 0..<count {
            if let k = try? keyName(at: i) { keys.append(k) }
        }
        return keys
    }
}
#endif

// MARK: - 型のデコード / エンコード (プラットフォーム非依存。テスト対象)

extension SMC {
    static func bigEndianUInt(_ bytes: [UInt8]) -> UInt64 {
        bytes.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// SMC の FourCC 型を Double に変換する。未知の型は nil。
    public static func decode(bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        case "fp88":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 256.0
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 256.0
        case "sp87":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / 128.0
        case "ui8 ", "flag", "ui16", "ui32", "ui64":
            guard !bytes.isEmpty else { return nil }
            return Double(bigEndianUInt(bytes))
        case "si8 ":
            guard let b = bytes.first else { return nil }
            return Double(Int8(bitPattern: b))
        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
        case "ioft":
            // 48.16 固定小数 (Intel の一部の電力キー)
            guard bytes.count >= 8 else { return nil }
            return Double(bigEndianUInt(bytes)) / 65536.0
        default:
            return nil
        }
    }

    /// Double を SMC 型にエンコードする。
    public static func encode(value: Double, type: String, size: Int) -> [UInt8]? {
        switch type {
        case "flt ":
            let raw = Float(value).bitPattern
            return [UInt8(raw & 0xff), UInt8(raw >> 8 & 0xff), UInt8(raw >> 16 & 0xff), UInt8(raw >> 24 & 0xff)]
        case "fpe2":
            let raw = UInt16(max(0, min(16383, value)) * 4)
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "ui8 ", "flag":
            return [UInt8(max(0, min(255, value)))]
        case "ui16":
            let raw = UInt16(max(0, min(65535, value)))
            return [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "ui32":
            let raw = UInt32(max(0, min(Double(UInt32.max), value)))
            return [UInt8(raw >> 24 & 0xff), UInt8(raw >> 16 & 0xff), UInt8(raw >> 8 & 0xff), UInt8(raw & 0xff)]
        default:
            _ = size
            return nil
        }
    }
}

#if !canImport(IOKit)
/// Linux などでテストをビルドするためのプレースホルダ。デコード/エンコードの static 関数のみ使える。
public enum SMC {}
#endif
