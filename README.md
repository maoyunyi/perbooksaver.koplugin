# AutoScreensaver

**Per-book standby screensaver for KOReader.** Give each book its own screensaver; books you never configure keep using the global one.

**English** · [中文](README_zh-CN.md)

---

## What it does

KOReader ships a single global screensaver setting (what to show when the device sleeps).
This plugin adds a **per-book override** on top of it:

- Show the book's own cover for one manga, a specific image for another, and a random image
  from a folder for a third;
- Books you never configured behave exactly as before — they use the global screensaver;
- The built-in global screensaver menu is left **completely untouched**. The plugin never
  edits your global settings.

## Modes

| Menu item | What this book shows when sleeping |
| --- | --- |
| Follow global settings (current: xx) | Removes the per-book setting; back to the global screensaver |
| Use this book's cover | The book's own cover |
| Use a specific image… | The image you pick (png / jpg, etc.) |
| Use an image folder (random)… | A random image from the folder you pick |
| Leave screen as-is (no screensaver) | Nothing is drawn; the last screen stays as it was |

The five modes are mutually exclusive and switch instantly. **Changing a per-book setting
never touches the global one.**

## Requirements

- KOReader. Tested on **v2026.07.1 (Kindle Paperwhite 6)**.
- Only long-stable public APIs are used (`Screensaver:setup`, `LuaSettings`, the menu API),
  so Kobo / Android / desktop should work as well — but they are untested.

## Installation

1. Download this repository and locate the `autoscreensaver.koplugin` folder —
   **the folder name must end with `.koplugin`**, otherwise KOReader will not load it.
2. Copy the whole folder into KOReader's plugin directory:

   | Platform | Plugin directory |
   | --- | --- |
   | Kindle | `/mnt/us/koreader/plugins/` |
   | Kobo | `.adds/koreader/plugins/` |
   | Others | `plugins/` inside the KOReader data directory |

3. **Restart KOReader**: File manager → top menu → "Exit" section → "Restart KOReader".

Or clone it directly (replace the URL with your own repository):

```bash
cd koreader/plugins
git clone https://github.com/<your-name>/<your-repo>.git autoscreensaver.koplugin
```

## Usage

Open any book → **Settings → Screensaver**. The **first group** in the panel is
"Per-book screensaver (<book name>)":

| Menu item | Description |
| --- | --- |
| Current book: xxx | Tap for the rules; also a quick way to confirm which book you are configuring |
| Follow global settings (current: xx) | Removes the per-book setting; this book goes back to the global screensaver |
| Use this book's cover | Shows this book's own cover |
| Use a specific image… | Pick an image; this book shows it when sleeping |
| Use an image folder (random)… | Pick a folder; a random image from it is shown |
| Leave screen as-is (no screensaver) | Same as the built-in option: nothing is drawn when this book sleeps |
| Clear per-book screensaver settings | Deletes every per-book setting at once |

The group also appears in the **file manager** (without a book name in the title); there it
applies to the book you opened most recently. Opening a book in the reader targets exactly
that book.

## Priority rules

1. The book has its own setting → that setting wins;
2. The book has no setting → the global screensaver is used;
3. The book's image / folder was deleted or is unreachable → falls back to global and logs
   a warning to `crash.log`;
4. **Suspend, power-off and reboot** all follow the same rules;
5. Exception: if you explicitly configured a "power-off screensaver" in the built-in menu,
   that one still wins on power-off (built-in behaviour is preserved as-is).

Presentation options (screensaver delay, message text, background fill, stretch / rotate)
are *not* overridden — they keep following the global settings.

## Configuration file

Settings live in `perbook_screensaver.json` inside KOReader's settings directory. The plugin
owns that file, and it **never writes to a book's sidecar (`.sdr`)**, so copying or syncing
your books will not drag your screensaver settings along.

```json
{
  "version": 1,
  "books": {
    "/mnt/us/koreader/manga/xxx.cbz": { "kind": "cover" },
    "/mnt/us/koreader/books/a.epub":  { "kind": "image", "path": "/mnt/us/screensaver/bg.png" },
    "/mnt/us/koreader/manga/m2/":     { "kind": "folder", "path": "/mnt/us/screensaver/manga" },
    "/mnt/us/koreader/books/b.epub":  { "kind": "disable" }
  }
}
```

Keys are absolute book paths; `kind` is one of `cover` / `image` / `folder` / `disable`
(`disable` means "leave screen as-is" and needs no `path`).

## FAQ

- **The "Per-book screensaver" group is missing** — make sure the folder name ends with
  `.koplugin` and that you restarted KOReader. Also check Settings → Tools → Plugin
  management to see whether the plugin is disabled.
- **Settings saved, but nothing changes on sleep** — search `crash.log` for
  `AutoScreensaver`. Unusable resources log a warning and fall back to global.
- **Will this alter my global screensaver settings?** — No. See "How it works" below.
- **Do I need to restart after switching modes?** — No, changes apply immediately.
- **What if a book is flagged `exclude_screensaver`?** — That is KOReader's own
  document-level setting; the built-in code combines it with "leave screen as-is".
  The plugin does not interfere with that logic.

> Note: the plugin's menu strings are currently **Chinese only**. Contributions with
> gettext-based translations are welcome.

## Uninstall

Delete the `plugins/autoscreensaver.koplugin/` folder and restart KOReader.
You may also delete the leftover `settings/perbook_screensaver.json` (harmless either way).

## How it works

Exactly one place in the whole flow reads the screensaver settings:
`Screensaver:setup(event, event_message)` in `frontend/ui/screensaver.lua`.
The plugin wraps only that one function:

```
save the real global values -> temporarily write this book's values
    -> pcall(the original setup) -> restore the real global values immediately
```

This swap never spans a UI event-loop iteration, so **the global settings on disk are never
modified** — no dirty leftovers after a power cut or after the process is killed by the
system, and no cross-process state is needed.

By contrast, "write the book's value into the global setting when the book opens, and rely
on an in-memory variable to restore it" breaks permanently the moment the process is killed,
and the accounting variable forgets everything on restart. This plugin deliberately avoids
that approach.

## License

Not specified yet. Pick a license (MIT, GPL-3.0, …) and add a `LICENSE` file at the
repository root before publishing.
