import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS  \(name)" : "FAIL  \(name)")
    if !ok { failures += 1 }
}

let salt = try VaultCrypto.randomBytes(16)
let iters = VaultCrypto.defaultIterations
let secret = Data(#"{"entries":[{"secret":"sk-test-123"}]}"#.utf8)

let start = Date()
let key = try VaultCrypto.deriveKey(password: "correct horse battery", salt: salt, iterations: iters)
print(String(format: "      PBKDF2 x%d took %.2fs", iters, Date().timeIntervalSince(start)))

let file = try VaultCrypto.seal(secret, key: key, salt: salt, iterations: iters)
check(try VaultCrypto.open(file, key: key) == secret, "round trip decrypts")

let payload = Data(base64Encoded: file.payload)!
check(payload.range(of: Data("sk-test-123".utf8)) == nil, "ciphertext does not contain plaintext")

let again = try VaultCrypto.deriveKey(password: "correct horse battery", salt: salt, iterations: iters)
check((try? VaultCrypto.open(file, key: again)) == secret, "same password re-derives same key")

let wrong = try VaultCrypto.deriveKey(password: "wrong password!!", salt: salt, iterations: iters)
do { _ = try VaultCrypto.open(file, key: wrong); check(false, "wrong password rejected") }
catch VaultError.wrongPassword { check(true, "wrong password rejected") }

var tampered = file
var bytes = [UInt8](payload); bytes[bytes.count / 2] ^= 0x01
tampered.payload = Data(bytes).base64EncodedString()
check((try? VaultCrypto.open(tampered, key: key)) == nil, "tampered ciphertext rejected")

var headerTampered = file
headerTampered.iterations = iters + 1
check((try? VaultCrypto.open(headerTampered, key: key)) == nil, "tampered header (AAD) rejected")

var weak = file
weak.iterations = 1_000
check((try? VaultCrypto.open(weak, key: key)) == nil, "iteration downgrade rejected")

let file2 = try VaultCrypto.seal(secret, key: key, salt: salt, iterations: iters)
check(file2.payload != file.payload, "fresh random nonce per save")

var huge = file
huge.iterations = 4_000_000_000
check((try? VaultCrypto.open(huge, key: key)) == nil, "absurd iteration count rejected (no hang)")
check((try? VaultCrypto.deriveKey(password: "x", salt: salt, iterations: 4_000_000_000)) == nil,
      "deriveKey refuses absurd iteration count")

// "café" typed precomposed (U+00E9) vs decomposed (e + U+0301) must unlock the same vault.
let composed = "caf\u{00E9} password 123"
let decomposed = "cafe\u{0301} password 123"
check(composed != decomposed.precomposedStringWithCanonicalMapping ? false : true, "test strings normalise equal")
let kc = try VaultCrypto.deriveKey(password: composed, salt: salt, iterations: iters)
let kd = try VaultCrypto.deriveKey(password: decomposed, salt: salt, iterations: iters)
let nfcFile = try VaultCrypto.seal(secret, key: kc, salt: salt, iterations: iters)
check((try? VaultCrypto.open(nfcFile, key: kd)) == secret, "Unicode-normalised passwords match")

// Old vaults made with the raw (un-normalised) bytes still open via normalize: false.
let raw = try VaultCrypto.deriveKey(password: decomposed, salt: salt, iterations: iters, normalize: false)
let rawFile = try VaultCrypto.seal(secret, key: raw, salt: salt, iterations: iters)
let rawAgain = try VaultCrypto.deriveKey(password: decomposed, salt: salt, iterations: iters, normalize: false)
check((try? VaultCrypto.open(rawFile, key: rawAgain)) == secret, "legacy raw-password vault still opens")

let cal = VaultCrypto.calibratedIterations()
print("      calibrated iterations: \(cal)")
check(cal >= VaultCrypto.defaultIterations && cal <= 5_000_000, "calibrated iterations within bounds")

for weak in ["password123", "Password1234!", "P@ssw0rd2024", "aaaaaaaaaaaaaaaa", "123456789012",
             "qwertyuiop12", "abcdefghijklmnop", "letmein!letmein"] {
    check(PasswordPolicy.problem(weak) != nil, "policy rejects \"\(weak)\"")
}
for strong in ["maple orbit cactus lantern", "Vq7#tLm2!pRz9w", "correct horse battery staple"] {
    check(PasswordPolicy.problem(strong) == nil, "policy accepts \"\(strong)\"")
}

print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)

