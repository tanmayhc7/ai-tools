# ai-tools

A growing collection of small, practical tools for people who build with AI. They're **privacy-first**: they run on your Mac and keep your data there.

## What's inside

| | Tool | What it does |
|---|---|---|
| <img src="keyvault/assets/logo.png" width="40"> | **[KeyVault](keyvault/)** | An encrypted vault for your API keys (OpenAI, Anthropic, Stripe and others). AES-256-GCM encryption, auto-lock, a self-clearing clipboard and built-in backups. |
| <img src="leakguard/assets/logo.png" width="40"> | **[LeakGuard](leakguard/)** | Finds API keys that leaked into your code, including ones buried in old git commits, and installs a git hook that blocks new leaks. Can also check for your exact KeyVault keys. |
| <img src="redact/assets/logo.png" width="40"> | **[Redact](redact/)** | Replaces names, emails, phone numbers, card numbers and keys with placeholders before you paste text into an AI, then puts the real values back into the AI's answer. |
| <img src="contextpack/assets/logo.png" width="40"> | **[ContextPack](contextpack/)** | Bundles a code project into one prompt-ready block of text. It respects `.gitignore`, shows token counts, never reads `.env` or key files, and redacts secrets. |

All four are native macOS apps (macOS 14+) with no third-party dependencies. Each folder has its own README with setup steps, usage, and the attacks it was tested against.

### How they fit together

```
            KeyVault  ── stores your keys, encrypted
               │
               ▼
           LeakGuard  ── checks those keys never ended up in your code or git history

   Redact  ·  ContextPack  ── keep personal data and secrets out of what you send to AI
```

## Getting started

```bash
xcode-select --install
```

```bash
git clone https://github.com/tanmayhc7/ai-tools.git
```

Then build whichever tool you want. For example:

```bash
cd ai-tools/keyvault && ./build.sh && open build/KeyVault.app
```

Every tool builds the same way: `cd` into its folder and run `./build.sh`. The script runs the tool's tests before building.

## More to come 🚧

More tools are on the way. Star or watch the repo to hear about new ones.

Have an idea, or found a bug? [Open an issue](https://github.com/tanmayhc7/ai-tools/issues).
