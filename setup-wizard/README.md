# BAYSOL setup wizard

`BAYSOLSetup` is the small program behind `baysol setup`. It decides where BAYSOL keeps its data, what the launcher starts and which shortcuts exist, and it repairs, inspects and removes an installation. It is independent of the terminal interface and of the fitting code: it uses only the Julia standard library (`REPL.TerminalMenus`), so it starts at once.

## When it runs

- Automatically on the first start of `baysol`, when there is no `install.json` yet and
  standard input is a terminal.
- By hand with `baysol setup`, or from the main menu of the terminal interface (Shift+A).

It needs a terminal for its menus. Without one it exits with status 1.

## The menu

The menu returns after every step (Cancel included).


| Entry            | What it does                                                                                                                                                                                  |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Set up or change | Asks for the folders, the threads, what the launcher starts and the shortcuts, shows a summary and writes nothing until you choose Apply.                                                     |
| Repair           | Finds a missing or wrong menu entry, Desktop icon, PATH link or `install.json` and rewrites them from the bundle. A missing bundle file is reported, because only a reinstall brings it back. |
| Check dependencies | Looks for the optional things outside the bundle (a LaTeX engine, a sixel terminal) and offers to install what is missing (see below). |
| Folders          | Opens or clears the folders (see below).                                                                                                                                                      |
| Uninstall        | Removes the app and the cache folder; the projects folder stays. A second choice also removes the projects, and then you must type `delete`. Anything else cancels.                                 |
| Quit             | Leaves the wizard.                                                                                                                                                                            |

### What Set up asks

- **Projects folder** (the BAYSOL folder). An existing one is detected and used; only one can exist.
- **Cache folder**: the one cache of BAYSOL, which the launcher exports as `BAYSOL_CACHE`. It holds only what must last: the structures that later runs reuse, the font list and the native files of the app. The temporary files of the terminal interface are not in it (they are in the temporary folder of the system, `<tmp>/baysol`, and are cleared when the interface starts and quits). Nothing clears the cache but this wizard (**Clear cache**, **Uninstall**); the terminal interface and the app never do.
- **Threads per fit** (default: the machine's, at most 8, one per chain).
- **What the launcher opens**: the terminal interface (`tui`) or a shell with the command line ready (`cli`). `baysol` and the icon both start whichever you chose here, not always the interface.
- **Shortcuts**: the entry in the application menu, an icon on the Desktop, a taskbar or dock pin (GNOME) and a link on the `PATH` (Linux and macOS only: on Windows the item is not offered, because a link there needs a privilege and editing the user `PATH` in the registry from here (`setx` cuts it at 1024 characters and flattens `%VARS%`) could damage the whole variable; the Start Menu shortcut starts BAYSOL instead).

Apply keeps an undo journal. An error or Ctrl+C undoes everything it did.

### Folders

- **Open projects**, **Open cache**: the wizard leaves, starts the file manager on the folder if one is installed (Dolphin, Nautilus, Finder, Explorer and so on) and then opens a shell in that folder, the way the terminal interface does.
- **Clear cache**: empties the cache folder after you confirm with Clear (only if it holds BAYSOL's `CACHEDIR.TAG` marker or is empty). Cancel leaves it as it is.
- The **projects folder cannot be cleared** here. It holds your work, so it can only be opened.

### Check dependencies

The packaged app carries its own Julia, Node, 7-Zip and Python tools, so the check never looks for them. It only looks at what is outside the bundle, and everything on the list is optional. It runs once at the end of the first setup and whenever you pick **Check dependencies**. It first scans and prints a report (present, missing, optional, not applicable on this system), then offers to install each missing item with a prompt of its own. Nothing is installed without an explicit yes, and a command that needs administrator rights (`sudo`) is shown for you to run, never run by the wizard.

| Item                  | Kind     | Detection                                                         | Install route                                                                                                                              |
| --------------------- | -------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| LaTeX engine (TeX Live) | optional | `lualatex`, `xelatex` or `pdflatex` on the `PATH`                 | Windows: text only (install-tl, or MiKTeX). macOS: `brew install --cask mactex-no-gui`. Linux: the `texlive` packages with apt, dnf or pacman |
| Sixel terminal        | optional | a hint from `TERM_PROGRAM`, `WT_SESSION`, `TERM`, `KONSOLE_VERSION`   | Windows: `winget` (Windows Terminal). macOS: `brew` (iTerm2). Linux: `foot` with apt, dnf or pacman. Else text                              |
| Truecolor             | info     | `COLORTERM` is `truecolor` or `24bit` (or Windows Terminal)       | none                                                                                                                                       |
| Terminal of 80 x 24   | info     | the size of the window                                            | none                                                                                                                                       |

The LaTeX engine only renders plots to PDF (the `.tex` files are written without it; the minimum a machine needs for rendering, engine, packages, fonts and `pdftocairo`, is listed by `bysl deps`). It is large (gigabytes), and BAYSOL works without it. The terminal interface draws rendered figures with sixel graphics where the terminal supports them and falls back to Unicode plots otherwise. The interface asks the terminal itself when it starts; the wizard cannot do that, so its sixel line is a hint from the environment and from terminals installed on the machine, not a test. A package manager that is not installed (no `winget`, `brew`, `apt`, `dnf` or `pacman` on the `PATH`) gives the manual instructions instead. The package names are not verified on every distribution release.

For a missing optional item the prompt offers **Install now** (only when the command needs no administrator rights), **Not now**, **No** and **Never ask again**. The answers are remembered in `install.json` as `dep.latex` and `dep.sixel` (`yes`, `no`, `later`, `never`). Never is not asked again. No is not asked again at the first run, but the menu entry asks again. Not now, and a failed install, are asked again at the next check. Answers are stored once `install.json` exists (after the first setup); an `install.json` without them is read as no answers.

## What it writes

`install.json`, in the per-user configuration folder, written last and atomically:


| System  | Folder                                             |
| --------- | ---------------------------------------------------- |
| Linux   | `$XDG_CONFIG_HOME/baysol`, else `~/.config/baysol` |
| macOS   | `~/Library/Application Support/baysol`             |
| Windows | `%APPDATA%\baysol`                                 |

The wizard proposes these folders for the projects and the cache (an existing `install.json` is never changed by this). They are the one default of the whole project (`Platform.cache_dir` in `platform.jl`; the terminal interface and the dev tools use the same folders, `cacheFolder` in `tui/src/core/environment.ts` mirrors it and both tests pin the same paths). `_structures` is the cache folder: downloaded and generated structures and components that later runs reuse (plus the interface's font list and native files), what the launcher exports as `BAYSOL_CACHE`, so the fit and the interface use it, also without the wizard. (`_cache` beside it is only the dev tools' place for unpacked test fixtures, `_cache/fixtures/<set>`; the wizard neither makes nor shows it.)

| System  | Projects                                              | Cache folder                                                 |
| ------- | ----------------------------------------------------- | ------------------------------------------------------------------------- |
| Linux   | `$XDG_DATA_HOME/baysol`, else `~/.local/share/baysol` | `$XDG_CACHE_HOME/baysol/_structures`, else `~/.cache/baysol/_structures`  |
| macOS   | `~/Library/Application Support/baysol`                | `~/Library/Caches/baysol/_structures`                            |
| Windows | `%LOCALAPPDATA%\baysol`                               | `%LOCALAPPDATA%\baysol-cache\_structures` (a sibling: Windows has one folder for both, and a cache inside the projects folder would be swept up with the work) |

Uninstall deletes the bundle folder only if it is an absolute folder holding `baysol`/`baysol.exe` that does not contain the home, projects, cache or configuration folder; otherwise it is kept and the log says why. On Windows a bundle that is in use is removed by a detached PowerShell after BAYSOL exits (the path is passed in an environment variable, never in the script text).

It records `home`, `structureCache` (the cache folder; the key keeps its old name so older files and the launcher keep working), `desktop`, `desktopIcon`, `taskbarPin`,  `pathLink`, `threads`, `opens` and the answers about the optional dependencies (`dep.<name>`). An older file that still has a `cache` key is read as it is: the key is ignored and not written back. The launcher turns it into `BAYSOL_HOME`, `BAYSOL_CACHE` and `BAYSOL_THREADS`, unless those are already set (a variable you set wins). A change takes effect the next time BAYSOL starts. The wizard also puts the shortcuts in place from the files of the bundle: the icon of this system (`baysol.icns`, or `baysol.ico` on Windows) and the launcher script (`baysol.sh`, `BAYSOL.command` or `baysol.cmd`).

### The icon

`bysl pkg` packs the hand-made PNG sizes of `icons/` (`icon_NxN.png`, `icon_NxN@2x.png`; nothing is resized or generated) into the one icon file at the root of the bundle. On Linux the wizard unpacks each size into `$XDG_DATA_HOME/icons/hicolor/<N>x<N>/apps/baysol.png` (1024 px as `512x512@2`) and the desktop entries say `Icon=baysol`, so the desktop picks the size that fits the place (menu, dock, Desktop) and scales the nearest one for a size that is missing. Without PNG sizes in the file the entries use a generic icon. Repair restores missing sizes, and uninstall removes them again. After the files are written the wizard runs `gtk-update-icon-cache` (only where the user theme already has a cache) and `update-desktop-database`, each only if installed.

| System  | What the wizard installs for the icon                                                                                             | Status   |
| ------- | --------------------------------------------------------------------------------------------------------------------------------- | -------- |
| Linux   | the hicolor PNGs above and `~/.local/share/applications/baysol.desktop` (`Icon=baysol`, `Exec` the bundle's `baysol`)            | tested   |
| macOS   | `~/Applications/BAYSOL.app`: `Contents/Info.plist` (names the icon), `Contents/Resources/baysol.icns`, a script in `Contents/MacOS` that opens `BAYSOL.command` in Terminal | untested |
| Windows | `baysol.ico` copied beside `install.json` and a Start Menu shortcut `BAYSOL.lnk` to `baysol.exe` (made through PowerShell `WScript.Shell`) | untested |

### The install manifest

Every file and folder the wizard makes for the icons, entries and the PATH link is listed in `install-manifest.txt`, beside `install.json` (`file<TAB>path`, `dir<TAB>path`; folders only the levels that were new). Uninstall removes exactly what the manifest names (folders only when they are empty, a link only when it points into the bundle) and then the manifest. Without a manifest it removes no icons or entries.

## Exit status


| Status | Meaning                                                           |
| -------- | ------------------------------------------------------------------- |
| 0      | Normal exit                                                       |
| 20     | After a setup or repair you chose to start the terminal interface |
| 21     | After a setup or repair you chose the command line                |
| 22     | The app was uninstalled; the caller must not carry on             |
| 130    | Ctrl+C                                                            |
| 1      | No terminal, or an error                                          |

Setting `BAYSOL_NO_LAUNCH=1` skips the "launch" question, which is what the terminal interface does when it starts the wizard.

## Development

The package has no dependencies besides `REPL`.

```bash
# the tests
julia --project=setup-wizard setup-wizard/test/runtests.jl

# try the wizard in a sandbox: a temporary HOME and a stand-in bundle, nothing real is touched
julia --startup-file=no setup-wizard/try.jl
```
