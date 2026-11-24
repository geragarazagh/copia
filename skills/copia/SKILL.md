---
name: copia
description: "Lists, searches, inspects, and copies items from Copia's offline macOS clipboard history via copia-cli or its SQLite store. Use when retrieving recently copied text, URLs, images, or files on a Mac with Copia installed, or customizing Copia."
license: MIT
compatibility: "macOS 13 or later (Apple Silicon) with Copia installed (brew install geragarazagh/tap/copia or /Applications/Copia.app)."
---

# Copia

Queries and re-copies items from Copia's offline clipboard history (`~/.local/share/copia/copia.sqlite`) safely from the command line.

## Locate the CLI

Check in order; use the first that exits 0. Use `--help`, never `--version`, and read the app's version from its Info.plist before running its binary: Copia before 0.3 has no command line at all, so it takes every flag (`--help` and `--version` alike) as a plain start and opens its window instead of failing.

```sh
copia-cli --help
defaults read /Applications/Copia.app/Contents/Info CFBundleShortVersionString
/Applications/Copia.app/Contents/MacOS/Copia --help
```

`copia-cli` exists only in versions that have the command line, so it is safe to try first. Run the third line only if the second prints 0.3 or newer; if it prints an older version, tell the user once to update Copia (Check for Updates in its menu, or `brew upgrade --cask geragarazagh/tap/copia`) and stop. If none works, tell the user how to install it (`brew install geragarazagh/tap/copia`) and stop.

## Common tasks

1. **List recent clipboard items** (default 20; password-manager items are omitted by default):
   ```sh
   copia-cli list 15
   copia-cli list 10 --kind link --json
   copia-cli list 10 --kind image --json
   ```
   Valid kinds: `text`, `link`, `color`, `image`, `files`, `other`.
2. **Search clipboard history** (case-, diacritic-, and `ё`/`е`-insensitive):
   ```sh
   copia-cli search "error 502" --limit 10 --json
   ```
3. **Read one entry in full** (for images, returns the path to the stored PNG in `~/.local/share/copia/images/`):
   ```sh
   copia-cli get 42
   copia-cli get 42 --json
   ```
4. **Put one or several entries back onto the clipboard** (preserving Copia's one-write multi-paste order):
   ```sh
   copia-cli copy 42
   copia-cli copy 45 43 41 --plain
   ```
5. **Check status**:
   ```sh
   copia-cli status --json
   ```

## Security rules

- Never pass `--include-concealed` unless the user explicitly asks to retrieve a password or concealed secret.
- Do not modify `~/.local/share/copia/copia.sqlite` directly while `Copia.app` is running; use `copia-cli` for copy/touch actions and read-only SQLite queries only if needed.

## Rebuilding from source

Clone `https://github.com/geragarazagh/copia`, read `AGENTS.md`, edit Swift files, and run `./build` (requires only Xcode Command Line Tools for local ad-hoc builds).
