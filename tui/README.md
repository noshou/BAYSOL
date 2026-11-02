# BAYSOL terminal interface

A terminal front end for BAYSOL: pick a project, edit its settings, and (soon) run fits and
read the results, all from the keyboard. It is plain Clojure on the JVM
([Lanterna](https://github.com/mabe02/lanterna)), and it runs in any terminal that is at
least 80 columns by 24 rows. It looks best with 24-bit colour (most current terminals);
without it the screens are black on white.

> **Status.** The main menu, the settings screens and projects work. The project's
> buffer, run, logs, models and data pages and the help page are not built yet, and the
> fits themselves are still run from Julia. This page will become the landing page, with
> installation and a full walk-through, once those exist.

## Starting it

You need a Java runtime (tested with Java 25) and the Clojure command line tools. From the
`tui/` folder of the repository:

```
clojure -M:run        # the program
clojure -M:test       # its tests
```

If you start it without a terminal (from a desktop icon, say), it opens one for itself.

## The main menu

Move with the arrow keys and press Enter, or press the letter:

| Key | Item | What it does |
| :-- | :-- | :-- |
| `n` | new | asks for a project name, makes the project, opens its menu |
| `l` | load | lists the projects there are; type to narrow the list |
| `o` | open | opens the projects folder in your file manager and starts a shell there |
| `s` | settings | the settings that every project starts from |
| `h` | help | not built yet |
| Esc | quit | |

A project name uses letters, digits, `.`, `_` and `-`, starts with a letter or a digit, has at
most 40 characters and is unique without regard to case. A new project gets an exact copy of
the global settings; its own settings can then differ.

## Settings

The settings are in four groups (output, model, sampler, plots), each a table of pages.

| Key | Does |
| :-- | :-- |
| up, down | the previous and next setting |
| left, right | the previous and next group of settings |
| Enter | edit the setting under the cursor |
| ctrl-s | save every change (a changed value is marked `*` until it is saved) |
| ctrl-u | undo the change of the setting under the cursor |
| ctrl-r | reset the settings of this group to their defaults |
| ctrl-b | back to the menu (changes that were not saved are dropped) |
| Esc | quit the program |

While editing a number, type it and press Enter (Esc gives up). A colour or a font is picked
from a dropdown: type to narrow it, up and down to move, Tab to take the highlighted name,
Enter to pick it, Esc to leave. A choice of a few options (the figure formats) is a row of
tabs: left, right and Tab move, Enter turns one on or off, Esc is done.

Every value is checked as it is entered, and again whenever settings are saved or a project
is opened. A saved value that is not valid is reset to its default, with a note on the page
and a line in `settings.log`. A project's settings reset to the **global** settings, not to
the defaults of the program.

## Where things are kept

| What | Where | Override |
| :-- | :-- | :-- |
| settings and projects | `~/.local/share/baysol` (macOS `~/Library/Application Support/baysol`, Windows `%LOCALAPPDATA%\baysol`) | `BAYSOL_HOME` |
| caches: the font list, downloaded structures | `~/.cache/baysol/_cache` (macOS `~/Library/Caches/baysol/_cache`, Windows `%LOCALAPPDATA%\baysol\_cache`) | `BAYSOL_CACHE` |

The data folder holds `settings.edn` (the global settings) and `projects/<name>/` (a
`project.edn` and the project's own `settings.edn`). The cache can be deleted at any time; it
is rebuilt when needed.

## Fonts

The font settings list the fonts installed on the machine, found in the system font folders,
with `fc-list` where there is one, in the Windows registry, and, if TeX is installed, among
its fonts. A font with an OpenType MATH table is offered as a math font and the others as text
fonts.
