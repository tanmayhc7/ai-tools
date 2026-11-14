import Foundation
import CryptoKit

struct ArchiveHeader: Codable, Equatable {
    var format: String
    var kdf: String
    var iterations: UInt32
    var salt: String            // base64, 16+ random bytes
    var cipher: String
    var chunkSize: Int
    var chunks: Int
    var plainLength: Int
}

/// On-disk format for the encrypted archive:
///
///     "CKA1\n"  header-JSON  "\n"  { u32 length (big endian) | AES-GCM nonce+ciphertext+tag }  …
///
/// The payload is split into chunks so that very large archives don't need one giant encryption
/// operation. Every chunk is authenticated with associated data made of the exact header bytes,
/// the chunk's position, and whether it is the last one. So editing the header, reordering,
/// duplicating, dropping or appending chunks, or cutting the file short all make decryption fail.
enum ArchiveCrypto {
    static let format = "chatkeep-1"
    static let kdfName = "PBKDF2-HMAC-SHA256"
    static let cipherName = "AES-256-GCM"
    static let magic = Data("CKA1\n".utf8)
    static let defaultChunkSize = 16 << 20
    static let overhead = 12 + 16            // nonce + tag
    static let maxHeaderBytes = 4096

    private static func associatedData(header: Data, index: Int, isFinal: Bool) -> Data {
        var aad = header
        withUnsafeBytes(of: UInt64(index).bigEndian) { aad.append(contentsOf: $0) }
        aad.append(isFinal ? 1 : 0)
        return aad
    }

    // MARK: Header

    static func parseHeader(_ file: Data) throws -> (header: ArchiveHeader, headerBytes: Data, bodyOffset: Int) {
        guard file.count > magic.count, file.prefix(magic.count) == magic else { throw VaultError.unsupportedFormat }
        let start = file.startIndex + magic.count
        let searchEnd = min(file.endIndex, start + maxHeaderBytes + 1)
        guard let newline = file[start..<searchEnd].firstIndex(of: 0x0A) else { throw VaultError.corrupted }
        let headerBytes = file[start..<newline]
        guard let header = try? JSONDecoder().decode(ArchiveHeader.self, from: headerBytes) else { throw VaultError.corrupted }

        guard header.format == format, header.kdf == kdfName, header.cipher == cipherName,
              header.iterations >= VaultCrypto.minimumIterations, header.iterations <= VaultCrypto.maximumIterations,
              (1024...(64 << 20)).contains(header.chunkSize),
              header.plainLength >= 0, header.chunks >= 1,
              header.chunks == max(1, (header.plainLength + header.chunkSize - 1) / header.chunkSize),
              let salt = Data(base64Encoded: header.salt), salt.count >= 16 else { throw VaultError.unsupportedFormat }
        return (header, Data(headerBytes), newline + 1 - file.startIndex)
    }

    static func salt(of header: ArchiveHeader) throws -> Data {
        guard let s = Data(base64Encoded: header.salt), s.count >= 16 else { throw VaultError.corrupted }
        return s
    }

    // MARK: Seal

    static func seal(_ plaintext: Data, key: SymmetricKey, salt: Data, iterations: UInt32,
                     chunkSize: Int = defaultChunkSize) throws -> Data {
        precondition((1024...(64 << 20)).contains(chunkSize))
        let chunks = max(1, (plaintext.count + chunkSize - 1) / chunkSize)
        let header = ArchiveHeader(format: format, kdf: kdfName, iterations: iterations, salt: salt.base64EncodedString(),
                                   cipher: cipherName, chunkSize: chunkSize, chunks: chunks, plainLength: plaintext.count)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let headerBytes = try encoder.encode(header)

        var out = Data()
        out.reserveCapacity(plaintext.count + chunks * (overhead + 4) + headerBytes.count + 16)
        out.append(magic); out.append(headerBytes); out.append(0x0A)
        for i in 0..<chunks {
            let lower = plaintext.startIndex + i * chunkSize
            let upper = min(plaintext.endIndex, lower + chunkSize)
            let box = try AES.GCM.seal(plaintext[lower..<upper], using: key,
                                       authenticating: associatedData(header: headerBytes, index: i, isFinal: i == chunks - 1))
            guard let combined = box.combined else { throw VaultError.corrupted }
            withUnsafeBytes(of: UInt32(combined.count).bigEndian) { out.append(contentsOf: $0) }
            out.append(combined)
        }
        return out
    }

    // MARK: Open

    static func open(_ file: Data, key: SymmetricKey) throws -> Data {
        let (header, headerBytes, bodyOffset) = try parseHeader(file)
        var plain = Data()
        plain.reserveCapacity(header.plainLength)
        var cursor = file.startIndex + bodyOffset

        for i in 0..<header.chunks {
            guard cursor + 4 <= file.endIndex else { throw VaultError.corrupted }
            let length = file[cursor..<cursor + 4].reduce(0) { ($0 << 8) | Int($1) }
            cursor += 4
            let isFinal = i == header.chunks - 1
            let expectedPlain = isFinal ? header.plainLength - (header.chunks - 1) * header.chunkSize : header.chunkSize
            guard length == expectedPlain + overhead, cursor + length <= file.endIndex else { throw VaultError.corrupted }
            do {
                let box = try AES.GCM.SealedBox(combined: file[cursor..<cursor + length])
                plain.append(try AES.GCM.open(box, using: key, authenticating: associatedData(header: headerBytes, index: i, isFinal: isFinal)))
            } catch {
                // The first chunk failing is what a wrong password looks like; later failures mean damage.
                throw i == 0 ? VaultError.wrongPassword : VaultError.corrupted
            }
            cursor += length
        }
        guard cursor == file.endIndex else { throw VaultError.corrupted }      // nothing may follow the last chunk
        return plain
    }
}
