import Foundation
import CryptoKit
import CommonCrypto
import Security

/// On-disk vault format. Only the salt and KDF parameters are stored in the clear;
/// every entry lives inside the AES-256-GCM encrypted payload.
struct VaultFile: Codable {
    var format: String       // "keyvault-1"
    var kdf: String          // "PBKDF2-HMAC-SHA256"
    var iterations: UInt32
    var salt: String         // base64, 16 random bytes
    var cipher: String       // "AES-256-GCM"
    var payload: String      // base64(nonce || ciphertext || tag)
}

enum VaultError: LocalizedError {
    case wrongPassword, corrupted, kdfFailed, randomFailed, unsupportedFormat, locked
    case throttled(seconds: Int)
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .wrongPassword:     return "Incorrect master password."
        case .corrupted:         return "The vault file is damaged or unreadable. You can restore a backup."
        case .throttled(let s):  return "Too many failed attempts. Try again in \(s)s."
        case .alreadyRunning:    return "KeyVault is already open."
        case .kdfFailed:         return "Key derivation failed."
        case .randomFailed:      return "The system random number generator failed."
        case .unsupportedFormat: return "This vault file uses an unsupported format."
        case .locked:            return "The vault is locked."
        }
    }
}

enum VaultCrypto {
    static let format = "keyvault-1"
    static let kdfName = "PBKDF2-HMAC-SHA256"
    static let cipherName = "AES-256-GCM"
    /// OWASP 2023+ recommendation for PBKDF2-HMAC-SHA256.
    static let defaultIterations: UInt32 = 600_000
    static let minimumIterations: UInt32 = 100_000
    /// Upper bound so a tampered file can't make unlock hang for hours.
    static let maximumIterations: UInt32 = 20_000_000
    /// Vaults below this are re-encrypted with a calibrated count on next unlock.
    static let upgradeThreshold: UInt32 = 1_000_000

    /// Picks an iteration count that takes about `target` seconds on this Mac
    /// (never below the OWASP minimum), so offline guessing is as slow as is comfortable.
    static func calibratedIterations(target: TimeInterval = 0.5) -> UInt32 {
        let probe: UInt32 = 100_000
        guard let salt = try? randomBytes(16) else { return defaultIterations }
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try? deriveKey(password: "calibration", salt: salt, iterations: probe)
        let elapsed = max(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, 0.001)
        let estimate = (Double(probe) * target / elapsed / 100_000).rounded() * 100_000
        return UInt32(min(max(estimate, Double(defaultIterations)), 5_000_000))
    }

    static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw VaultError.randomFailed }
        return data
    }

    /// Stretches the master password into a 256-bit AES key.
    /// Passwords are Unicode-normalised (NFC) first, so "é" typed as one character or as
    /// "e" + accent derives the same key regardless of keyboard or input method.
    static func deriveKey(password rawPassword: String, salt: Data, iterations: UInt32,
                          normalize: Bool = true) throws -> SymmetricKey {
        guard iterations >= minimumIterations, iterations <= maximumIterations else {
            throw VaultError.unsupportedFormat
        }
        let password = normalize ? rawPassword.precomposedStringWithCanonicalMapping : rawPassword
        var derived = [UInt8](repeating: 0, count: 32)
        defer { _ = derived.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }

        let passwordLength = password.utf8.count
        let status = salt.withUnsafeBytes { (saltBuf: UnsafeRawBufferPointer) -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password, passwordLength,
                saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                iterations,
                &derived, derived.count)
        }
        guard status == Int32(kCCSuccess) else { throw VaultError.kdfFailed }
        return SymmetricKey(data: derived)
    }

    /// Header fields are bound to the ciphertext as associated data, so editing
    /// the salt or iteration count in the file makes decryption fail.
    private static func associatedData(iterations: UInt32, salt: String) -> Data {
        Data("\(format)|\(kdfName)|\(iterations)|\(salt)|\(cipherName)".utf8)
    }

    static func seal(_ plaintext: Data, key: SymmetricKey, salt: Data, iterations: UInt32) throws -> VaultFile {
        let saltB64 = salt.base64EncodedString()
        let box = try AES.GCM.seal(plaintext, using: key,
                                   authenticating: associatedData(iterations: iterations, salt: saltB64))
        guard let combined = box.combined else { throw VaultError.corrupted }
        return VaultFile(format: format, kdf: kdfName, iterations: iterations,
                         salt: saltB64, cipher: cipherName,
                         payload: combined.base64EncodedString())
    }

    static func open(_ file: VaultFile, key: SymmetricKey) throws -> Data {
        guard file.format == format, file.kdf == kdfName, file.cipher == cipherName,
              file.iterations >= minimumIterations,
              file.iterations <= maximumIterations else { throw VaultError.unsupportedFormat }
        guard let combined = Data(base64Encoded: file.payload),
              let box = try? AES.GCM.SealedBox(combined: combined) else { throw VaultError.corrupted }
        do {
            return try AES.GCM.open(box, using: key,
                                    authenticating: associatedData(iterations: file.iterations, salt: file.salt))
        } catch {
            // GCM authentication failed: wrong key or tampered file.
            throw VaultError.wrongPassword
        }
    }

    static func salt(of file: VaultFile) throws -> Data {
        guard let salt = Data(base64Encoded: file.salt), salt.count >= 16 else { throw VaultError.corrupted }
        return salt
    }
}
