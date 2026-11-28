# BAYSOL setup wizard

`SetupWizard` is the small program behind `baysol setup`. It decides where BAYSOL keeps its data, what the launcher starts and which shortcuts exist, and it repairs, inspects and removes an installation. It is independent of the terminal interface and of the fitting code: it uses only the Julia standard library (`REPL.TerminalMenus`), so it starts at once.

## When it runs

- Automatically on the first start of `baysol`, when there is no `install.json` yet and
  standard input is a terminal.
- By hand with `baysol setup` (`baysol setup --advanced` opens the Advanced menu first), or from the main menu of the terminal interface (Shift+A).

It needs a terminal for its questions. Without one it exits with status 1.

## Questions

Every question is **Yes** or **No** (`Yes/No`, the default in brackets, Enter takes it; `y` and `n` work, anything else is asked again). The only other inputs are the folders and the number of threads (a printed default that Enter takes or that you edit) and one checklist of shortcuts (Enter ticks, `d` finishes). There are no "Not now", "Never ask again" or "Install now" variants. What the wizard cannot install (it needs administrator rights, for example TeX Live) is a printed note, not a question.

### First run

A short linear flow:

1. The settings as plain lines (projects folder, cache folder, threads, what the icon opens, the shortcuts that are on).
2. `Change any of these? (Yes/No)` [No]. Yes asks for the projects folder, the cache folder, the threads and the shortcut checklist; No takes the defaults.
3. `Apply? (Yes/No)` [Yes]. Nothing is written before it.
4. `Start BAYSOL now? (Yes/No)` [Yes]: starts what the icon opens (the terminal interface by default).

The dependency check does not run at the first setup (the interface says at its start what is missing). The terminal of macOS and what the icon opens take their defaults (`auto`, `tui`) and are changed in Advanced.

Defaults: menu entry and PATH link on, Desktop icon and taskbar pin off, no PATH link on Windows (`defaultInstall`).

### The menu

Later visits (`baysol setup`, or Shift+A in the interface) show a menu of four that returns after every step:

| Entry               | What it does                                                                                                                                                                                  |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Set up (Change)     | The same flow as the first run, on the current settings. Writes nothing until you answer Yes to Apply.                                                                                        |
| Advanced            | Repair, Check dependencies, Folders, and What the icon opens and the terminal (see below). `baysol setup --advanced` starts here.                                                              |
| Uninstall           | Removes the app and all of its caches; only the projects folder stays (without the empty `settings.json` the interface makes in it) after a Yes. The second scope also removes the projects, and then you must type `delete`. Anything else cancels. Afterwards nothing of the app is left: not the cache folder (`<cache home>/baysol`), the configuration folder, an empty `<tmp>/baysol`, or on macOS the Dock entry of `org.baysol.app`. Started from the interface, the wizard ends with status 22 and the interface quits. |
| Quit                | Leaves the wizard.                                                                                                                                                                            |

### Advanced

| Entry | What it does |
| ----- | ------------ |
| Repair | Finds a missing or wrong menu entry, Desktop icon, PATH link or `install.json` and rewrites them from the bundle (after a Yes). A missing bundle file is reported, because only a reinstall brings it back. |
| Check dependencies | Looks for the optional things outside the bundle (a LaTeX engine, a sixel terminal, the Terminal font and spacing on macOS) and offers to install what is missing (see below). |
| Folders | Opens or clears the folders (see below). |
| What the icon opens and the terminal | Yes/No: the terminal interface when BAYSOL starts (No: a shell with the command line ready). On macOS, when iTerm2 or WezTerm is installed, a list to pick the terminal of the icon. |

### What the settings are

- **Projects folder** (the BAYSOL folder). An existing one is detected and used; only one can exist.
- **Cache folder**: the one cache of BAYSOL, which the launcher exports as `BAYSOL_CACHE`. It holds only what must last: the structures that later runs reuse, the font list and the native files of the app. The temporary files of the terminal interface are not in it (they are in the temporary folder of the system, `<tmp>/baysol`, and are cleared when the interface starts and quits). Nothing clears the cache but this wizard (**Clear cache**, **Uninstall**); the terminal interface and the app never do.
- **Threads per fit** (default: the machine's, at most 8, one per chain).
- **What the launcher opens** (Advanced): the terminal interface (`tui`) or a shell with the command line ready (`cli`). `baysol` and the icon both start whichever you chose here.
- **The terminal of the icon** (macOS, Advanced; stored as `terminal`): automatic (the first of them that is installed when the icon is opened, else Terminal), one of them, or Terminal.
- **Shortcuts** (the checklist; macOS offers `~/Applications/BAYSOL.app`, a Desktop icon that links to it, and the PATH link; drag BAYSOL to the Dock by hand): the entry in the application menu, an icon on the Desktop, a taskbar or dock pin (GNOME) and a link on the `PATH` (Linux and macOS only: on Windows the item is not offered, because a link there needs a privilege and editing the user `PATH` in the registry from here (`setx` cuts it at 1024 characters and flattens `%VARS%`) could damage the whole variable; the Start Menu shortcut starts BAYSOL instead).

Apply keeps an undo journal. An error or Ctrl+C undoes everything it did.

### Folders

- **Open projects**, **Open cache**: the wizard leaves, starts the file manager on the folder if one is installed (Dolphin, Nautilus, Finder, Explorer and so on) and then opens a shell in that folder, the way the terminal interface does.
- **Clear cache**: empties the cache folder after a Yes to `Clear the cache?` [No] (only if it holds BAYSOL's `CACHEDIR.TAG` marker or is empty).
- The **projects folder cannot be cleared** here. It holds your work, so it can only be opened.

### Check dependencies

The packaged app carries its own Julia, Node, 7-Zip and Python tools, so the check never looks for them. It only looks at what is outside the bundle, and everything on the list is optional. It runs when you pick **Check dependencies** in Advanced (not at the first setup). It first scans and prints a report (present, missing, optional, not applicable on this system), then offers to install each missing item with a prompt of its own, always Yes or No. Nothing is installed without a Yes. Where no answer could install the item (the command needs administrator rights, `sudo`, there is no package manager, or it is a manual step) there is no question: the command or the instruction is shown as a note for you to follow, never run by the wizard.

| Item                  | Kind     | Detection                                                         | Install route                                                                                                                              |
| --------------------- | -------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Homebrew (macOS) | optional | `brew` on the `PATH` or in its own folders | its official installer, after a **Yes** only; it asks for the password itself |
| LaTeX engine (TeX Live) | optional | `lualatex`, `xelatex` or `pdflatex` on the `PATH`                 | Windows: text only (install-tl, or MiKTeX). macOS: `brew install --cask mactex-no-gui`. Linux: the `texlive` packages with apt, dnf or pacman |
| Sixel terminal        | optional | a hint from `TERM_PROGRAM`, `WT_SESSION`, `TERM`, `KONSOLE_VERSION`   | Windows: `winget` (Windows Terminal). macOS: `brew` (iTerm2); without Homebrew the question (Yes or No) runs its official installer (which asks for the password itself) and then installs iTerm2; the download page of iTerm2 is named in the text. An installed iTerm2 or WezTerm counts as present. Linux: `foot` with apt, dnf or pacman. Else text                              |
| Truecolor             | info     | `COLORTERM` is `truecolor` or `24bit` (or Windows Terminal)       | none                                                                                                                                       |
| Terminal of 80 x 24   | info     | the size of the window                                            | none                                                                                                                                       |
| Terminal font (macOS) | optional | Terminal.app only: the profile of the front window uses SF Mono | `osascript` gives that profile Menlo 14 pt, after a **Yes** only. An unreadable font and other terminals are left alone. Undo: Terminal > Settings > Profiles > Text |
| Terminal character and line spacing (macOS) | optional | Terminal.app only: the saved spacing of the front window's profile is not 1.0 | Terminal has no command for it: the question (Yes or No) shows the steps (Settings > Profiles > Text) after a Yes, and nothing is changed by the wizard |

The LaTeX engine only renders plots to PDF (the `.tex` files are written without it; the minimum a machine needs for rendering, engine, packages, fonts and `pdftocairo`, is listed by `bysl deps`). It is large (gigabytes), and BAYSOL works without it. The terminal interface draws rendered figures with sixel graphics where the terminal supports them and falls back to Unicode plots otherwise. The interface asks the terminal itself when it starts; the wizard cannot do that, so its sixel line is a hint from the environment and from terminals installed on the machine, not a test. A package manager that is not installed (no `winget`, `brew`, `apt`, `dnf` or `pacman` on the `PATH`) gives the manual instructions instead. The package names are not verified on every distribution release.

Every question is **Yes** or **No**. The answers are remembered in `install.json` as `dep.brew`, `dep.latex`, `dep.sixel`, `dep.font` and `dep.spacing` (`yes`, `no`, `later`; `never` is only read, from an `install.json` of an older version, which keeps loading, and is never asked again). The questions are typed Yes/No with No as the default. A cancelled question, a failed install and a note are asked again at the next check. Answers are stored once `install.json` exists (after the first setup); an `install.json` without them is read as no answers.

### The welcome icon

A small BAYSOL icon (10 x 5 cells) is drawn on the welcome page with coloured spaces only (truecolor where `COLORTERM` says so, else 256 colours), so no font or glyph matters. Without a terminal, with `NO_COLOR` set or with `TERM=dumb` it is a plain ASCII box with the name and no escape codes.

### The clock

On a terminal of at least 10 rows and 60 columns (and not `TERM=dumb`) a live clock ticks once a second in the last row, right-aligned, in the same text as the interface's clock: `Fri, 27 Nov 2026, 14:03:22-CET (UTC+01:00)` (24-hour time; the weekday, the zone abbreviation and the offset from UTC). The offset is computed from the C library's local time (`localOffsetMinutes`, no time-zone database), the abbreviation is the C library's `%Z`; where that is not a short name (Windows gives `Central European Standard Time`) the clock shows the offset only (`Fri, 27 Nov 2026, 14:03:22 (UTC+01:00)`). Each tick is one write (save cursor, move, text, restore cursor), so it does not move the cursor of a menu or a half-typed line. The clock is paused (and its line cleared) while a program of another kind owns the terminal: applying a setup, the dependency check, opening a folder (a file manager and a shell), and uninstalling. It is stopped and cleared on every exit path (Ctrl+C, an error, an uninstall, a normal end). `runWizard(...; clock = false)` turns it off; without a terminal it never starts. A resize below the minimum clears it.

## What it writes

`install.json`, in the per-user configuration folder, written last and atomically:


| System  | Folder                                             |
| --------- | ---------------------------------------------------- |
| Linux   | `$XDG_CONFIG_HOME/baysol`, else `~/.config/baysol` |
| macOS   | `~/Library/Application Support/baysol`             |
| Windows | `%APPDATA%\baysol`                                 |

The wizard proposes these folders for the projects and the cache (an existing `install.json` is never changed by this). They are the one default of the whole project (`Platform.cache_dir` in `platform.jl`; the terminal interface and the dev tools use the same folders, `cacheFolder` in `tui/src/core/environment.ts` mirrors it and both tests pin the same paths). `_structures` is the cache folder: downloaded and generated structures and components that later runs reuse (plus the interface's font list and native files), what the launcher exports as `BAYSOL_CACHE`, so the fit and the interface use it, also without the wizard. (`_cache` beside it is only the dev tools' place for unpacked test fixtures, `_cache/fixtures/<set>`; the wizard neither makes nor shows it.)

| System  | Projects                                              | Cache folder                                                 |
| ------- | ------------------------------------- |
| Linux   | `$XDG_DATA_HOME/baysol`, else `~/.local/share/baysol` | `$XDG_CACHE_HOME/baysol/_structures`, else `~/.cache/baysol/_structures`  |
| macOS   | `~/Library/Application Support/baysol`                | `~/Library/Caches/baysol/_structures`                            |
| Windows | `%LOCALAPPDATA%\baysol`                               | `%LOCALAPPDATA%\baysol-cache\_structures` (a sibling: Windows has one folder for both, and a cache inside the projects folder would be swept up with the work) |

Uninstall deletes the bundle folder only if it is an absolute folder holding `baysol`/`baysol.exe` that does not contain the home, projects, cache or configuration folder; otherwise it is kept and the log says why. On Windows a bundle that is in use is removed by a detached PowerShell after BAYSOL exits (the path is passed in an environment variable, never in the script text).

It records `home`, `structureCache` (the cache folder; the key keeps its old name so older files and the launcher keep working), `desktop`, `desktopIcon`, `taskbarPin`,  `pathLink`, `threads`, `opens` and the answers about the optional dependencies (`dep.<name>`). An older file that still has a `cache` key is read as it is: the key is ignored and not written back. The launcher turns it into `BAYSOL_HOME`, `BAYSOL_CACHE` and `BAYSOL_THREADS`, unless those are already set (a variable you set wins). A change takes effect the next time BAYSOL starts. The wizard also puts the shortcuts in place from the files of the bundle: the icon of this system (`baysol.icns`, or `baysol.ico` on Windows) and the launcher script (`baysol.sh`, `BAYSOL.command` or `baysol.cmd`).

### The icon

The one icon file at the root of the bundle is, on macOS, the hand-made `icons/icon.icns` copied as it is (pending a check on macOS); on Windows `bysl pkg` packs the hand-made PNG sizes of `icons/` (`icon_NxN.png`, `icon_NxN@2x.png`; nothing is resized or generated) into `baysol.ico`; on Linux it copies those PNGs as they are into the folder `icons/hicolor/<N>x<N>/baysol.png` of the bundle (1024 px as `512x512@2`). On Linux the wizard copies each size into `$XDG_DATA_HOME/icons/hicolor/<N>x<N>/apps/baysol.png` (1024 px as `512x512@2`) and the desktop entries say `Icon=baysol`, so the desktop picks the size that fits the place (menu, dock, Desktop) and scales the nearest one for a size that is missing. Without PNG sizes in the bundle the entries use a generic icon; an older bundle with a `baysol.icns` instead of the `icons` folder still works, the wizard unpacks the sizes of that file. Repair restores missing sizes, and uninstall removes them again. After the files are written the wizard runs `gtk-update-icon-cache` (only where the user theme already has a cache) and `update-desktop-database`, each only if installed.

| System  | What the wizard installs for the icon |
| ------- | ------------------------------------- |
| Linux   | the hicolor PNGs above and `~/.local/share/applications/baysol.desktop` (`Icon=baysol`, `Exec` the bundle's `baysol`) |
| macOS   | `~/Applications/BAYSOL.app`: `Contents/Info.plist` (names the icon), `Contents/Resources/baysol.icns`, a script in `Contents/MacOS` that opens `BAYSOL.command` in Terminal |
| Windows | `baysol.ico` copied beside `install.json` and a Start Menu shortcut `BAYSOL.lnk` to `baysol.exe` (made through PowerShell `WScript.Shell`) |

### The install manifest

Every file and folder the wizard makes for the icons, entries and the PATH link is listed in `install-manifest.txt`, beside `install.json` (`file<TAB>path`, `dir<TAB>path`; folders only the levels that were new). Uninstall removes exactly what the manifest names (folders only when they are empty, a link only when it points into the bundle) and then the manifest. Without a manifest it removes no icons or entries.

## Exit status


| Status | Meaning                                                           |
| -------- | ------------------------------------------------------------------- |
| 0      | Normal exit                                                       |
| 20     | After a setup or repair you answered Yes to starting, and the icon opens the terminal interface |
| 21     | The same, and the icon opens the command line                     |
| 22     | The app was uninstalled; the caller must not carry on             |
| 130    | Ctrl+C                                                            |
| 1      | No terminal, or an error                                          |

Setting `BAYSOL_NO_LAUNCH=1` skips the "Start BAYSOL now?" question, which is what the terminal interface does when it starts the wizard.

## Development

The package has no dependencies besides `REPL`.

```bash
# the tests
julia --project=setup-wizard setup-wizard/test/runtests.jl

# try the wizard in a sandbox: a temporary HOME and a stand-in bundle, nothing real is touched
julia --startup-file=no setup-wizard/try.jl
```
