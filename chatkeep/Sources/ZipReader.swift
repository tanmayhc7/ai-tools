import Foundation
import Compression
import Darwin

struct ZipEntry: Equatable, Sendable {
    let name: String
    let flags: UInt16
    let method: UInt16
    let crc32: UInt32
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64

    var isDirectory: Bool { name.hasSuffix("/") }
    /// Last path component. Names are NEVER used as file paths: nothing is ever written to disk
    /// from an archive, so "../" tricks have nothing to act on.
    var baseName: String { (name as NSString).lastPathComponent }
    var isEncrypted: Bool { flags & 0x1 != 0 }
}

enum ZipError: LocalizedError, Equatable {
    case notAZip
    case truncated
    case encrypted(String)
    case unsupportedMethod(String, UInt16)
    case tooLarge(String)
    case corrupt(String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notAZip: return "This doesn't look like a zip file."
        case .truncated: return "The zip file is cut off. It may not have finished downloading."
        case .encrypted(let n): return "“\(n)” is password-protected. Unzip it first, then import the folder."
        case .unsupportedMethod(let n, let m): return "“\(n)” uses a compression method (\(m)) this app can't read."
        case .tooLarge(let n): return "“\(n)” expands to an unreasonable size and was stopped."
        case .corrupt(let d): return "The zip file is damaged (\(d))."
        case .unreadable(let d): return "Couldn't read the file: \(d)"
        }
    }
}

/// Minimal, defensive ZIP reader: random access with `pread`, streaming inflate, CRC checking.
/// Only what is needed to pull `conversations*.json` out of a chat export without ever loading
/// the (often multi-gigabyte) archive into memory.
final class ZipArchive: @unchecked Sendable {
    static let maxEntries = 200_000
    static let maxCentralDirectoryBytes: UInt64 = 256 * 1024 * 1024
    /// Hard stop for how much one entry may expand to.
    static let defaultMaxOutput: UInt64 = 8 << 30

    private let fd: Int32
    let size: UInt64
    private(set) var entries: [ZipEntry] = []

    init(path: String) throws {
        fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ZipError.unreadable(String(cString: strerror(errno))) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd); throw ZipError.unreadable("not a regular file")
        }
        size = UInt64(st.st_size)
        do { try loadDirectory() } catch { close(fd); throw error }
    }

    deinit { close(fd) }

    // MARK: Reading bytes

    private func read(at offset: UInt64, count: Int) throws -> [UInt8] {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else { throw ZipError.truncated }
        var out = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = out.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done)) }
            if n < 0 { if errno == EINTR { continue }; throw ZipError.unreadable(String(cString: strerror(errno))) }
            if n == 0 { throw ZipError.truncated }          // file shrank while reading
            done += n
        }
        return out
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { UInt16(b[o]) | UInt16(b[o + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(u16(b, o)) | UInt32(u16(b, o + 2)) << 16 }
    private static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32 }

    // MARK: Directory

    private func loadDirectory() throws {
        guard size >= 22 else { throw ZipError.notAZip }
        let tailLength = Int(min(size, 22 + 65_535))
        let tail = try read(at: size - UInt64(tailLength), count: tailLength)

        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06 {
                let commentLength = Int(Self.u16(tail, i + 20))
                if i + 22 + commentLength <= tail.count { eocd = i; break }
            }
            i -= 1
        }
        guard eocd >= 0 else {
            // A zip starts with a local header; anything else isn't one.
            let head = try read(at: 0, count: 4)
            if head == [0x50, 0x4B, 0x03, 0x04] { throw ZipError.truncated }
            throw ZipError.notAZip
        }

        var total = UInt64(Self.u16(tail, eocd + 10))
        var cdSize = UInt64(Self.u32(tail, eocd + 12))
        var cdOffset = UInt64(Self.u32(tail, eocd + 16))

        if total == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {      // ZIP64
            let eocdAbsolute = size - UInt64(tailLength) + UInt64(eocd)
            guard eocdAbsolute >= 20 else { throw ZipError.corrupt("zip64 locator missing") }
            let locator = try read(at: eocdAbsolute - 20, count: 20)
            guard Self.u32(locator, 0) == 0x0706_4B50 else { throw ZipError.corrupt("zip64 locator missing") }
            let z64Offset = Self.u64(locator, 8)
            let z64 = try read(at: z64Offset, count: 56)
            guard Self.u32(z64, 0) == 0x0606_4B50 else { throw ZipError.corrupt("zip64 record missing") }
            total = Self.u64(z64, 32); cdSize = Self.u64(z64, 40); cdOffset = Self.u64(z64, 48)
        }

        guard total <= UInt64(Self.maxEntries) else { throw ZipError.corrupt("too many entries") }
        guard cdSize <= Self.maxCentralDirectoryBytes, cdOffset <= size, cdSize <= size - cdOffset else {
            throw ZipError.corrupt("directory out of range")
        }
        let cd = try read(at: cdOffset, count: Int(cdSize))

        var p = 0
        var found: [ZipEntry] = []
        for _ in 0..<Int(total) {
            guard p + 46 <= cd.count, Self.u32(cd, p) == 0x0201_4B50 else { throw ZipError.corrupt("bad directory entry") }
            let flags = Self.u16(cd, p + 8)
            let method = Self.u16(cd, p + 10)
            let crc = Self.u32(cd, p + 16)
            var compressed = UInt64(Self.u32(cd, p + 20))
            var uncompressed = UInt64(Self.u32(cd, p + 24))
            let nameLength = Int(Self.u16(cd, p + 28)), extraLength = Int(Self.u16(cd, p + 30)), commentLength = Int(Self.u16(cd, p + 32))
            var localOffset = UInt64(Self.u32(cd, p + 42))
            let nameStart = p + 46
            guard nameStart + nameLength + extraLength + commentLength <= cd.count else { throw ZipError.corrupt("bad directory entry") }
            let name = String(decoding: cd[nameStart..<nameStart + nameLength], as: UTF8.self)

            // ZIP64 extended information: values appear only for fields that were 0xFFFFFFFF.
            var q = nameStart + nameLength
            let extraEnd = q + extraLength
            while q + 4 <= extraEnd {
                let id = Self.u16(cd, q), length = Int(Self.u16(cd, q + 2))
                guard q + 4 + length <= extraEnd else { break }
                if id == 0x0001 {
                    var r = q + 4
                    func next() -> UInt64? { guard r + 8 <= q + 4 + length else { return nil }; defer { r += 8 }; return Self.u64(cd, r) }
                    if uncompressed == 0xFFFF_FFFF, let v = next() { uncompressed = v }
                    if compressed == 0xFFFF_FFFF, let v = next() { compressed = v }
                    if localOffset == 0xFFFF_FFFF, let v = next() { localOffset = v }
                }
                q += 4 + length
            }
            found.append(ZipEntry(name: name, flags: flags, method: method, crc32: crc,
                                  compressedSize: compressed, uncompressedSize: uncompressed, localHeaderOffset: localOffset))
            p = nameStart + nameLength + extraLength + commentLength
        }
        entries = found
    }

    // MARK: Streaming an entry

    /// Streams the entry's decompressed bytes to `sink`. Verifies size and CRC at the end and throws
    /// if they don't match (after the data has been delivered, so callers can keep what they got).
    func stream(_ entry: ZipEntry, maxOutput: UInt64 = ZipArchive.defaultMaxOutput,
                isCancelled: () -> Bool = { false },
                sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        if entry.isEncrypted { throw ZipError.encrypted(entry.name) }
        guard entry.method == 0 || entry.method == 8 else { throw ZipError.unsupportedMethod(entry.name, entry.method) }
        if entry.uncompressedSize > maxOutput { throw ZipError.tooLarge(entry.name) }

        let header = try read(at: entry.localHeaderOffset, count: 30)
        guard Self.u32(header, 0) == 0x0403_4B50 else { throw ZipError.corrupt("bad local header") }
        let dataStart = entry.localHeaderOffset + 30 + UInt64(Self.u16(header, 26)) + UInt64(Self.u16(header, 28))
        guard dataStart <= size, entry.compressedSize <= size - dataStart else { throw ZipError.truncated }

        var crc = CRC32()
        var produced: UInt64 = 0
        let chunk = 1 << 20

        func emit(_ ptr: UnsafeRawBufferPointer) throws {
            produced += UInt64(ptr.count)
            if produced > maxOutput { throw ZipError.tooLarge(entry.name) }
            crc.update(ptr)
            try sink(ptr)
        }

        if entry.method == 0 {
            var offset = dataStart, left = entry.compressedSize
            while left > 0 {
                if isCancelled() { return }
                let n = Int(min(UInt64(chunk), left))
                let bytes = try read(at: offset, count: n)
                try bytes.withUnsafeBytes { try emit($0) }
                offset += UInt64(n); left -= UInt64(n)
            }
        } else {
            try inflate(entry: entry, dataStart: dataStart, chunk: chunk, isCancelled: isCancelled, emit: emit)
        }

        if isCancelled() { return }
        guard produced == entry.uncompressedSize else { throw ZipError.corrupt("“\(entry.name)” is the wrong size") }
        guard crc.value == entry.crc32 else { throw ZipError.corrupt("checksum mismatch in “\(entry.name)”") }
    }

    private func inflate(entry: ZipEntry, dataStart: UInt64, chunk: Int, isCancelled: () -> Bool,
                         emit: (UnsafeRawBufferPointer) throws -> Void) throws {
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ZipError.corrupt("can't start decompression")
        }
        defer { compression_stream_destroy(&stream) }

        var input = [UInt8](repeating: 0, count: chunk)
        var output = [UInt8](repeating: 0, count: chunk)
        var offset = dataStart, remaining = entry.compressedSize
        var stalls = 0

        try input.withUnsafeMutableBufferPointer { inPtr in
            try output.withUnsafeMutableBufferPointer { outPtr in
                stream.src_ptr = UnsafePointer(inPtr.baseAddress!); stream.src_size = 0
                stream.dst_ptr = outPtr.baseAddress!; stream.dst_size = chunk
                while true {
                    if isCancelled() { return }
                    if stream.src_size == 0, remaining > 0 {
                        let n = Int(min(UInt64(chunk), remaining))
                        let bytes = try read(at: offset, count: n)
                        bytes.withUnsafeBufferPointer { inPtr.baseAddress!.update(from: $0.baseAddress!, count: n) }
                        stream.src_ptr = UnsafePointer(inPtr.baseAddress!); stream.src_size = n
                        offset += UInt64(n); remaining -= UInt64(n)
                    }
                    let finalize = remaining == 0
                    let before = stream.src_size
                    let status = compression_stream_process(&stream, finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    let have = chunk - stream.dst_size
                    if have > 0 {
                        try emit(UnsafeRawBufferPointer(start: outPtr.baseAddress!, count: have))
                        stream.dst_ptr = outPtr.baseAddress!; stream.dst_size = chunk
                    }
                    switch status {
                    case COMPRESSION_STATUS_END: return
                    case COMPRESSION_STATUS_ERROR: throw ZipError.corrupt("“\(entry.name)” won't decompress")
                    default:
                        // OK but no progress at all means the compressed data ended early.
                        if have == 0, stream.src_size == before { stalls += 1 } else { stalls = 0 }
                        if finalize, stalls > 2 { throw ZipError.corrupt("“\(entry.name)” ends early") }
                    }
                }
            }
        }
    }

    /// Convenience for small entries and tests.
    func read(_ entry: ZipEntry, maxBytes: Int = 64 << 20) throws -> Data {
        var data = Data()
        try stream(entry, maxOutput: UInt64(maxBytes)) { data.append(contentsOf: $0) }
        return data
    }
}

struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
    private var state: UInt32 = 0xFFFF_FFFF
    var value: UInt32 { state ^ 0xFFFF_FFFF }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var c = state
        CRC32.table.withUnsafeBufferPointer { t in
            for b in bytes { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        state = c
    }
}
