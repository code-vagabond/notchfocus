# NotchFocus

**Your MacBook notch shakes when you drift off task.**

NotchFocus is a tiny macOS menu-bar app. You tell it what you're working on. Every few
seconds it reads the *text* of your active window (on-device OCR — no screenshots ever leave
your Mac), asks a small decision model whether that matches your goal, and if you've wandered
off, the notch grows into a Dynamic-Island-style bar and shakes at you. That's it. No
blocklists, no timers, no "are you sure?" dialogs — just a nudge when you need one.

https://github.com/user-attachments/assets/3e9e5628-9f93-4937-b3dc-02d1818132ff

*(Player not showing? [Download the 30 s demo](docs/demo.mp4).)*

```
ScreenCaptureKit (active window) → Apple Vision OCR → { goal, app, title, url, screen_text }
   → Jev (TypeSafe System One)  → { distracted: p, severity: 0..3 }
   → p ≥ threshold for N consecutive samples → notch expands + shakes + trackpad haptic
```

## Why

Website blockers are blunt: YouTube is a distraction when you should be writing, and research
when you're editing a video. The only thing that knows the difference is your *stated goal*
compared against *what's actually on screen*. NotchFocus does exactly that comparison and
nothing else.

## How it works

1. **Capture** — `ScreenCaptureKit` grabs a frame of the frontmost window only (falls back to
   the display if the window can't be captured). Frames are OCR'd with Apple Vision and
   discarded; only the recognized text is kept.
2. **Context** — frontmost app, window title (Accessibility API) and, for browsers, the current
   URL (AppleScript).
3. **Judge** — `{ focus_goal, active_window, screen_text }` is POSTed to
   [Jev](https://docs.typesafe.ai), TypeSafe's "System One" model. It's a decision model, not a
   chat model: it returns typed probabilities, no generation, no vision. Two questions are asked:
   - `distracted` → p ∈ [0, 1]
   - `severity` → 0 *On task* · 1 *Slight drift* (email, Slack, docs) · 2 *Off task* · 3 *Doom-scrolling*
4. **Nudge** — a distracted sample is p ≥ threshold (65 % default; 80 % if severity is only
   "slight drift"). One distracted sample shakes the notch (raise "Samples before nudge" in Settings if you get false alarms). On Macs or external
   displays without a notch, a small island is drawn in the menu-bar band instead.

Checks run on a fixed interval (10 s default) *and* on tab / window / app switches (after a short
settle delay), so a wrong turn is caught within a couple of seconds.

## Privacy

- Screenshots never leave your machine. OCR is Apple Vision, on-device. Only the extracted
  text plus app name, window title and browser URL are sent to the Jev API.
- Nothing else talks to the network. No analytics, no accounts.
- Everything the app writes lives in `~/.config/notchfocus/`:

  | File | Contents |
  | --- | --- |
  | `apikey` | your TypeSafe key, `0600` |
  | `verdicts.jsonl` | one JSON line per check (p, severity, app, title, tokens, latency) — also the source of the "spent today" line in the menu |
  | `last_request.json` | the most recent request body, incl. OCR'd screen text — for prompt tuning; delete if you don't want it |
  | `app.log` | plain-text app log (errors, permission state) |

If you're not comfortable sending window titles / on-screen text to a third-party API, this
app isn't for you — it *is* the product.

## Requirements

- macOS 14 Sonoma or later (Apple Silicon or Intel; a notch is nice but not required)
- Xcode Command Line Tools (`xcode-select --install`) — Swift 5.9+
- A [TypeSafe](https://typesafe.ai) API key

## Install

There's no signed release yet — build it yourself (takes ~30 s):

```sh
git clone https://github.com/code-vagabond/notchfocus.git
cd notchfocus
./scripts/bundle.sh      # swift build -c release → ./NotchFocus.app (ad-hoc signed)
open NotchFocus.app
```

`bundle.sh` wraps the binary in a minimal `.app` so macOS attributes the permissions below to
*NotchFocus* rather than to your terminal. `swift run` also works for hacking, but then TCC
prompts are tied to Terminal/iTerm.

That's all you need. No Apple developer account, no certificates — the bundle is ad-hoc
signed and runs as-is.

**If you're going to rebuild often**, note that macOS ties permission grants to the code
signature, and an ad-hoc signature changes with every build — so you'd re-grant Screen
Recording / Accessibility each time. To avoid that, sign with a real identity:

```sh
security find-identity -v -p codesigning        # list your identities
NOTCHFOCUS_SIGN_ID="Apple Development: you@example.com (TEAMID)" ./scripts/bundle.sh
```

A free Apple ID added in Xcode → Settings → Accounts gives you an "Apple Development"
certificate; the paid Developer Program isn't required. `NOTCHFOCUS_INSTALL=1` additionally
copies the bundle to `/Applications`.

### First launch

The app walks you through, in order:

1. **Accessibility** — to read window titles and watch for tab/window switches
2. **TypeSafe API key** — stored in `~/.config/notchfocus/apikey` (or export `TYPESAFE_API_KEY`)
3. **Your focus goal** — e.g. *"write the Q3 investor update"*
4. **Screen Recording** — macOS prompts on the first capture
5. **Automation → your browser** — macOS prompts on the first URL read

Grant all of them, then right-click the `◎` in the menu bar → **Check now** (⌘R) to confirm
it's working, and **Test notch shake** (⌘T) to see the nudge.

## Usage

- **Left-click `◎`** — popover: type what you're working on, hit *Start focus*. Also shows the
  last verdict and a *Pause* button.
- **Right-click `◎`** — full menu: Check now, Pause/Resume, Test shake, Settings, permission
  shortcuts, Set API key, Open log folder, Quit.

### Settings (⌘,)

| Setting | Default | What it does |
| --- | ---: | --- |
| Check interval | 10 s | Seconds between periodic screen checks (5–60) |
| Reaction delay | 1.5 s | Wait after a tab/window/app change before judging it, so the page can settle |
| Min. gap | 4 s | Minimum spacing between change-triggered checks |
| Distraction threshold | 65 % | p(distracted) above which a sample counts as distracted |
| Slight-drift threshold | 80 % | Separate, stricter cutoff when Jev rates the activity as only "slight drift" (email, Slack, docs). 100 % = never nudge for drift |
| Samples before nudge | 1 | Consecutive distracted samples required before the notch shakes |

### Cost

Each check is ~500–900 input tokens. At Jev's current pricing ($0.042 / M tokens) that's
roughly **1 cent per hour** at the default 10 s interval. Event-driven checks add a bit
when you're switching tabs a lot.

## Tuning the judge

The prompts live in `Sources/NotchFocus/JevClient.swift` (`questions` → `instructions` and
`criteria`). The model is told to weight `active_window` (exact OS metadata) far above
`screen_text` (noisy OCR that may quote unrelated things), and that terminals, IDEs, docs and
AI coding assistants count as work unless the content is clearly unrelated.

To iterate: run for a while, then look at `~/.config/notchfocus/verdicts.jsonl` for
false positives/negatives and `last_request.json` for exactly what the model saw. `jev-latest`
is used while prototyping; pin a model version before you rely on it.

## Project layout

```
Package.swift                  SwiftPM, single executable target, no dependencies
scripts/bundle.sh              release build → .app bundle → codesign (→ /Applications, opt-in)
scripts/entitlements.plist     apple-events entitlement (browser URL via AppleScript)
Sources/NotchFocus/
  main.swift                   NSApplication bootstrap
  AppDelegate.swift            status item, timer loop, debounce + escalation, first-run dialogs
  FocusPopover.swift           "What are you working on?" popover under the status item
  ScreenReader.swift           ScreenCaptureKit active-window capture (display fallback) + Vision OCR
  ActiveContext.swift          frontmost app, AX window title, browser URL via AppleScript
  WindowWatcher.swift          AX observer: re-check on tab switch / new window / title change
  JevClient.swift              POST /v1/systemone, question definitions, response parsing
  NotchPanel.swift             click-through NSPanel over the notch: expand / collapse / shake
  NotchPresenter.swift         one panel per display; alert lands on the screen with the focused window
  Settings.swift               UserDefaults, API key lookup, JSONL + text logs
  SettingsWindow.swift         Settings window (sliders)
```

No Xcode project, no third-party dependencies — just AppKit, ScreenCaptureKit and Vision.

## Roadmap / ideas

- Escalation: longer shake, dim the screen after N minutes of persistent distraction
- Pluggable judge — swap Jev for a local model or another API behind the same
  `{ distracted, severity }` contract
- Signed + notarized release build
- Feed the verdict stream into a time tracker (same JSON shape as `verdicts.jsonl`)

PRs welcome, especially prompt tuning backed by real `verdicts.jsonl` examples and reports from
Macs without a notch / with multiple displays.

## License

MIT — see [LICENSE](LICENSE).

## Credits

Built with Apple Vision + ScreenCaptureKit and [TypeSafe's Jev](https://docs.typesafe.ai)
decision model. Not affiliated with Apple or TypeSafe.
