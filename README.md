# Saathi

**Loom shows you how. Saathi sits next to you while you do it.**

Saathi is a Mac cursor buddy that sees your screen and helps you get things done — especially on the government, banking and travel portals where people (often our parents) get stuck. You say or type what you want ("download my Aadhaar", "book Tatkal for Saturday"), choose how much control to hand over, and a marigold ring takes it from there.

Built for the [Nebius × NVIDIA Global AI Hackathon](https://nebiusglobalaihackathon.devpost.com/) — **Personal AI track**.

## How you use it

A black pill sits at the top centre of your screen, blending into the MacBook notch:

- **Press ⌘⇧Space** (or click the pill) and type what you want, or **hold Control + Option and talk**.
- The pill shows what Saathi is doing ("Step 3 · selecting Goa") and the Next / Stop / Confirm buttons when it needs you. **Esc** stops everything.

## How it works

Say what you need, and Saathi does it on your Mac while you watch: it opens the right site, clicks, types and scrolls, and narrates every step with the marigold ring.

Safety, built in:

- **Cookie banners and pop-ups are cleared first** (declining optional cookies when it can), so Saathi never clicks a button hidden behind an overlay.
- **Hard pause before anything irreversible** — pay, submit, send, book, delete. The ring turns red and waits for you to confirm.
- **Saathi never types passwords, OTPs, PINs, card or ID numbers.** The ring parks beside the field with a lock badge and says "your turn".
- **Esc stops everything instantly.** While Saathi is driving, the screen edge glows marigold with an "Esc to stop" label.
- **Runs are capped at 15 autonomous steps**, then Saathi hands control back to you.

## Skills: it gets faster the more you use it

After a task works, Saathi offers to **save it as a skill** — a small JSON file of steps described in words ("button 'Login'"), never pixel positions. Next time, the steps replay without a big-model call by finding each target again on the current screen, so a skill survives layout changes. If a target moved, the planner takes over with the saved step as a hint (self-healing).

Personal values are never stored. A typed value becomes a placeholder like `{aadhaar_number}`; on replay Saathi fills it from your new request if you said it, otherwise it's your turn to type.

## How it uses NVIDIA Nemotron and Nebius Token Factory

Every model call goes to **Nebius Token Factory** through its OpenAI-compatible API. Three NVIDIA Nemotron 3 models each have a distinct job:

| Model | Job in Saathi |
|---|---|
| **Nemotron 3 Nano Omni** | Reads privacy-shielded screenshots: answers questions about the screen, and plans steps visually when an app has no Accessibility tree (canvas apps, images) |
| **Nemotron 3 Super** | Plans the next step from the numbered list of on-screen elements |
| **Nemotron 3 Nano** | Fast, cheap calls: task-vs-question routing, matching requests to saved skills, filling skill fields, naming skills |

Targeting uses the **macOS Accessibility tree first** (real buttons and fields with exact frames — far more reliable than guessing pixels), with Omni vision as the fallback, and vision points snapped onto the real element underneath.

The **Model routing** window shows every call live: which model handled it, latency, tokens and estimated cost, plus a running spend total with a **hard spend cap** (`SPEND_LIMIT_USD`).

**Tavily**: for a task with no saved skill, Saathi first searches the official steps and the current official URL, so the agent doesn't guess at an outdated flow — and it warns you if the site you're on doesn't match the official domain it found.

## Privacy

- Saathi only looks at your screen when you ask (hotkey or Ask box). Nothing is recorded in the background.
- Before any screenshot leaves the Mac, Apple's on-device text recognition finds Aadhaar, PAN, passport and card numbers and blacks them out, along with every password field.
- No analytics, no account, no email collection.

## Run it

Requirements: macOS 14.2+ and Apple's Command Line Tools (`xcode-select --install`). Full Xcode is not needed. You also need a Nebius Token Factory API key.

1. Copy `.env.example` to `.env` in the project root and add your key:
   ```
   PROVIDER_BASE_URL=https://api.tokenfactory.nebius.com/v1
   PROVIDER_API_KEY=your-key
   TAVILY_API_KEY=optional
   SPEND_LIMIT_USD=2
   ```
   Model IDs are picked automatically from the provider's model list; set `VISION_MODEL`, `REASONING_MODEL` or `FAST_MODEL` to override. Any OpenAI-compatible provider works for testing.
2. Build and launch:
   ```
   bash build-saathi.sh
   open ~/Applications/Saathi.app
   ```
   The script builds with SwiftPM, packages `~/Applications/Saathi.app` and signs it with a local self-signed "Saathi Dev" certificate it creates once, so macOS keeps your permissions across rebuilds.
3. Saathi appears in the **menu bar** (not the Dock). Click the ring icon and grant Accessibility, Screen Recording and Microphone, then quit and reopen Saathi once so Screen Recording takes effect.
4. Press **⌘⇧Space** and type what you need, or hold **Control + Option** and say it. 

> Always launch with `open` (or from Finder). Running the binary directly from Terminal gives the permissions to Terminal instead of Saathi.

## Project layout

| File | What it does |
|---|---|
| `AgentCoordinator.swift` | The agent loop: skills → research → observe → plan → present → act/wait, plus all safety rules |
| `AccessibilityTreeReader.swift` | Reads the frontmost app's buttons and fields; presses, clicks, types, scrolls |
| `AgentRingOverlay.swift` | The marigold ring: travel, morph, trust-dial states, spotlight, caption chip, driving glow, floating controls |
| `NemotronClient.swift` | Token Factory client: model auto-resolution, routing log, spend cap |
| `PrivacyShield.swift` | On-device redaction of ID numbers and password fields |
| `TavilyClient.swift` | Official-steps research and the lookalike-site check |
| `SkillStore.swift` | Saving, matching and replaying skills |
| `ActionReceiptStore.swift`, `AgentDashboardWindow.swift` | Receipts, skills and model-routing window |
| `DynamicIsland.swift` | The notch pill: ask box (⌘⇧Space), status, and the Next / Stop / Confirm buttons |
| `AgentControlsView.swift` | Ask box and language switch in the menu bar panel |
| `SystemSpeechTTSClient.swift` | Free, offline narration with macOS voices, including Hindi |

## Credits

Saathi is built on [Clicky](https://github.com/farzaa/clicky) by Farza (MIT), which provided the macOS foundation: menu bar app, push-to-talk, screen capture and the cursor overlay window. On top of it, Saathi adds the task agent, Accessibility-tree targeting, skills, the privacy shield, Tavily research, receipts and model routing, the marigold ring identity, Hindi narration, and a move from Claude/AssemblyAI/ElevenLabs to NVIDIA Nemotron on Nebius Token Factory with free on-device speech.

## License

MIT — see [LICENSE](LICENSE).
