import Compression
import Foundation

/// Reads a ZIP archive held in memory: stored and deflated entries, found
/// through the central directory. ZIP64 and encrypted entries are refused.
struct ZipReader {
    struct Entry {
        let path: String
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let headerOffset: Int
        var isDirectory: Bool { path.hasSuffix("/") }
    }

    let data: Data
    let entries: [Entry]

    init(data: Data) throws {
        self.data = data
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

        // The end-of-central-directory record sits in the last 64 KB + 22 bytes.
        guard bytes.count >= 22 else { throw StudioError.resource("不是 zip 文件：文件太短。") }
        var end = -1
        var at = bytes.count - 22
        while at >= max(0, bytes.count - 22 - 65_535) {
            if u32(at) == 0x0605_4b50 { end = at; break }
            at -= 1
        }
        guard end >= 0 else { throw StudioError.resource("不是 zip 文件：找不到目录。") }
        let count = u16(end + 10)
        let directory = u32(end + 16)
        guard count != 0xFFFF, directory != 0xFFFF_FFFF else {
            throw StudioError.resource("这个 zip 用了 ZIP64 格式，暂不支持。")
        }

        var entries: [Entry] = []
        var cursor = directory
        for _ in 0..<count {
            guard cursor + 46 <= bytes.count, u32(cursor) == 0x0201_4b50 else {
                throw StudioError.resource("zip 目录损坏。")
            }
            let flags = u16(cursor + 8)
            let nameLength = u16(cursor + 28), extraLength = u16(cursor + 30), commentLength = u16(cursor + 32)
            guard cursor + 46 + nameLength <= bytes.count else { throw StudioError.resource("zip 目录损坏。") }
            let nameBytes = Array(bytes[(cursor + 46)..<(cursor + 46 + nameLength)])
            let path = String(decoding: nameBytes, as: UTF8.self)
            if flags & 1 != 0 { throw StudioError.resource("zip 里的文件加了密码，无法读取：\(path)") }
            entries.append(Entry(path: path, method: UInt16(u16(cursor + 10)), crc: UInt32(u32(cursor + 16)),
                                 compressedSize: u32(cursor + 20), size: u32(cursor + 24),
                                 headerOffset: u32(cursor + 42)))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    func entry(_ path: String) -> Entry? { entries.first { $0.path == path } }

    func read(_ entry: Entry) throws -> Data {
        let start = entry.headerOffset
        guard start + 30 <= data.count else { throw StudioError.resource("zip 文件损坏：\(entry.path)") }
        let header = data.subdata(in: start..<(start + 30))
        let nameLength = Int(header[26]) | Int(header[27]) << 8
        let extraLength = Int(header[28]) | Int(header[29]) << 8
        let body = start + 30 + nameLength + extraLength
        guard body + entry.compressedSize <= data.count else { throw StudioError.resource("zip 文件损坏：\(entry.path)") }
        let packed = data.subdata(in: body..<(body + entry.compressedSize))

        let output: Data
        switch entry.method {
        case 0:
            output = packed
        case 8:
            output = try Self.inflate(packed, size: entry.size, path: entry.path)
        default:
            throw StudioError.resource("zip 里的文件用了不支持的压缩方式（\(entry.method)）：\(entry.path)")
        }
        guard ZipWriter.crc32(output) == entry.crc else { throw StudioError.resource("zip 文件校验失败：\(entry.path)") }
        return output
    }

    /// Raw DEFLATE, which is what `COMPRESSION_ZLIB` decodes.
    private static func inflate(_ packed: Data, size: Int, path: String) throws -> Data {
        if size == 0 { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) -> Int in
            packed.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let to = target.bindMemory(to: UInt8.self).baseAddress,
                      let from = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(to, size, from, packed.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw StudioError.resource("zip 解压失败：\(path)") }
        return output
    }
}
