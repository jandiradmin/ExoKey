# ExoKey — notes for Claude Code

ExoKey is a macOS menu-bar app (macOS 13+, Apple Silicon): it fixes text typed in the wrong keyboard layout (EN/UK/RU),
corrects typos, and shows local-LLM ghost-text autocomplete (Cotypist-style). Open source, MIT:
github.com/jandiradmin/ExoKey. Site: https://exokey.top (served from `docs/`).

## Working with Yan (the owner)
- Answer in **Russian**, short, numbered steps. No long explanations.
- Shell commands in plain unindented code blocks (no indentation inside lists — it gets copied).
- **Ask when in doubt** instead of guessing. Don't guess about results: check logs/tests.
- **Never hardcode specific words** to fix a case — find the general rule.
- **Do not release** (`scripts/release.sh`, GitHub releases, version bumps) without explicit approval.
  Next release will be **0.2.0** (only v0.1.0 is published).
- No Russian services/products anywhere (code, site, docs, keywords).
- Yan tests by typing; Claude writes all the code. After a change: build, install, tell him what to test.

## One session per project
- Only one Claude Code session works on ExoKey at a time (other projects — ExoCommander, ExoCalc — have their own).
  Two sessions editing the same repo collide. Commit at the end of each piece of work, so the next session starts clean.
- If a debugging session goes in circles 2–3 times: write what was learned here, then start a fresh session.

## Build & run
```
scripts/build_app.sh --install     # swift build (release, arm64) → build/ExoKey.app → signs → mv to /Applications → opens
```
- Built with Command Line Tools (no Xcode project). SwiftPM: `Package.swift`, sources in `Sources/ExoKey/`.
- Signed with the self-signed identity **"ExoKey Dev"** (keeps macOS permissions between builds), hardened runtime,
  `Resources/ExoKey.entitlements` (addressbook). Build number = git commit count; `VERSION_OVERRIDE=0.0.9` to test the updater.
- Dictionaries `data/dict/*.exd` are not in git: `scripts/fetch_dicts.sh` / `tools/build_dicts.py`.
- Only one instance runs (single-instance guard). Restart: `pkill -x ExoKey; open /Applications/ExoKey.app`.

## Logs & debugging
- Log: `~/Library/Logs/ExoKey.log` (no typed text). Useful greps: `mid fix`, `final fix`, `layout ->`, `mixed scripts`,
  `word continues`, `spell:`, `ai: shown|answer|skip`, `convert:`.
- Context dump: `~/Library/Logs/ExoKey-context-<bundle>.txt`, triggered by the distributed notification `app.exokey.dumpContext`.
  Also `app.exokey.checkUpdates`, `app.exokey.installUpdate`.
- Electron apps (Claude desktop, Codex, Slack…) report the caret/AX text 1–2 chars off — never trust `textBeforeCaret`
  without verifying it ends with what was just typed.

## Architecture (Sources/ExoKey)
- `KeyTap` — CGEventTap (HID level). Synthetic events are tagged (`Injector.tag`) and ignored by the tap.
- `Engine` — the core: word state (`keys` = physical keystrokes), mid-word and end-of-word layout decisions, undo,
  hold logic (`holdUntilSpace`, `disabled`, `continuation`, `startedAfterErase`, mixed-script restore), calculator trigger,
  hotkeys (⌃⌥Z undo, ⌃⌥X convert, ⌃⌥C spell, ⌃⌥R case, ⌃⌥P pause), learning (`learnUnknown`).
- `Layouts` (LayoutManager) — TIS input sources; `select()` marks expected switches; external switches go to `Engine` via `onChange`.
- `KeyLayout` — UCKeyTranslate key→char per layout.
- `WordDictionary` — EXD2 binary dictionaries (mmap, prefix frequencies, `topK`). `SpellIndex` + `SpellFix` — typo hints (plaque, Tab/Esc), revisit-word check.
- `Predictor` — AI ghost text: `readContext`, prompt, stream from `AIModel`, filters (`extract`, `knownWordsOnly`, `repeatsTyped`…), `fallback()`.
  Current behaviour = the early "model leads" logic (Yan rejected dictionary-led suggestions and partial-word ghosts).
- `AIModel` — llama.cpp `llama-server` (b11840) on port 8737, streaming `/completion` with `n_probs`; watchdog restart.
  Models in `~/Library/Application Support/ExoKey/`: `model-fast.gguf` (Qwen3-4B-Instruct-2507 Q4_K_M, default), `model-base.gguf` (experimental).
- `WindowContext` — conversation text around the field (AX tree, pruned; per-pid cache), `ScreenText` — OCR fallback (ScreenCaptureKit + Vision).
- `UserStore` — SQLite: words, exceptions, rules, candidates, phrases, banned, n-gram counts (`NSRecursiveLock`!).
- `Calculator`, `Converter` (units, currencies via open.er-api.com, cached 12 h), `ContactPicker` (@Name), `Selection` (selection read / convert / case),
  `LayoutBadge`, `CaretLocator`, `FieldGuard` (password fields), `Updater` (GitHub releases, SHA-256, replace + relaunch),
  `Settings`/`SettingsView`/`L10n` (UI strings RU/UK/EN — add every new string in all three).

## Tests / tools
- `tools/test/typing_sim.py` — typing simulation of autocomplete (`--no-model`, `--lora`, `--lang`, `--dict`…). Don't `pkill` the app's server in sims.
- `tools/test/spellcheck/main.swift` — standalone SpellIndex check:
  `xcrun swiftc -O -o /tmp/sc tools/test/spellcheck/main.swift Sources/ExoKey/SpellIndex.swift Sources/ExoKey/WordDictionary.swift Sources/ExoKey/Log.swift && /tmp/sc data/dict`
- `tools/dict_rules/{ru,uk,en}.{ban,keep}` — short-word dictionary cleanup; `tools/dump_short.py`.
- `tools/train/` — MLX LoRA experiments (all made suggestions worse; adapters off).

## Site (docs/)
- `docs/index.html` landing (UA/EN/RU switched in JS, GA `G-LW9CL37B92`, events `download_click`, `donate_click`, `promo_click`),
  `docs/guide/{,uk/,ru/}index.html` user guide (generated; keep all 3 languages in sync, mark unreleased features "0.2"),
  `docs/sitemap.xml`, `docs/robots.txt`, `docs/release-notes/<ver>.md`.
- Server `root@2.31.6.223` (nginx, `/var/www/exokey`, cron `git pull` from main) — a push to main deploys the site in ~1 min.
  DNS on Hetzner. Also hosts exocommander.top.
- Promote sister apps: ExoCalc (github.com/jandiradmin/ExoCalc), ExoCommander (https://exocommander.top).

## iPhone keyboard (ios/)
- Prototype of ExoKey for iPhone/iPad as a keyboard extension (UIInputViewController). xcodegen: `ios/project.yml`,
  team RU5B5M38AJ, app group `group.com.jandiradmin.exokeymobile`. Not on the App Store (needs the $99 account).
- Build & install on Yan's iPhone (connected by cable or Wi-Fi):
```
cd ios && xcodebuild -project ExoKeyMobile.xcodeproj -scheme ExoKeyMobile -configuration Release -destination 'id=00008150-000054D23CF0401C' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device 00008150-000054D23CF0401C build/Build/Products/Release-iphoneos/ExoKeyMobile.app
```
- Log: `ios/pull_log.sh` copies the keyboard log from the phone to `ios/keyboard.log` (has typed text — not in git).
- **Lost light taps (solved 2026-11-09):** iOS drops a touch on a fully transparent point of a keyboard extension
  before any view sees it (no hitTest at all). The gaps between keys were `.clear`, so light taps at key edges vanished
  (SwiftKey had none). Fix: `KeyboardView.applyGapFill()` — 2% black fill. **Never make the keyboard background clear.**
  Not the cause (checked): main-thread stalls, the "repeat of the same touch" filter, vibration.
- Space held 0.45 s → cursor mode (slide moves the cursor, 9 pt per character); a quick swipe on space switches the language.
- Haptics (`Haptics.swift`): weak 0.45, medium 0.83 (light generator), strong = medium generator 0.8.
- Next: autocorrect that knows neighbouring keys ("подьзоватлб" → "пользователю" found nothing).
- Next (Yan, 2026-11-10): after "name@" also offer the domain — the most frequent domains among the contacts'
  e-mails ("@gmail.com" …), not a fixed list.

## Homebrew
- Tap `jandiradmin/homebrew-tap` (`brew tap jandiradmin/tap`, `brew trust jandiradmin/tap`, `brew install --cask exokey`).
  After a release: clone it, set `version` and `sha256` in `Casks/exokey.rb`, push. ExoKey is arm64-only (`depends_on arch: :arm64`).

## Git
- Work on `main`; commit only what was asked. Snapshot branch `ai-experiments-2026-11-06`.
- Commit message trailer: `Co-Authored-By: Claude <noreply@anthropic.com>`.
