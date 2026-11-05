import Foundation

// Shared helper (identical copy in leakguard/ and contextpack/).

enum SafeRead {
    /// Reads a file only if it is a regular file, without following symlinks and without
    /// blocking. Checking first and reading later would leave a gap in which the file could
    /// be swapped for a symlink (escaping the folder) or a named pipe (hanging the scan
    /// forever); opening once and checking the open handle closes that gap.
    static func regularFile(at path: String, maxBytes: Int) -> Data? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(info.st_size)
        guard size <= maxBytes else { return nil }
        guard size > 0 else { return Data() }

        var data = Data(count: size)
        var total = 0
        let ok = data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Bool in
            while total < size {
                let n = read(fd, buf.baseAddress! + total, size - total)
                if n == 0 { break }          // file shrank while reading
                if n < 0 { return errno == EINTR ? true : false }
                total += n
            }
            return true
        }
        guard ok else { return nil }
        data.count = total
        return data
    }
}
