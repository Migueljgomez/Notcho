# Working on Notcho (for AI coding agents)

Notcho is a macOS day planner that lives in the MacBook notch, written in Swift with SwiftUI and AppKit. It's a Swift package with one target and no dependencies. The person asking you for changes may not read code: explain what you changed in plain words, and show them how to try it.

## Build and check

```bash
swift build                              # debug build, fast
.build/debug/Notcho --selftest           # must print "selftest ok"
./make-app.sh                            # release build, installed to /Applications/Notcho.app
./make-app.sh release                    # Apple silicon + Intel build, dist/Notcho.zip for GitHub Releases
```

Needs only Apple's Command Line Tools (`xcode-select --install`), macOS 14+. After `./make-app.sh`, quit and reopen the app: `osascript -e 'quit app "Notcho"'; open /Applications/Notcho.app`.

Run the self-test after every change. Add a check to it (in `main.swift`, under `--selftest`) for any new logic that can break quietly, like layout math, saved-data loading or sync rules.

## Where things are

All code is in `Sources/Notcho/`.

| File | What it holds |
|---|---|
| `main.swift` | App start, the notch window, hover/click to open, timers, menu bar menu, the self-test |
| `Views.swift` | The notch: the open workspace and its cards (Tasks, Focus, Notepad, Events, Fridge), the closed-notch timer pill |
| `Theme.swift` | Design tokens: colors, spacing, corner radii, named by meaning. **Start here for a new look or skin.** |
| `Settings.swift` | Every setting, with defaults, including looks (`NotchLook`) and card layout |
| `Customize.swift` | The Customize screen in the Planner, where settings are changed |
| `Planner.swift` | The Planner window: Today, Plan your day, projects, goals |
| `Timebox.swift` | Time blocks on the calendar (a separate "Notch" calendar, never any other) |
| `Store.swift` | The data model and saving (`~/Library/Application Support/Notcho/store.json`) |
| `Notes.swift` | Daily notes and plan pages as Markdown files in iCloud Drive → Notch |
| `Fridge.swift` | Files stuck to the notch (bookmarks to the originals, nothing copied) |
| `Sync.swift` | Phone sync through an Apple Reminders list |
| `Reminders.swift` | Task reminders as macOS notifications |
| `Insights.swift` | Focus stats |
| `Commands.swift`, `Agent.swift`, `MCP.swift` | The `notch://` links, the `notcho` command and the MCP server AI apps use |

## Change freely

Looks, colors, fonts, spacing, wording, layout, new cards, new skins, new settings. To add a skin, add a case to `NotchLook` in `Settings.swift`, give it colors in `Theme.swift`, and it shows up in Customize → Appearance.

## Be careful with

- **Saved data.** People's tasks live in `store.json`. A new saved field must be optional or have a default, and be read with `decodeIfPresent`, so older files still load. Never rename or remove a saved field without a migration. The self-test checks that old data still loads.
- **The self-test never touches real data.** Don't create a `Store()` inside `--selftest`; use temporary files.
- **Other apps' data.** Notcho only writes to its own "Notch" calendar, its own "Notch" Reminders list and its own iCloud Drive → Notch folder. Keep it that way.
- **The MCP tools** (`Agent.swift`, `MCP.swift`) are what people's AI apps rely on. Add tools freely; don't rename or remove existing ones. The server's name in people's configs is `notch`.
- **Battery.** The notch's cards stay alive while it's closed. Anything that repeats (a `TimelineView`, a `Timer`) must pause when the notch is closed: see `notchOpen` in `Views.swift`.

## Making changes

Work on a branch and open a pull request. GitHub runs the build and self-test on every pull request (`.github/workflows/ci.yml`).
