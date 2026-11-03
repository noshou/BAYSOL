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
| ctrl-w | save every change (a changed value is marked `*` until it is saved) |
| ctrl-u | undo the change of the setting under the cursor |
| ctrl-r | reset the settings of this group to their defaults |
| ctrl-x | back to the menu; with changes not saved it first asks `discard N changes?` (Enter drops them, Esc keeps editing; the same for Esc when it would quit) |
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

Save is `^w` (Ctrl-W): `^s` is not usable because the terminal's flow control takes it and freezes the screen (`^q` is its pair); `^d`, `^c`, `^z`, `^y` were rejected too.

Back/menu is `^x` (Ctrl-X, 2026-11-02): `^b` was dropped because it is tmux's prefix and `^j` because the terminal sends Enter as the same byte.

## Questions, resets and notes (2026-11-03)

- **Leaving with unsaved changes asks.** The tables (solutes, recipes, custom solutes) show `discard N changes?  enter: discard  esc: keep` in the border row; the settings sheets show it in the description column. Nothing unsaved: no question. An open prompt, flow or edit is dropped first and does not count.
- **A recipe loaded over a buffer that has solutes asks** at the first `^w`: `replace N solutes with recipe "NAME"?` (Enter replaces, Esc keeps editing). An empty buffer is replaced without a question.
- **A `buffer.edn`, `recipes.edn` or `custom-solutes.edn` that cannot be used** is never written over. The landing (buffer; custom solutes and recipes, for the option under the cursor) shows the file's path and `r: reset`; `r` asks, Enter renames the file to `<name>.corrupt` (replacing an older one) and starts empty. The tables of such a file do not invite adding (no `no solutes: ^n ...`, the add legends are blank).
- A solutes table with no row hides the `edit` and `undo` legends.
- A project folder whose `project.edn` is broken is not listed by `load`; the name stays taken: `that name is taken by a broken project folder!`.
- A project whose `settings.edn` was unreadable opens with a box (`settings.edn was unreadable: global settings used, old file kept as settings.edn.corrupt`), once.

### Wide text, caps and pasted paths (2026-11-03)

- Names and paths are measured in terminal cells, not characters: a Japanese or emoji
  character takes two cells, a combining mark none, and no cell, box or dropdown is pushed
  out of its border by one (`text.clj`: `display-width`, `take-width`, `splice-width`).
  Text that is cut never splits a wide character; the cell it would cross is a space.
- A cap on typing is told, never silent: a name or text at its limit answers a further
  character with `name too long (40 at most)`, a number in a settings sheet with
  `16 digits at most`. A whole-number setting is also refused beyond 15 digits.
- A path typed or pasted into the models or sequence prompt is trimmed of blanks and a
  trailing newline before it is used.
- End of input (the terminal going away) in the main menu's name prompt or project list
  ends the program, as everywhere else.

- In the models list `^r` removes the model under the cursor (after a warning; the Delete key works too), as `^r` removes a row in the tables. The custom-solute forms show `menu: ^x` in their footers. A note on a table's bottom border never covers a junction of the rule.
