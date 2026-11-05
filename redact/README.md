<p align="center">
  <img src="assets/logo.png" width="128" alt="Redact logo">
</p>

<h1 align="center">Redact</h1>

<p align="center">
  Use AI on real documents without handing over personal data.<br>
  Redact swaps names, emails, numbers and keys for placeholders, then puts them back in the AI's answer.<br>
  A native Mac app. Detection runs entirely on your machine.
</p>

---

## How it works

```
 Your text                     What the AI sees                 The AI's reply, restored
 ─────────                     ────────────────                 ────────────────────────
 "Email Priya Raman at    →    "Email [NAME_1] at          →    "Hi Priya Raman, about
  priya@acme.com about          [EMAIL_1] about                  card 4111 1111 1111 1111…"
  card 4111 1111 1111 1111"     card [CARD_1]"
```

1. **Paste or drop** your text (or open a Word, RTF, PDF or text file). The redacted version updates as you type.
2. **Copy** the redacted text and paste it into ChatGPT, Claude or any other AI.
3. Paste the AI's answer into **2. Restore**, and your real details are filled back in.

## What it detects

| On by default | Off by default (often needed for context) |
|---|---|
| People's names · email addresses · phone numbers · street addresses · card numbers (check digit verified) · IBANs (checksum verified) · US SSNs · IP addresses · API keys and passwords · your own custom terms | Web links · organisations · places |

Turn any category on or off in the sidebar. Click the 👁 next to an item to leave that one visible.

**Always hide these words:** add project code names, client names or anything else that must never leak. These are matched as whole words, case-insensitively.

## Requirements

| | |
|---|---|
| **macOS** | 14 Sonoma or later (Apple Silicon or Intel) |
| **Tools** | Apple's free Command Line Tools. Full Xcode is **not** needed |

## Setup

```bash
xcode-select --install
```

```bash
git clone https://github.com/tanmayhc7/ai-tools.git
```

```bash
cd ai-tools/redact && ./build.sh
```

```bash
open build/Redact.app
```

To install it: `cp -R build/Redact.app /Applications/`

The build runs 49 self-tests first; every line should say `PASS`.

## Robustness and privacy

| Risk | How Redact handles it |
|---|---|
| The same person written different ways | The same value always gets the same placeholder, across separate pastes too. A name found once is hidden **everywhere** it appears, and for "Sarah Connor" so is a later "Connor" on its own |
| Your text already contains something like `[EMAIL_1]` | Redact never assigns a placeholder that already appears in your text |
| The AI rewrites placeholders | Restore recognises `[EMAIL_1]`, `[email_1]`, `[ EMAIL_1 ]`, Markdown-escaped `\[EMAIL\_1\]` and bare `EMAIL_1` |
| A restored value that itself looks like a placeholder | Restore works in a single pass, so nothing is expanded twice |
| The AI invents a placeholder that doesn't exist | It's left untouched and listed as "not from this session" |
| Random numbers mistaken for cards or bank accounts | Card numbers must pass the Luhn check and IBANs the mod-97 check; times like `12:30:45` and code like `std::vector` aren't treated as IP addresses |
| Crafted text designed to freeze pattern matching | Every pattern has an upper length bound; 2-million-character hostile inputs finish in seconds, on a background thread |
| **HTML files phoning home** | Found during testing: Apple's HTML importer can fetch remote images, which would reveal that you opened the file. Redact reads HTML as plain text instead |
| Typing while it works | Placeholder numbers are only locked in when you copy, so half-typed text doesn't use them up |
| Screenshots and screen recording | All Redact windows are hidden from capture |
| Clipboard | Restored text (which contains your real data again) is marked so clipboard managers don't record it, and never syncs to other devices |
| What's saved to disk | Only which categories are on. Your text, the placeholder mapping, custom terms and "keep visible" choices live in memory and are gone when you quit or click **Clear All** (<kbd>⌘</kbd><kbd>K</kbd>) |

### Limits, honestly

- **Names come from Apple's on-device language model.** It's good with full sentences, but can miss names in short fragments ("José García." on its own line) or unusual names. **Add anything critical to "Always hide these words"**, which is guaranteed.
- Addresses and phone numbers use Apple's built-in detectors, which are strongest for US and European formats.
- Restore only works within the same session. After **Clear All** or quitting, the mapping is gone. That's by design.
- Placeholders hide values, not context. "The CEO of a Cupertino phone company" still says a lot.

## Troubleshooting

| Problem | Fix |
|---|---|
| A name wasn't hidden | Add it under **Always hide these words** |
| Too much is hidden | Click 👁 on the item, or switch that category off |
| "Nothing to restore yet" | Redact the original text first, in the same session |
| Screenshots of the app are blank | Intentional: windows are hidden from screen capture |

## Project layout

```
redact/
├── build.sh
├── Sources/
│   ├── RedactionEngine.swift  Detection, placeholders, restore (no UI; fully tested)
│   ├── SecretRules.swift      API-key patterns (shared with LeakGuard and ContextPack)
│   ├── RedactApp.swift        App state, file loading, clipboard
│   ├── RedactViews.swift      Interface
│   └── Local.swift            Lets SwiftUI build without full Xcode
├── tests/main.swift           49 tests, including hostile inputs
└── tools/make_icon.swift
```
