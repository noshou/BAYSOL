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
| Folders          | Opens or clears the folders (see below).                                                                                                                                                      |
| Uninstall        | Removes the app and the caches; the projects folder stays. A second choice also removes the projects, and then you must type `delete`. Anything else cancels.                                 |
| Quit             | Leaves the wizard.                                                                                                                                                                            |

### What Set up asks

- **Projects folder** (the BAYSOL folder). An existing one is detected and used; only one can exist.
- **Cache** and **structure cache** (the folder of the structure preparation, which the fit reads as `BAYSOL_CACHE`).
- **Threads per fit** (default: the machine's, at most 8, one per chain).
- **What the launcher opens**: the terminal interface (`tui`) or a shell with the command line ready (`cli`). `baysol` and the icon both start whichever you chose here, not always the interface.
- **Shortcuts**: the entry in the application menu, an icon on the Desktop, a taskbar or dock pin (GNOME) and a link on the `PATH`.

Apply keeps an undo journal. An error or Ctrl+C undoes everything it did.

### Folders

- **Open projects**, **Open cache**, **Open structure cache**: the wizard leaves, starts the file manager on the folder if one is installed (Dolphin, Nautilus, Finder, Explorer and so on) and then opens a shell in that folder, the way the terminal interface does.
- **Clear cache**, **Clear structure cache**: empty the folder after you confirm with Clear. Cancel leaves it as it is.
- The **projects folder cannot be cleared** here. It holds your work, so it can only be opened.

## What it writes

`install.json`, in the per-user configuration folder, written last and atomically:


| System  | Folder                                             |
| --------- | ---------------------------------------------------- |
| Linux   | `$XDG_CONFIG_HOME/baysol`, else `~/.config/baysol` |
| macOS   | `~/Library/Application Support/baysol`             |
| Windows | `%APPDATA%\baysol`                                 |

It records `home`, `cache`, `structureCache`, `desktop`, `desktopIcon`, `taskbarPin`,  `pathLink`, `threads` and `opens`. The launcher turns it into `BAYSOL_HOME`, `BAYSOL_CACHE` and `BAYSOL_THREADS`, unless those are already set (a variable you set wins). A change takes effect the next time BAYSOL starts. The wizard also puts the shortcuts in place from the files of the bundle: the icon of this system (`baysol.icns`, or `baysol.ico` on Windows) and the launcher script (`baysol.sh`, `BAYSOL.command` or `baysol.cmd`).

### The icon

`bysl pkg` packs the hand-made PNG sizes of `icons/` (`icon_NxN.png`, `icon_NxN@2x.png`; nothing is resized or generated) into the one icon file at the root of the bundle. On Linux the wizard unpacks each size into `$XDG_DATA_HOME/icons/hicolor/<N>x<N>/apps/baysol.png` (1024 px as `512x512@2`) and the desktop entries say `Icon=baysol`, so the desktop picks the size that fits the place (menu, dock, Desktop) and scales the nearest one for a size that is missing. Without PNG sizes in the file the entries use a generic icon. Repair restores missing sizes, and uninstall removes them again.

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
