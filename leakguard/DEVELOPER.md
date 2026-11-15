<p align="center">
  <img src="../assets/icons/leakguard.png" width="96" alt="LeakGuard">
</p>

<h1 align="center">LeakGuard: how it works inside</h1>

<p align="center">
  A guided tour of the code, for anyone who wants to understand it, check it, or change it.<br>
  No security background needed. New words are explained where they first appear.
</p>

---

## In one minute

LeakGuard hunts for API keys that ended up where they shouldn't be.

1. **It reads your project's files** and looks for text shaped like a key (`sk-…`, `AKIA…`, `ghp_…`, a private key block, a password in a database address).
2. **It also reads your git history.** A key you deleted last year is still stored in old commits, so LeakGuard replays every commit and checks the lines each one *added*.
3. **It never keeps a secret.** A finding is the file, the line, a masked preview like `sk-p••••••••Ab3x` and a short fingerprint.
4. **It can stand guard.** One click installs a git hook that refuses any commit adding a key.

The twist that shapes most of the code: you point LeakGuard at folders **you didn't write**. A hostile project could try to trick a scanner, so most of the careful engineering is about staying safe while reading untrusted things.

## The big picture

```mermaid
flowchart LR
    subgraph input["What it reads"]
        F["Project files"]
        H["Git history"]
        K["Your KeyVault<br/>optional"]
    end
    SC["Scanner<br/>walks files, streams history"]
    SR["SecretRules<br/>20 patterns plus checks"]
    GR["GitRunner<br/>runs git very carefully"]
    VR["VaultReader<br/>read-only KeyVault access"]
    OUT["Findings<br/>masked previews only"]
    HK["HookInstaller<br/>pre-commit hook"]

    F --> SC
    H --> GR --> SC
    K --> VR --> SC
    SC <--> SR
    SC --> OUT
    HK -.->|"uses a subset of the patterns"| SR
```

## Watch a scan

<p align="center">
  <img src="docs/scan.gif" width="100%" alt="Animation: files and git history flow through the scanner and the secret rules to produce masked findings">
</p>

<details>
<summary><b>The same steps in words</b></summary>

1. The scanner walks the folder. It skips dependency folders, binaries and files over 5 MB, and never follows symlinks out of the folder.
2. Each file goes to `SecretRules`: a fast check for trigger words first, then 20 patterns for known key formats.
3. Matches come back. A generic `key = …` match only counts if the value also looks random, so placeholders are ignored.
4. Then history. Git runs with every program-launching feature switched off, and its output is read line by line, never all at once.
5. Only added lines are checked. That is how a key you deleted months ago is still found, with the commit it came from.
6. A finding keeps the file, the line, a masked preview and a short hash. The secret itself is never stored or shown.

</details>

## Where everything lives

| File | What it does |
|---|---|
| `SecretRules.swift` | **The detector.** 20 patterns, how overlaps are resolved, the "does it look random" check, masking. Shared with Redact, ContextPack and ChatKeep |
| `Scanner.swift` | Walks the folder, streams git history, turns matches into findings, tracks progress and cancellation |
| `GitRunner.swift` | Runs `git` safely against untrusted repositories, and splits its output into lines. Shared with ContextPack |
| `SafeRead.swift` | Reads a file only if it is a plain file, without following links or hanging. Shared with ContextPack |
| `HookInstaller.swift` | Installs, checks and removes the pre-commit hook |
| `VaultReader.swift` | Opens your KeyVault read-only so LeakGuard can look for your exact keys. Shared with ChatKeep |
| `VaultCrypto.swift` | KeyVault's encryption code, copied so this tool builds on its own |
| `LeakGuardApp.swift` | App entry point and the scan state (`ScanModel`) |
| `LeakGuardViews.swift` | The screens: drop zone, results, side panel, KeyVault password sheet |

## Part 1: Recognising a key (`SecretRules`)

The detector has three layers, cheapest first.

```mermaid
flowchart LR
    T["Some text"] --> G{"Layer 1: gate<br/>any trigger word<br/>in it at all?"}
    G -->|"no, skip"| N["Nothing found"]
    G -->|"yes"| R["Layer 2: 20 patterns<br/>known key shapes"]
    R --> E{"Layer 3: generic matches only<br/>does it look random?"}
    E -->|"placeholder or low variety"| N
    E -->|"yes"| O["Resolve overlaps,<br/>return matches"]
```

**Layer 1, the gate.** Almost every file contains no key at all, so the first question is a very cheap one: does the text contain any trigger such as `sk-`, `akia`, `ghp_`, `key`, `token`, `://`? One lowercase copy of the text is searched with `memmem` (a fast C routine). This single choice made scanning 200,000 chat messages go from 33 seconds to 1.4 seconds.

**Layer 2, the patterns.** Each service has a recognisable shape. OpenAI keys start `sk-` and are long. AWS access keys are `AKIA` plus 16 capitals and digits. GitHub tokens start `ghp_`. A few patterns capture only the secret part (for example the password inside `postgres://user:PASSWORD@host`).

**Layer 3, "does it look random?"** The generic rule (`api_key = "…"`) would flag `password = "please-change-this-later"`. So its matches must pass `looksRandom`: not a placeholder word (`your`, `example`, `changeme`, `process.env`…), and with enough variety (Shannon entropy of at least 3.5) *and* both letters and digits.

**Overlaps.** When two patterns match the same text, the earlier, more specific rule wins (an Anthropic key also looks like an OpenAI key, but is reported once, as Anthropic). Rule order in the list matters.

**Private keys.** A `-----BEGIN … PRIVATE KEY-----` header is found by the pattern, then the matching `END` line is found with a single pass and a binary search. (A naive "from BEGIN to END" pattern takes quadratic time on a file full of fake headers: 30,000 of them took 7.8 seconds before the change, 1 second after.)

> [!IMPORTANT]
> **Every repeat in every pattern has an upper limit** (`{20,250}`, never `{20,}`). Unbounded repeats let crafted text freeze the scanner: the word `token` repeated 200,000 times used to take over 100 seconds. A test (`hostile input … scanned in …`) guards this.

## Part 2: Scanning the files (`Scanner.scanWorkingCopy`)

For each file it applies, in order:

| Check | Why |
|---|---|
| Skip folders like `node_modules`, `.build`, `venv`, `Pods`, `.git` | they are huge and not yours |
| Never follow symlinks | a link out of the folder could make it read your whole disk |
| Skip files over 5 MB | keeps memory bounded |
| Read with `SafeRead` | opens once and checks the open handle, so a file swapped for a link or a pipe mid-scan can't redirect or hang it |
| Skip binaries (a NUL byte in the first 8 KB) | images and archives aren't text |
| Decode as text; bad bytes become `�` | an odd encoding can never crash it |

Results stop at 5,000 findings, and a **Stop** button cancels cleanly.

## Part 3: Scanning git history (`Scanner.scanHistory`)

LeakGuard runs one command and reads its output as it streams in:

```text
git log --all -p -U0 --no-color --no-ext-diff --no-textconv --no-renames --format=%x01%H %ad
```

`-p` prints every change, `-U0` leaves out surrounding unchanged lines, `--all` covers every branch, and the odd `%x01` marker starts each commit's header.

The parser is a small state machine reading line by line:

```mermaid
flowchart TB
    L["Read next line"] --> C{"What is it?"}
    C -->|"starts with 01"| H["New commit: remember its id and date"]
    C -->|"diff --git"| D["New file section"]
    C -->|"+++ b/path"| P["Remember which file this is"]
    C -->|"@@ -a +b @@"| N["Remember the new line number"]
    C -->|"+text"| A["An ADDED line: scan it"]
    C -->|"anything else"| X["Ignore"]
```

Only **added** lines (`+…`) are scanned, which is how a deleted key is still caught. The log runs newest to oldest, so if the same secret appears in the same file in many commits it is reported once, at the **oldest** commit (the real origin).

File names in diffs need care: git adds an invisible tab after names containing spaces and wraps unusual names in quotes with octal escapes (`\303\274` for `ü`). `parseDiffPath` decodes both.

## Part 4: Running git safely (`GitRunner`)

A git repository can carry its own configuration, and some settings **launch programs**. A booby-trapped repo could say "when you show a diff, run this script". So LeakGuard overrides every such setting on the command line, which beats anything inside the repo:

| Danger | What is switched off |
|---|---|
| A program run to "format" a diff | `--no-ext-diff`, `--no-textconv` |
| A file-watcher program | `core.fsmonitor=false` |
| A program to page output | `core.pager=cat` |
| A program to "verify" signed commits | `log.showSignature=false`, and every signing program set to `/usr/bin/false` |
| Password helpers and network transports | `credential.helper=`, `protocol.allow=never` |

It also runs git with a minimal environment (`PATH=/usr/bin:/bin`, no system config, no prompts, no optional locks), caps output size and time (10 minutes for history), and uses `LineSplitter` so no line over 2 MB is ever held whole.

> [!NOTE]
> The signature-verification hole was **found by a test, not by thinking**: the test plants a repo whose config tries to run a program through `gpg.program`, and the first version of the code ran it. See `malicious gpg.program + log.showSignature did NOT execute` in `tests/main.swift`.

## Part 5: The pre-commit hook (`HookInstaller`)

```mermaid
sequenceDiagram
    participant You
    participant Git
    participant Hook as pre-commit hook
    You->>Git: git commit
    Git->>Hook: run the hook
    Hook->>Git: which files are staged? (names, null-separated)
    Hook->>Git: show only the added lines of each
    Hook->>Hook: grep those lines for key patterns
    alt a key is found
        Hook-->>You: blocked, here are the files
    else nothing found
        Hook-->>Git: exit 0, commit continues
    end
```

- The installed file is a small shell script with a marker line, `# Installed by LeakGuard`. LeakGuard only ever **removes or replaces a hook that has that marker**. If you already have a different pre-commit hook it refuses to touch it.
- Where does the hook go? If `core.hooksPath` is set (tools like Husky do this) it follows that; otherwise `<git-common-dir>/hooks`, which also handles linked worktrees.
- The hook uses a **subset** of the patterns, written as plain `grep -E` expressions in `HookInstaller.pattern`. It is a separate list from `SecretRules`, because it must run anywhere with just `grep`. Keep the two in step by hand.
- Bypass once, if you must: `git commit --no-verify`.

## Part 6: Your own keys (`VaultReader`)

The "My KeyVault keys" option decrypts your KeyVault read-only, so LeakGuard can search for your **exact** keys even when they are in an unusual format. Two rules protect you:

- The keys exist in memory only for that one scan, and findings keep only a masked preview and a hash.
- A wrong KeyVault password typed here **counts toward KeyVault's own lockout** (it writes to the same saved counters, `local.keyvault.app`). Otherwise LeakGuard would be a way around the lockout.

Entries shorter than 12 characters are ignored; they would match ordinary words.

## Tests

`./build.sh` runs all **67** tests (`tests/main.swift`) before building.

| Group | What it covers |
|---|---|
| Rules | each key type is found, and ordinary code, placeholders and env-var references are not |
| Hostile input | 3 MB single lines, keys on a window boundary, text built to slow patterns down |
| Folder scanning | hidden `.env` files, skipped folders, symlinks, binaries, bad encodings, oversized files, cancelling |
| Git history | a key deleted in a later commit, odd file names, one report per secret, **booby-trapped repos that must not run anything** |
| The hook | blocks a key, allows clean commits, handles file names with spaces, never overwrites someone else's hook |
| KeyVault link | decrypts a throwaway vault, and shares the lockout |

Test keys are **built at runtime** (`"sk-" + "proj-" + …`) so this repository's own source never contains something that looks like a real key.

```bash
swiftc -O Sources/SecretRules.swift Sources/GitRunner.swift Sources/SafeRead.swift Sources/Scanner.swift \
  Sources/VaultReader.swift Sources/VaultCrypto.swift Sources/HookInstaller.swift tests/main.swift -o /tmp/lg-tests && /tmp/lg-tests
```

## Changing things safely

<details>
<summary><b>Add a new kind of key</b></summary>

1. Open `SecretRules.swift` and add a `rule(...)` to `all`. Put it **before** any broader rule that would also match it.
2. **Give every repeat an upper bound** (`{32,100}`, not `{32,}`).
3. **Add a trigger.** Add a lowercase piece of the key's prefix (like `"foo_"`) to the `triggers` list. If you forget, the gate in layer 1 will skip texts containing the new key and your pattern will never run.
4. Add tests in `tests/main.swift`: the key is found, a near-miss isn't, and the hostile-input timing still passes. Build the fake key at runtime.
5. Copy `SecretRules.swift` to `redact/`, `contextpack/` and `chatkeep/`, then run `tools/check-shared.sh`.
6. If the key should also block commits, add its pattern to `HookInstaller.pattern`.

</details>

<details>
<summary><b>Skip another folder</b></summary>

Add its name to `Scanner.skipDirectories`.

</details>

<details>
<summary><b>Change what counts as "looks random"</b></summary>

Edit `SecretRules.looksRandom`. Expect to adjust the false-positive tests (`ignores low-entropy config value`, `ignores placeholder`) alongside.

</details>

## Gotchas

- **The whole point is untrusted input.** Don't add a call that runs git, a shell or any program on a scanned folder without going through `GitRunner`.
- **Copies.** `SecretRules`, `GitRunner`, `SafeRead` and `VaultReader` are shared. Edit the original in `leakguard/`, copy, and run `tools/check-shared.sh`.
- **Never store a full secret.** Findings hold `masked` and `fingerprint` only. Keep it that way.
- **Don't use `@State`**; it needs full Xcode. Use `@Local`.

## Glossary

| Word | Plain meaning |
|---|---|
| **Commit** | One saved snapshot of a project in git |
| **History** | Every commit ever made. Deleting a file later doesn't remove it from old commits |
| **Diff** | The list of lines a commit added and removed |
| **Hook** | A script git runs automatically at certain moments, such as before a commit |
| **Regular expression** | A pattern for matching text, like "sk- followed by 32 or more letters" |
| **Entropy** | A measure of how random text looks. `aaaaaaaa` is low, `h7Gk2LmQ9xPz` is high |
| **Symlink** | A shortcut file that points somewhere else |
| **Booby-trapped repo** | A repository whose settings try to run a program when you read it |

---

<p align="center">
  <sub>Part of <a href="../README.md">ai-tools</a> · back to <a href="README.md">LeakGuard</a> · licensed under the <a href="../LICENSE">GNU AGPL v3</a></sub>
</p>
