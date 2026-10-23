# ExoKey

Automatic keyboard layout switcher for macOS (English / Russian / Ukrainian) — an open-source analog of Punto Switcher / KeyRay.

Type `ghbdtn` in the English layout — ExoKey turns it into `привет` and switches the layout, after the 3rd letter.

## Features
- Detection by local dictionaries (word + prefix lookup), no cloud, no neural networks
- Works with any installed layouts (ABC, US, Russian, Russian – PC, Ukrainian, …) — key mapping is read from the system
- Undo last correction (⌃⌥Z), manual convert of last word (⌃⌥X), pause (⌃⌥P) — all configurable
- Learning: undone corrections become exceptions, repeated unknown words go to the user dictionary
- Dictionary editor: words, exceptions, rules, candidates; import/export, backup/restore
- Per-app exclusions, secure input (password fields) is never processed
- Interface in Russian, Ukrainian, English; dark theme

## Requirements
macOS 13+, Apple Silicon. Permissions: Accessibility and Input Monitoring.

## Build from source
```
xcode-select --install
scripts/fetch_dicts.sh
scripts/make_dev_cert.sh
scripts/build_app.sh --install
```

## Privacy
Typed text is never stored or sent. Only single words you confirm/learn are kept locally in `~/Library/Application Support/ExoKey/user.sqlite`.

## Dictionaries & licenses
- Word frequencies: [hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords) — CC BY-SA 4.0
- Word forms: LibreOffice hunspell dictionaries (en_US, ru_RU, uk_UA) — see their respective licenses
- ExoKey code: MIT

## Support
If ExoKey is useful to you, donations are welcome (links coming soon).
