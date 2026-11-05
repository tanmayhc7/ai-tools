<p align="center">
  <img src="assets/logo.png" width="128" alt="ContextPack logo">
</p>

<h1 align="center">ContextPack</h1>

<p align="center">
  Turn a code project into one prompt-ready block of text for any AI, with secrets removed automatically.<br>
  A native Mac app. Nothing leaves your machine until you paste it somewhere.
</p>

---

## What it does

- **Pick a project folder** and tick the files you want. Whole folders can be ticked at once
- **Respects `.gitignore`.** It asks git for the file list, so ignore rules (including nested ones) are exactly what git uses
- **Shows a token estimate** per file and in total, plus which context sizes it fits (32K / 128K / 200K / 1M)
- **Removes secrets**: API keys, tokens, private keys and database passwords become `[REDACTED OpenAI API key]`
- **Never reads credential files** (`.env`, `*.pem`, SSH keys, cloud credentials, Terraform state…). They're listed with a 🔒 so you know they exist, but their contents are never loaded
- **Copy to clipboard** (<kbd>⌘</kbd><kbd>⇧</kbd><kbd>C</kbd>) or **Save As…** in XML-tag or Markdown format

Example output (XML format):

```xml
<project name="my-app">
<file_tree>
├── src/
│   └── main.py
└── README.md
</file_tree>

<file path="src/main.py">
API_KEY = "[REDACTED OpenAI API key]"
...
</file>
</project>
```

## Requirements

| | |
|---|---|
| **macOS** | 14 Sonoma or later (Apple Silicon or Intel) |
| **Tools** | Apple's free Command Line Tools (these include `git`). Full Xcode is **not** needed |

## Setup

```bash
xcode-select --install
```

```bash
git clone https://github.com/tanmayhc7/ai-tools.git
```

```bash
cd ai-tools/contextpack && ./build.sh
```

```bash
open build/ContextPack.app
```

To install it: `cp -R build/ContextPack.app /Applications/`

The build runs 54 self-tests first; every line should say `PASS`.

## Using it

1. **Drop a project folder** onto the window, or click **Choose Folder…**.
2. Untick anything you don't need. Lock files (`package-lock.json` and similar) start unticked because they're mostly noise. Use the filter box to find files fast.
3. Watch the token total and the context-size badges.
4. Pick **XML tags** (works well with Claude) or **Markdown**, then **Copy** or **Save As…**.

Icons in the file list:
- 🔒 **never included**: a credential file; it's never read
- 🛡 **orange shield**: this file contains a secret, which will be redacted
- **over 1 MB**: too large to include

## Robustness and security

| Risk | How ContextPack handles it |
|---|---|
| Accidentally pasting your `.env` or private keys into an AI | Credential files are never read, even if you tick them. Secrets inside normal files are redacted |
| A key hidden in an innocently named file (`notes.txt`) | Every file's content is scanned with the same patterns LeakGuard uses, and whole private-key blocks are removed |
| A booby-trapped repo whose config runs programs through git | Blocked: the same hardened git setup as LeakGuard, verified by tests |
| Symlinks pointing outside the project | Never followed |
| A file swapped for a named pipe while loading | Files are opened once and checked through the open handle, so loading can't hang |
| A file containing ` ``` ` breaking the Markdown output | Code fences grow longer than any backtick run in the file |
| A file containing `</file>` breaking the XML output | Escaped, and file paths are XML-escaped too |
| Odd file names (spaces, quotes, accents, even newlines) | Handled; git output is read null-separated |
| Huge projects | Up to 20,000 files and 150 MB of text are read; files over 1 MB are listed but excluded; packing runs in the background |

The app is built with the hardened runtime, so code can't be injected into it.

### Limits

- Token counts are estimates (about 4 characters per token for code and English). Real counts vary a little by model.
- Secret detection catches known key formats and random-looking `key = "..."` assignments. Review before sharing anything sensitive. [LeakGuard](../leakguard/) can check the KeyVault keys you know about.
- The packed text is your code: anything you paste into an AI service goes to that service.

## Troubleshooting

| Problem | Fix |
|---|---|
| "Default ignore list (not a git repo)" | The folder isn't a git repo, so a built-in list is used (skips `node_modules`, `build`, `.venv`, etc.) |
| A file I need is missing | It's probably git-ignored or binary. Check `.gitignore` |
| A file is greyed out with 🔒 | It looks like a credential file. Rename or copy the parts you need into a normal file if it's genuinely safe |

## Project layout

```
contextpack/
├── build.sh
├── Sources/
│   ├── Packer.swift            File listing, loading, packing (no UI; fully tested)
│   ├── SecretRules.swift       Secret patterns (shared with LeakGuard and Redact)
│   ├── GitRunner.swift         Runs git safely (shared with LeakGuard)
│   ├── SafeRead.swift          Race-free file reads (shared with LeakGuard)
│   ├── ContextPackApp.swift    App state
│   ├── ContextPackViews.swift  Interface
│   └── Local.swift             Lets SwiftUI build without full Xcode
├── tests/main.swift            54 tests
└── tools/make_icon.swift
```
