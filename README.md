<p align="center">
  <img src="docs/assets/icon-256.png" width="128" height="128" alt="MDown icon">
</p>

<h1 align="center">MDown</h1>

<p align="center">
  The Markdown editor for working with AI.<br>
  Free, open source, and native Swift.
</p>

<p align="center">
  <a href="https://mdown.sandeepgangarapu.com">Website</a> ·
  <a href="https://github.com/sandeepgangarapu/mdown/releases/latest/download/MDown.dmg">Download for Mac</a>
</p>

![MDown with an agent brief open. One paragraph shows its Markdown while the rest of the page stays typeset.](docs/assets/screenshot-light.png)

Prompts, agent briefs, specs, and model output are all Markdown. The editors around it are either bloated or complex. MDown is a small native Mac app that keeps the page readable and puts the Markdown one click away.

## What it does

- **Edit in place.** The page stays typeset. Click any block to edit its Markdown right where it is, then click away or press Escape and it sets again.
- **Your files stay files.** Plain `.md` files on disk. No database, no account, no sync service. Git, your terminal, and your AI tools read the same file you do.
- **Writes like a word processor.** Return starts a new paragraph or list item, Return on an empty item ends the list, Tab nests a list item, and the arrow keys move between blocks.
- **Every open file in view.** The sidebar lists your open documents, the current document's headings, and recent files.
- **Shortcuts you already know.** Title (⇧⌘T), Heading (⇧⌘H), Body (⇧⌘B), Checklist (⇧⌘L), Bold (⌘B), Link (⌘K), and Find (⌘F), the same as Notes.
- **Native.** SwiftUI and AppKit, system colors, light and dark appearance, and a 7 MB universal app.

## Install

1. [Download MDown.dmg](https://github.com/sandeepgangarapu/mdown/releases/latest/download/MDown.dmg).
2. Open it and drag MDown to Applications.
3. Open MDown from Applications.

MDown needs macOS 26 or later and runs natively on Apple silicon and Intel.

MDown isn't notarized by Apple yet, so macOS stops it the first time you open it. Open System Settings, go to Privacy & Security, and click Open Anyway next to MDown. You only need to do this once.

## Build from source

You need Xcode 26 or later.

```sh
git clone https://github.com/sandeepgangarapu/mdown.git
cd mdown
open MDown.xcodeproj
```

Choose the MDown scheme and run it.

Run the tests for the Markdown engine and editing rules:

```sh
swift test --package-path MDownCore
```

Build the DMG (needs `pip install dmgbuild`):

```sh
Packaging/make-dmg.sh
```

## Project layout

| Folder | What's in it |
| --- | --- |
| `MDown/` | The Mac app: SwiftUI views, the inline block editor, sidebar, toolbar, and menus |
| `MDownCore/` | A Swift package with the Markdown model, formatting actions, editing rules, and their tests |
| `Packaging/` | The DMG layout and background |
| `docs/` | The website at [mdown.sandeepgangarapu.com](https://mdown.sandeepgangarapu.com) |

MDown parses Markdown with Apple's [swift-markdown](https://github.com/swiftlang/swift-markdown).

## License

MDown is available under the [MIT License](LICENSE).
