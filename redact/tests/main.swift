import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS  \(name)" : "FAIL  \(name)")
    if !ok { failures += 1 }
}
func redact(_ s: String, _ settings: RedactionSettings = RedactionSettings()) -> (String, RedactionMap) {
    var map = RedactionMap()
    let out = RedactionEngine.redact(s, settings: settings, map: &map)
    return (out.text, map)
}
var all = RedactionSettings(); all.enabled = Set(Category.allCases)

// MARK: Detection

check(redact("mail jane.doe+ai@example.co.uk now").0 == "mail [EMAIL_1] now", "email")
check(redact("card 4111 1111 1111 1111 ok").0 == "card [CARD_1] ok", "valid card (Luhn) redacted")
check(redact("order 4111 1111 1111 1112 ok").0.contains("4111 1111 1111 1112"), "Luhn-invalid number left alone")
check(redact("ref 0000000000000000").0.contains("0000000000000000"), "all-same-digit number left alone")
check(redact("pay GB82 WEST 1234 5698 7654 32 today").0 == "pay [IBAN_1] today", "valid IBAN redacted")
check(redact("code GB00 WEST 1234 5698 7654 32").0.contains("GB00"), "IBAN with bad checksum left alone")
check(redact("ssn 123-45-6789.").0 == "ssn [ID_1].", "US SSN")
check(!redact("ssn 000-12-3456").0.contains("[ID_"), "invalid SSN pattern not labelled as an ID")
check(redact("server 10.0.12.7 and localhost 127.0.0.1").0 == "server [IP_1] and localhost 127.0.0.1", "IPv4 (loopback kept)")
check(redact("v6 2001:db8:85a3::8a2e:370:7334 here").0 == "v6 [IP_1] here", "compressed IPv6")
check(redact("meet at 12:30:45 for std::vector and a::b").0 == "meet at 12:30:45 for std::vector and a::b", "times and C++ scopes are not IPs")
check(redact("version 1.2.3 released").0 == "version 1.2.3 released", "3-part version not an IP")
check(redact("call +1 (415) 555-0132 today").0.contains("[PHONE_1]"), "phone number")
check(!redact("in 2024 we had 12 items").0.contains("PHONE"), "short numbers are not phones")
let key = "sk-" + "proj-" + String(repeating: "Ab3x", count: 12)
check(redact("OPENAI_API_KEY=\(key)").0 == "OPENAI_API_KEY=[SECRET_1]", "API key")
check(redact("visit https://intranet.acme.dev/x", all).0.contains("[URL_1]"), "URL when enabled")
check(redact("visit https://intranet.acme.dev/x").0.contains("https://"), "URL off by default")

let story = "Sarah Connor emailed John Smith. Later, Connor called John Smith again."
let (sOut, sMap) = redact(story)
check(!sOut.contains("Sarah") && !sOut.contains("John Smith"), "people's names redacted")
check(!sOut.contains("Connor"), "surname on its own also hidden (token expansion)")
check(sOut.components(separatedBy: "[NAME_").count - 1 >= 4, "every mention replaced")
let johnKeys = sMap.all.filter { $0.original == "John Smith" }
check(johnKeys.count == 1, "same name → same placeholder")
let accented = redact("Yesterday José García met with Zoë Ødegaard at the office to discuss the contract.").0
check(!accented.contains("García") && !accented.contains("Ødegaard"), "accented names")

// MARK: Custom terms and keep-list

var custom = RedactionSettings(); custom.customTerms = ["Project Falcon", "C++ (beta)", "Ann"]
let (cOut, _) = redact("project falcon ships. Annual review with Ann. Using C++ (beta).", custom)
check(cOut.contains("[TERM_") && !cOut.lowercased().contains("project falcon"), "custom term, case-insensitive")
check(cOut.contains("Annual"), "custom term matches whole words only")
check(!cOut.contains("C++ (beta)"), "custom term with regex characters handled")
var keep = RedactionSettings(); keep.keep = [RedactionMap.normalize("ops@example.com", .email)]
check(redact("ops@example.com and me@example.com", keep).0 == "ops@example.com and [EMAIL_1]", "keep-list leaves chosen value visible")

// MARK: Placeholder safety

let (collOut, collMap) = redact("Literal [EMAIL_1] in text, real: a@b.io")
check(collOut.hasPrefix("Literal [EMAIL_1] in text") && collOut.contains("[EMAIL_2]"), "never reuses a token already in the text")
check(collMap.byKey["EMAIL_1"] == nil, "colliding token not in the map")

var session = RedactionMap()
_ = RedactionEngine.redact("from a@b.io", settings: RedactionSettings(), map: &session)
let second = RedactionEngine.redact("to c@d.io and a@b.io", settings: RedactionSettings(), map: &session)
check(second.text == "to [EMAIL_2] and [EMAIL_1]", "session map keeps placeholders stable across pastes")

// MARK: Restore

var m = RedactionMap()
let red = RedactionEngine.redact("Email bob@x.com, card 4111111111111111, names: Alice Brown",
                                 settings: RedactionSettings(), map: &m)
let reply = "Sure — I'll write to [email_1], charge \\[CARD\\_1\\], and greet NAME_1. Also [ NAME_1 ] and [EMAIL_9]."
let r = RedactionEngine.restore(reply, map: m)
check(r.text.contains("write to bob@x.com"), "restore: case-insensitive token")
check(r.text.contains("charge 4111111111111111"), "restore: markdown-escaped token")
check(r.text.contains("greet Alice Brown") && r.text.contains("Also Alice Brown"), "restore: bare and spaced tokens")
check(r.unknown == ["[EMAIL_9]"], "restore: reports tokens it never created")
check(red.used.count == 3, "redact reports placeholders used")

var tricky = RedactionMap()
_ = RedactionEngine.redact("x@y.io writes about [EMAIL_1]-style tokens", settings: RedactionSettings(), map: &tricky)
// x@y.io became EMAIL_2 (EMAIL_1 already in text). Restoring must not chain-expand.
var chain = RedactionMap()
_ = chain.placeholder(for: "[EMAIL_2] literal", category: .custom, avoiding: "")
_ = chain.placeholder(for: "z@z.io", category: .email, avoiding: "")
let chained = RedactionEngine.restore("[TERM_1] then [EMAIL_1]", map: chain)
check(chained.text == "[EMAIL_2] literal then z@z.io", "restore is single-pass (no chain expansion)")
check(RedactionEngine.restore("[NAME_10] vs [NAME_1]", map: { var mm = RedactionMap()
    for i in 1...10 { _ = mm.placeholder(for: "Person\(i)", category: .person, avoiding: "") }; return mm }()).text
      == "Person10 vs Person1", "restore: NAME_10 not confused with NAME_1")
check(RedactionEngine.restore("max [MAX_2] value", map: m).text == "max [MAX_2] value", "restore: ignores non-placeholder brackets")

// MARK: Robustness

check(redact("").0 == "", "empty input")
check(redact("👋🏽 hi e\u{301}mail me: a@b.io 👨‍👩‍👧").0 == "👋🏽 hi e\u{301}mail me: [EMAIL_1] 👨‍👩‍👧", "emoji and combining marks keep ranges correct")
let big = String(repeating: "Lorem ipsum dolor sit amet, contact sales@acme.io or call 415-555-0132. ", count: 6_000)
let t0 = Date()
let (bigOut, _) = redact(big)
let dt = Date().timeIntervalSince(t0)
check(!bigOut.contains("sales@acme.io"), "large input fully redacted")
check(dt < 30, String(format: "~430 KB redacted in %.1fs", dt))
for (name, text) in [("email domain bomb", "a@" + String(repeating: "b.", count: 300_000) + "!"),
                     ("2M digits", String(repeating: "4", count: 2_000_000)),
                     ("'[' + spaces ×100k", String(repeating: "[   ", count: 100_000)),
                     ("'[EMAIL' ×100k", String(repeating: "[EMAIL", count: 100_000)),
                     ("dotted numbers ×200k", String(repeating: "1.1.1.", count: 200_000)),
                     ("hex-colon run", String(repeating: "a:", count: 400_000)),
                     ("@ storm", String(repeating: "a@", count: 400_000))] {
    var mm = RedactionMap()
    let t = Date(); _ = RedactionEngine.redact(text, settings: all, map: &mm)
    _ = RedactionEngine.restore(text, map: mm)
    let dt = Date().timeIntervalSince(t)
    check(dt < 20, String(format: "hostile input %@ handled in %.2fs", name, dt))
}
let roundTrip = RedactionEngine.restore(RedactionEngine.redact(story, settings: RedactionSettings(), map: &m).text, map: m)
check(roundTrip.text == story, "redact → restore round-trips exactly")

print(failures == 0 ? "\nAll tests passed." : "\n\(failures) test(s) failed.")
exit(failures == 0 ? 0 : 1)
