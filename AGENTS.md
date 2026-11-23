# AGENTS.md — Copia

Offline macOS clipboard manager in plain Swift + AppKit + SQLite WAL (`~/.local/share/copia/`). No Xcode project; `./build` compiles directly with `swiftc`.

## Architecture

- `main.swift` — entry point, `--login`, `--open-at-login`, `--paste-to`, single-instance guard, calls `runCopiaCLI`.
- `cli.swift` — `copia-cli` (`list`, `search`, `get`, `copy`, `status`, `--version`, `--help`) with `answersForItself()` guard and concealed-item protection.
- `store.swift` — SQLite WAL store (`copia.sqlite`, `0700`/`0600`) with `entries`, `reps` (`ON DELETE CASCADE`), `originals`, `settings`, content-addressed `images/` & `blobs/`.
- `model.swift`, `capture.swift`, `link.swift` — pasteboard snapshots, deduplication (`contentKey`), offline link cards (`com.apple.linkpresentation.metadata`), zero-network guarantee.
- `copy.swift`, `paste.swift` — one-write multi-paste (`writeObjects`), concealed/host-only preservation, `CGEventPostToPid` + `--paste-to PID` fresh-process TCC helper.
- `panel.swift`, `place.swift`, `rows.swift`, `preview.swift`, `motion.swift` — Spotlight-style `⌥⌘C` panel, 15 Grids-aligned places with soft-magnet drag, `memmem` parallel search, Quick Look/editable preview.
- `queue.swift`, `deck.swift`, `drag.swift`, `shelf.swift` — `⌃⌥C` Paste Queue floating deck with zero-Accessibility promised-data sequential `⌘V`.
- `browser.swift`, `views.swift`, `settings.swift`, `keys.swift` — Finder-style big window (`⌘,`) and Settings pane.

## Build & Test

- `./build` — builds ad-hoc signed `Copia.app` (`-target arm64-apple-macos13.0`). Works with Xcode Command Line Tools alone (falls back to `iconutil` from `docs/icon.png`). Full Xcode is used for vector `Assets.car` (required when `SIGN_ID` is set).
- `./test unit` — unit tests (store, capture, one-write copy, link cards, facts line).
- `./test` — full test suite.

## Invariants

- **Privacy**: concealed password-manager items (`concealed = 1`) always stay concealed and `currentHostOnly` when copied back; CLI hides them unless `--include-concealed` is passed.
- **Zero network**: no network calls outside Sparkle's EdDSA-verified appcast.
- **UI**: English-only, Liquid Glass on macOS 26+, system accent colour, minimum big-window size `890 × 708 pt` without scrollbars in Settings.
- **Customizing locally**: edit source, run `./build`, replace `/Applications/Copia.app` (your database in `~/.local/share/copia` stays intact).
