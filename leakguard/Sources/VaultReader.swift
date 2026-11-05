import Foundation

/// Read-only access to a KeyVault vault, so LeakGuard can check whether any of your
/// stored keys appear in a project. Secrets are held in memory only for one scan.
enum VaultReader {
    static var vaultURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KeyVault", isDirectory: true)
        .appendingPathComponent("vault.json")

    /// KeyVault's own preferences, so a wrong password here counts toward KeyVault's lockout
    /// (otherwise LeakGuard would be a way around it). Replaceable in tests.
    static var lockoutDefaults: UserDefaults? = UserDefaults(suiteName: "local.keyvault.app")

    static var exists: Bool { FileManager.default.fileExists(atPath: vaultURL.path) }

    private struct Entry: Decodable { let name: String; let secret: String }
    private struct Contents: Decodable { let entries: [Entry] }

    static func readSecrets(password: String) throws -> [VaultSecret] {
        let defaults = lockoutDefaults
        let until = defaults?.double(forKey: "unlockBlockedUntil") ?? 0
        if until > Date().timeIntervalSince1970 {
            throw VaultError.throttled(seconds: Int((until - Date().timeIntervalSince1970).rounded(.up)))
        }
        do {
            let secrets = try decrypt(password: password)
            defaults?.set(0, forKey: "failedUnlocks")
            defaults?.set(0, forKey: "unlockBlockedUntil")
            return secrets
        } catch VaultError.wrongPassword {
            let n = (defaults?.integer(forKey: "failedUnlocks") ?? 0) + 1
            defaults?.set(n, forKey: "failedUnlocks")
            if n >= 3 {   // same schedule as KeyVault: 5 s, 10 s, 20 s … capped at 5 min
                defaults?.set(Date().timeIntervalSince1970 + min(5 * pow(2, Double(n - 3)), 300), forKey: "unlockBlockedUntil")
            }
            throw VaultError.wrongPassword
        }
    }

    private static func decrypt(password: String) throws -> [VaultSecret] {
        let attrs = try FileManager.default.attributesOfItem(atPath: vaultURL.path)
        guard (attrs[.size] as? Int ?? 0) <= 32 * 1024 * 1024 else { throw VaultError.corrupted }
        let data = try Data(contentsOf: vaultURL)
        guard let file = try? JSONDecoder().decode(VaultFile.self, from: data) else { throw VaultError.corrupted }
        let salt = try VaultCrypto.salt(of: file)

        let plaintext: Data
        do {
            let key = try VaultCrypto.deriveKey(password: password, salt: salt, iterations: file.iterations)
            plaintext = try VaultCrypto.open(file, key: key)
        } catch VaultError.wrongPassword where password.precomposedStringWithCanonicalMapping != password {
            let key = try VaultCrypto.deriveKey(password: password, salt: salt,
                                                iterations: file.iterations, normalize: false)
            plaintext = try VaultCrypto.open(file, key: key)
        }
        guard let contents = try? JSONDecoder().decode(Contents.self, from: plaintext) else {
            throw VaultError.corrupted
        }
        return contents.entries.map { VaultSecret(name: $0.name, secret: $0.secret) }
    }
}
