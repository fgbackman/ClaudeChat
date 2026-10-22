# Claude Chat

A native SwiftUI Mac app for chatting with Claude through the Claude API, using your own API key and credit.

## What it does

- Streams replies as they're written, with a Stop button (⌘.)
- Model picker per chat: Sonnet 5.5 (default), Opus 5.5, Haiku 5.5, Fable 5.1
- Effort picker (Low / Medium / High / Max / Model default) — the main dial for cost and speed
- Credit meter in the sidebar: starts at $100 and counts down using the token counts the API returns
- Per-reply footer showing tokens in/out, cache hits and cost
- Prompt caching on by default, so the re-sent history in long chats is billed at the cache-read rate
- Saved chat history (`~/Library/Application Support/ClaudeChat/conversations.json`)
- API key stored in the macOS Keychain
- Attachments: pictures (JPEG, PNG, HEIC, GIF, WebP…), PDFs, and text-based files (txt, md, csv, json, code, Word, RTF). Attach with the paperclip, drag files onto the chat, ⌘O, or ⌘⇧V to paste a copied image or screenshot. Images are rotated upright and resized to 2000 px on the long edge before sending.
- Menu bar panel with credit left, the latest reply and a quick-ask box
- Optional system prompt and optional "show reasoning" view
- Markdown-ish rendering with copyable code blocks

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ or the Xcode Command Line Tools (`xcode-select --install`)
- A Claude API key from the Claude Console (platform.claude.com → API Keys)

## Build and run

**Option A — make a real .app:**

```bash
cd ClaudeChat
chmod +x build-app.sh
./build-app.sh
open "build/Claude Chat.app"
```

Drag `build/Claude Chat.app` into /Applications if you want to keep it.

**Option B — Xcode:** `open Package.swift`, pick the "ClaudeChat" scheme and "My Mac", then ⌘R.

**Option C — terminal, quick test:** `swift run`

On first launch, paste your API key. You can change it, your starting credit, the default model and more in Settings (⌘,). If `ANTHROPIC_API_KEY` is set in your environment, it's used when no key is saved.

## Prices built in (per million tokens, from Anthropic's pricing page, Oct 2026)

| Model      | Input  | Output | Cache read |
|------------|--------|--------|------------|
| Haiku 5.5  | $0.10  | $0.50  | $0.01      |
| Sonnet 5.5 | $2     | $10    | $0.10      |
| Opus 5.5   | $4     | $20    | $0.20      |
| Fable 5.1  | $10    | $50    | $0.25      |

Haiku 5.5 is priced higher for prompts over 100k tokens ($0.50 / $2.50); the app accounts for that. If prices change, edit `ModelOption.all` in `Sources/ClaudeChat/Models.swift`.

Thinking tokens bill as output, which is why the effort setting matters: lower effort means less thinking and cheaper replies.

## What attachments cost

They're billed as input tokens. A typical photo (resized to ~2000×1500) is about 3,900 tokens, roughly 0.8¢ on Sonnet 5.5 the first time. A PDF is about 1,500–3,000 tokens per page, since each page is read as text plus an image. Attachments stay in the conversation, so they're re-sent with every later message, but with prompt caching on, those repeats are billed at the cache-read rate (5% of normal on Sonnet/Opus 5.5).

## Notes

- The credit meter is an estimate. The Claude Console's usage and billing pages are the real record. If you stop a reply partway, the final token count isn't reported, so the meter can run slightly low.
- After rebuilding, macOS may ask once whether the new build can read the saved key from the Keychain; choose "Always Allow".
- Chat history is plain JSON on your Mac; nothing is sent anywhere except to api.anthropic.com.
