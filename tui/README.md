# BAYSOL terminal interface

A terminal front end for BAYSOL: make a project, add its models and its buffer, edit its settings, all from the
keyboard. It is written in TypeScript with [Ink](https://github.com/vadimdemedes/ink) (React for the terminal) and runs in any
terminal that is at least 80 columns by 24 rows. The layout adapts to the size of the terminal: nothing has a fixed width,
lists scroll and text wraps. It looks best with 24-bit colour. Running a fit from here is not built yet.

```bash
cd tui
npm start        # run it (the repository has one node_modules, at its root: `npm install` there once)
npx tsc          # type-check
npm test         # the test suite (takes a few minutes)
```

Started from a launcher with no terminal, it opens a terminal emulator that runs the same program. The release name on the main
menu comes from the repository's `Project.toml`.

## The menus

Move with the arrow keys and press Enter, or press the letter of an option. The hint at the bottom lists the keys that work
from where the cursor is, and nothing else.

| Menu | Options |
| :-- | :-- |
| main | `n`ew project, `l`oad one, `o`pen the projects folder in the file manager (and a shell there), `s`ettings (global), `h`elp (not built), `q`uit |
| project | `m`odels, `d`ata (not built yet), `b`uffer, `g` logs (not built yet), `s`ettings (the project's own), `o`pen (the project folder in the file manager, no shell) |
| settings | `u` output, `m` model, `a` sampler, `p` plots; Ctrl-E (global only) opens the custom solutes and recipes |

A project name uses letters, digits, `.`, `_` and `-`, starts with a letter or a digit, has at most 40 characters and is unique
without regard to case. A new project gets an exact copy of the global settings; its own settings can then differ.

## Keys everywhere

| Key | Does |
| :-- | :-- |
| arrows, Enter | move, select or edit |
| Esc | closes what is open (a prompt, list, question, viewer); it never quits and does nothing at menu level |
| Ctrl-X | back one screen, never quits |
| `q` (main menu), Ctrl-C, Ctrl-D | the only ways to leave the program |
| Shift+R, Shift+Y | project menu taskbar, shown only when they apply: `run: shift+r` (a model and a buffer exist), `results: shift+y` (a finished run exists); placeholders for now |
| Ctrl-W | save every change on the screen |
| Ctrl-U | undo (a removal mark, or the change under the cursor) |
| Ctrl-R | remove a row of the buffer's solutes (marks it, `^w` removes), reset a group of settings, delete (`delete: ^r` in the legend) a project in `load`, a saved recipe, a custom solute or a model: it asks, and Enter deletes at once |
| Ctrl-N, P, F, E | add a non-biological solute, a polymer, a protein, a nucleotide |
| Ctrl-T | open the theme list (light themes, then dark themes, each with its emoji and colour swatches): arrows move, Enter picks, Esc leaves. The theme you leave the program in is the one it starts with (first start: the default theme); the bottom line shows `theme (^t): <name> <emoji>` |

`^s`, `^q`, `^z` and `^y` are taken by the terminal (`^c` and `^d` leave the program); `^m`, `^i` and `^j` arrive as Enter, Tab and Enter.

**Unsaved changes ask** (`discard N changes?`, Enter discards, Esc keeps). **Removing anything you made asks**
(`delete X? this cannot be undone!`, Enter deletes, Esc keeps): a project in `load`, a recipe, a custom solute, a model. The
deletion is immediate after Enter (no mark, no `^w`); a row that was never saved just goes. If the
terminal is made too small the screen waits and comes back as it was when it is big enough again.

## Settings

Four sheets (output, model, sampler, plots), each a table of name, description and value, one group of related settings at a time (sampling, chains, MAP search, ...)
(left and right switch group). Enter edits: a number is typed (Esc gives up), a colour or font is picked from a list (type to narrow,
Tab completes), the figure formats are a row of tabs, a pair like the colour and its opacity is edited part by part. `*` marks a
change that is not saved; Ctrl-W saves them all, Ctrl-U undoes the one under the cursor, Ctrl-R resets the group. Every value is
checked as it is entered and again when settings are saved or a project is opened. An invalid saved value is reset to its default
(in a project: to the global value), with a note and a line in `settings.log`.

## Models and the buffer

- **Models:** type or paste the full path of a `.cif` or `.pdb` file (names are hinted, Tab completes), or press `o` on an empty
  field to pick files in the desktop's file chooser, or `m` to list the project's models. A model is a copy; the original is never
  touched.
- **Buffer:** the solutes of the solution, with concentration in mM and an uncertainty. Add with `^n` (non-biological), `^p` (polymer
  grade or family such as PEG n=22), `^f` (protein sequence file), `^e` (DNA or RNA sequence file). Recipes are named buffers kept
  for every project: load one, save the current buffer as one, or edit them. Custom solutes (your own formula, charge and partial
  molar volume) are under the global settings, Ctrl-E.

## Data

The project menu's `data` option (`d`) takes the measured curve. `load a file` asks for the full path of any delimited text
file (tab, comma, semicolon, pipe or aligned columns; `#` comment lines and an optional header row are skipped) or an `.xlsx`
workbook (its first sheet); names are hinted, Tab completes, `o` on an empty field picks the file in the desktop's chooser. The
first three columns are q, I and sigma; a file that is not a curve (fewer than 3 columns, a cell that is no number, q not above 0
or not increasing, sigma not above 0, fewer than 10 points) shows its reason under the field, naming the row, and changes nothing.
A good file is copied at once as a clean `data.tsv` in the project (three tab-separated columns, no header, no comments, no
units); the original is never touched. Once a file is loaded, `units` (`nm⁻¹` or `Å⁻¹`, left/right/Tab, Enter saves; new data
starts as `Å⁻¹`) and `energy` (the X-ray energy in eV, above 0, no default) are saved at once into `data.json`, never into the
TSV. A project can run only when the data is valid and the energy is set. Data files that cannot be used are told and never
written over: `r` puts them aside as `.corrupt`. Keys: up/down move, Enter does it, Esc closes a prompt, `^x` goes back.

## Where things are kept

| What | Where | Override |
| :-- | :-- | :-- |
| settings, projects, recipes, custom solutes, theme | `~/.local/share/baysol` (macOS `~/Library/Application Support/baysol`, Windows `%LOCALAPPDATA%\baysol`) | `BAYSOL_HOME` |
| caches: the font list, downloaded structures | `~/.cache/baysol/_cache` (macOS `~/Library/Caches/baysol/_cache`, Windows `%LOCALAPPDATA%\baysol\_cache`) | `BAYSOL_CACHE` |

Every file the interface writes is JSON (`settings.json`, `theme.json` (the name of the theme), `buffer.json`, `data.json` (plus the table `data.tsv`), `recipes.json`, `custom-solutes.json`,
`project.json`), written through a temporary file so a reader never sees half a file. A file that cannot be used is told and never
written over (a reset keeps it as `<name>.corrupt`). The cache can be deleted at any time; it is rebuilt when needed.

**Two copies at once are safe.** Saving takes a short lock on the file. Settings changed in two copies are merged (the same setting:
the last save wins); a buffer, recipe or custom-solute list that another copy saved meanwhile is not overwritten (`changed on disk:
another copy of BAYSOL saved it; reopen it`); a project deleted in one copy is not brought back by the other.

## Fonts

The font settings list the fonts installed on the machine, found in the system font folders, with `fc-list` where there is one, in
the Windows registry, and, if TeX is installed, among its fonts. A font with an OpenType MATH table is offered as a math font and
the others as text fonts.

## Status

Built: everything above. Not built: running a fit, the help page, the logs views beyond the lists of runs. The macOS and
Windows parts (file pickers, terminal launching, font discovery) are written from documentation and untested.
`tui/SPEC.md` is the specification of the earlier Clojure version, kept as the reference of its rules and messages.
