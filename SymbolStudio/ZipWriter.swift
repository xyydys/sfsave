import Foundation

/// Writes a plain ZIP file (entries stored, not compressed) straight to disk.
/// PNG is already compressed and the SVGs are small, so this keeps the
/// writer short and the memory use flat. ZIP64 is not supported; a file or
/// archive over 4 GB or more than 65,535 entries is refused.
final class ZipWriter {
    private struct Entry {
        let name: [UInt8]
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    let url: URL
    private let handle: FileHandle
    private var entries: [Entry] = []
    private var paths = Set<String>()
    private var offset: UInt64 = 0
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw StudioError.export("无法创建压缩包：\(url.lastPathComponent)")
        }
        handle = try FileHandle(forWritingTo: url)
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let year = min(max((parts.year ?? 1980) - 1980, 0), 127)
        dosDate = UInt16(year << 9 | (parts.month ?? 1) << 5 | (parts.day ?? 1))
        dosTime = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | (parts.second ?? 0) / 2)
    }

    var entryCount: Int { entries.count }

    func contains(_ path: String) -> Bool { paths.contains(path.lowercased()) }

    func add(path: String, data: Data) throws {
        let name = Array(path.utf8)
        guard entries.count < 65_535, name.count < 65_535, data.count < Int(UInt32.max) - 1,
              offset < UInt64(UInt32.max) - UInt64(data.count) - 1_000_000 else {
            throw StudioError.export("压缩包太大，请把方案拆成几份再导出。")
        }
        guard paths.insert(path.lowercased()).inserted else {
            throw StudioError.export("压缩包里已经有同名文件：\(path)")
        }
        let crc = Self.crc32(data)
        var header = Data()
        header.append32(0x0403_4b50)
        header.append16(20)
        header.append16(0x0800)            // UTF-8 names
        header.append16(0)                 // stored
        header.append16(dosTime)
        header.append16(dosDate)
        header.append32(crc)
        header.append32(UInt32(data.count))
        header.append32(UInt32(data.count))
        header.append16(UInt16(name.count))
        header.append16(0)
        header.append(contentsOf: name)
        let start = UInt32(offset)
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: data)
        offset += UInt64(header.count + data.count)
        entries.append(Entry(name: name, crc: crc, size: UInt32(data.count), offset: start))
    }

    func finish() throws {
        let directoryStart = UInt32(offset)
        var directory = Data()
        for entry in entries {
            directory.append32(0x0201_4b50)
            directory.append16(20)
            directory.append16(20)
            directory.append16(0x0800)
            directory.append16(0)
            directory.append16(dosTime)
            directory.append16(dosDate)
            directory.append32(entry.crc)
            directory.append32(entry.size)
            directory.append32(entry.size)
            directory.append16(UInt16(entry.name.count))
            directory.append16(0)          // extra
            directory.append16(0)          // comment
            directory.append16(0)          // disk
            directory.append16(0)          // internal attributes
            directory.append32(0)          // external attributes
            directory.append32(entry.offset)
            directory.append(contentsOf: entry.name)
        }
        let directorySize = UInt32(directory.count)
        directory.append32(0x0605_4b50)
        directory.append16(0)
        directory.append16(0)
        directory.append16(UInt16(entries.count))
        directory.append16(UInt16(entries.count))
        directory.append32(directorySize)
        directory.append32(directoryStart)
        directory.append16(0)
        try handle.write(contentsOf: directory)
        try handle.close()
    }

    func cancel() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append16(_ value: UInt16) {
        append(UInt8(value & 0xFF)); append(UInt8(value >> 8))
    }

    mutating func append32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }
}
