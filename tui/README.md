# BAYSOL terminal interface

The terminal interface (TUI) is a full-screen program for using BAYSOL without writing code: you make a
**project**, put its 3D model, its measured curve and its buffer into it, press one key to fit, and read the
results in the same window. It is written in TypeScript with [Ink](https://github.com/vadimdemedes/ink) (React
for the terminal) and runs in any terminal of at least **80 columns by 24 rows**; nothing has a fixed width,
lists scroll and text wraps. It looks best with 24-bit colour. The fit itself is the Julia package: the
interface starts Julia as a child process, shows its output live, and reads the files it writes.

This page is the user guide and the reference; the last section is for contributors. The same steps, shorter,
are in the first guide of the repository's main README.

## Contents

- Install and start
- A first session in ten steps
- Screens and keys: the main menu, the project menu, models, data, buffer, logs, settings, run, results
- Keys at a glance
- Files on disk, with examples
- Two copies at once
- If something goes wrong
- For contributors

## Install and start

You need **Julia 1.12**, **Node.js 22 or newer** (`node --version`) and a BAYSOL folder that contains `tui/`.
The repository has **one** `node_modules`, at its root: `tui` is an npm workspace of the root `package.json`.

```bash
cd BAYSOL                  # the repository root
npm install                # once, here, not in tui/
julia --project=. -e 'using Pkg; Pkg.instantiate(); using BAYSOL'   # once: the fitting code
cd tui
npm start                  # every time (runs `tsx src/main.tsx`)
```

The `julia` line downloads and compiles BAYSOL (several minutes) so that the first fit is not the one that waits;
a first fit also downloads the helper programs PROPKA and pdb2pqr and needs internet. A run starts
`julia --startup-file=no --color=no --threads=auto,1 --project=<repository root> ...`; the program is `julia` on
the PATH, or the one named by the environment variable `JULIA`.

Started with no terminal (a pipe, a launcher) the program prints `BAYSOL: this program needs a terminal` and
stops. Made smaller than 80 x 24 it shows a message in place of the screen and returns to the same screen when
the terminal is big enough again. The release name on the main menu comes from the repository's `Project.toml`.

**The data folder** holds everything you make. It is chosen like this:

| System | Data folder | Cache of downloaded structures |
| :-- | :-- | :-- |
| any, if `BAYSOL_HOME` / `BAYSOL_CACHE` is an absolute path | `$BAYSOL_HOME` | `$BAYSOL_CACHE` |
| Linux and others | `$XDG_DATA_HOME/baysol`, else `~/.local/share/baysol` | `$XDG_CACHE_HOME/baysol/_cache`, else `~/.cache/baysol/_cache` |
| macOS | `~/Library/Application Support/baysol` | `~/Library/Caches/baysol/_cache` |
| Windows | `%LOCALAPPDATA%\baysol` | `%LOCALAPPDATA%\baysol\_cache` |

A relative path in an environment variable is ignored. The folders are made on first use. The cache can be
deleted at any time; it is rebuilt when needed. To try the program without touching your real work, start it as
`BAYSOL_HOME=/tmp/baysol-try BAYSOL_CACHE=/tmp/baysol-try-cache npm start`.

The macOS and Windows parts (the desktop file chooser, also of the references, opening a folder in the file manager, stopping a run on
Windows) are written from the systems' documentation and are **untested**. The rest behaves the same everywhere.

## A first session in ten steps

1. `npm start`. On the main menu press `n`, type `demo`, press Enter: the project menu opens.
2. `m` (models): paste the full path of a `.cif` or `.pdb`, press Enter. `^x` goes back.
3. `d` (data), `load a file`: paste the path of your curve, Enter; check the three columns in the preview;
   press `^w`.
4. On the data screen, set `units` (Enter turns nm⁻¹ and Å⁻¹) and `energy` (eV).
5. `^x`, then `b` (buffer), Enter on `buffer`: `^g` for the pH (`7.4 0.1`), `^n` for each solute (name, concentration, ±;
   `^k` turns the unit), `^w` to save.
6. `^x` to the project menu. A `run: shift+r` item appears at the bottom once everything is there.
7. Press `Shift+R`, accept or change the temperature, press Enter.
8. Watch the run screen. When it says `done`, press Enter.
9. `o` (open...), `open runs`, Enter on the model: the results workbook. `^p` shows the plots.
10. `^l` on a run reads its log; `^x` goes back; `^x` again and `q` on the main menu quits.

## Screens and keys

### Moving around

Move with the arrow keys and press Enter, or press the hotkey of an option. The hint at the bottom lists the keys
that work *from where the cursor is*, and nothing else; the footer's height depends on the screen only, so the
logo at its left never jumps. The table-style screens (the buffer table, the custom solutes table and forms,
the settings sheets, the logs pages) are blocky: the blocky logo, double-line tables, the footer in a double-line box.
Every other screen is smooth: the rounded logo, rounded panels, thin single-line tables.

- **Esc** closes what is open (a prompt, a list, a question, a pager). It never quits and does nothing at
  menu level.
- **Ctrl-X** goes back one screen, from any mode. It never quits.
- **`q`** on the main menu, **Ctrl-C** and **Ctrl-D** are the only ways to leave the program. Ctrl-C and Ctrl-D
  first stop a run that is going, then leave.
- **Ctrl-T** opens the theme list on any screen (also during a run).
- `^s`, `^q`, `^z` and `^y` are taken by the terminal; `^m`, `^i`, `^j` arrive as Enter, Tab and Enter.
- **Unsaved changes ask** (`discard N changes?`: Enter discards, Esc keeps) when you leave a screen with
  unsaved changes. **Removing anything you made asks** (`delete X? this cannot be undone!`: Enter deletes,
  Esc keeps).

### The theme list (`^t`)

All 20 themes at once, alphabetical, each with an emoji, four colour swatches and its mode: `abyssal`,
`arboreal`, `autumn`, `citron`, `graphite`, `holograph`, `invert`, `lavender`, `luxe`, `mate`, `onigiri`,
`pamplemousse`, `parchment`, `rose`, `syrah`, `terracotta`, `tweedia`, `ultrapink`, `ursus`, `vt100` (ten light,
ten dark). Arrows move, Enter picks, Esc or `^t` leaves. The pick is saved by name in `theme.json` and is the
theme of the next start; the bottom right of every screen reads `theme (^t): <name> <emoji>`.
The program only paints cells; it never changes your terminal's own colours.

### The main menu

```
                █████╗   ████╗  ██╗   ██╗ █████╗  ████╗  ██
                ██╔═██╗ ██╔═██╗ ╚██╗ ██╔╝ ██╔══╝ ██╔═██╗ ██
                █████╔╝ ██████║  ╚████╔╝  █████╗ ██║ ██║ ██
                ██╔═██╗ ██╔═██║   ╚██╔╝   ╚══██║ ██║ ██║ ██
                █████╔╝ ██║ ██║    ██║    █████║ ╚████╔╝ ████╗
                ╚════╝  ╚═╝ ╚═╝    ╚═╝    ╚════╝  ╚═══╝  ╚═══╝
                              v0.4.0 yals-n-gɛsga
   ╭─╮  ╔╗╦╔═╗╦ ╦ ┌╴┌┐╷╶┐                       ╦  ╔═╗╔═╗╔╦╗ ┌╴╷  ╶┐
   │▶│  ║║║╠╣ ║║║ │ │└┤ │                       ║  ║ ║╠═╣ ║║ │ │   │
   ╰─╯  ╝╚╝╚═╝╚╩╝ └╴╵ ╵╶┘                       ╩═╝╚═╝╩ ╩═╩╝ └╴└─╴╶┘

        ╔═╗╔═╗╔═╗╔╗╦    ┌╴┌─┐╶┐                 ╔═╗╔═╗╔╦╗╔╦╗╦╔╗╦╔═╗╔═╗ ┌╴┌─┐╶┐
        ║ ║╠═╝╠╣ ║║║    │ │ │ │                 ╚═╗╠╣  ║  ║ ║║║║║ ╦╚═╗ │ └─┐ │
        ╚═╝╩  ╚═╝╝╚╝ooo └╴└─┘╶┘                 ╚═╝╚═╝ ╩  ╩ ╝╝╚╝╚═╝╚═╝ └╴└─┘╶┘
        ╦ ╦╔═╗╦  ╔═╗ ┌╴╷ ╷╶┐                    ╔═╗ ╦ ╦╔╔╦╗ ┌─┌─┐ ┐
        ╠═╣║╣ ║  ╠═╝ │ ├─┤ │                    ║ ║ ║ ║║ ║  │ │ │ │
        ╩ ╩╚═╝╩═╝╩   └╴╵ ╵╶┘                    ╚═╩═╚═╝╩ ╩  └─└─┴╴┘

                           ╭─────────────────────────╮
                           │                         │
                           │move:     →     select: ⏎│
                           │        ↓                │
                           ╰─────────────────────────╯
                                                        theme (^t): holograph 🌃
```

The options are drawn as pictures (new project, load project, open, settings, help, quit), two to a row:

| Option | Hotkey | Does |
| :-- | :-- | :-- |
| new project | `n` | asks for a name (`create: ⏎`, `cancel: esc`) and opens the project menu |
| load project | `l` | a list of your projects; Enter opens one, `^r` (or Delete) deletes the highlighted one after a question, Tab completes a typed name. With no project: `no projects to load!` |
| open | `o` | opens the **data folder** in the file manager and gives you a shell in it; leave the shell to come back |
| settings | `s` | the **global** settings sheets (see Settings) |
| help | `h` | a placeholder: `help is not built yet` |
| quit | `q` | leaves the program |

A project name uses letters, digits, `.`, `_` and `-`, starts with a letter or a digit, has at most 40
characters, and is unique without regard to case. A new project gets an exact copy of the global settings; its
own settings can then differ. A name that is taken, or a folder that cannot be made, is told under the prompt.

### The project menu

The options are pictures, two to a row (three rows), under `project: <name>`:

```
   models        data
   buffer        logs
   settings      open...
```

| Option | Hotkey | Does |
| :-- | :-- | :-- |
| models | `m` | the models of the project |
| data | `d` | the measured curve |
| buffer | `b` | the buffer, its pH, the custom solutes and the recipes |
| logs | `g` | the runs of the project: read a run's inputs and logs, restore them (see Logs). With no run yet: `no runs yet` |
| settings | `s` | the project's own settings sheets |
| open... | `o` | with no run yet: opens the project folder in the file manager. With a run: a small list, `open project folder` and `open runs` |

The **taskbar** at the bottom right shows an extra item only when it applies, reached by its Shift key:
**`run: shift+r`** appears when the project has a model, a buffer (at least one solute and a pH) and valid data
with its energy. There is no Shift+D; lower-case `d` is only `data`.

### Models

`models` takes the **full absolute path** of a `.cif` or `.pdb` file. Names are hinted as you type and Tab
completes. The file is **copied** into the project's `models/` folder (`copied lyz.cif`); the original is never
touched, and an existing name is never overwritten. A project can hold several models; a run fits each in turn.

| Key | Does |
| :-- | :-- |
| `o` (on an empty field) | pick files in the desktop file chooser |
| `m` (on an empty field) | list the project's models (`models (N): m`) |
| `^r` or Delete (on the list) | delete the highlighted model after a question |
| `^o` (on the list) | the **settings of the highlighted model** (below) |

**Settings of one model.** On the list `^o` opens the settings of the highlighted model: the same sheets as the
project's, but only the settings that can differ from model to model (`output` has only `VAL_SIGMA` and `plots` is
not offered: the figures' look, `TABLE_SIGFIGS` and `FIGURES_*` are settings of the whole run, so a model cannot
have them). The title says `model: <name>`. Every setting shows its value and, in the last column (headed `here`), `overridden`
(the model's own, in the full colour) or `inherited` (the project's value, muted). Edit as on any sheet: a value
that differs from the project's becomes an override, a value equal to it removes the override (so the file stays
sparse), `^u` undoes the change under the cursor and **`^r` (`inherit group`) gives the group the project's values
again**. `^w` saves into `model-settings.json` of the project (only the changed settings of this model, under a
lock, over the file as it is then; another copy's changes to other settings or models are kept). In the list a
model with overrides has a `*` and the note under the list says `overrides: Q_MAX, N_CHAINS`. A model that is
renamed or deleted leaves its table in the file (a run ignores it with a note); the program never removes it. An
invalid value, or a setting of the whole run, found in the file is wiped when the model's sheet opens (one line in
`settings.log`, `model <name>: <SETTING>`). An override stays when the project's own value changes later, even when
it comes to equal it (only an edit to the project's value, or `inherit group`, removes it), unless the two then
break a rule (a model's `Q_MIN` above the project's `Q_MAX`): that override is wiped.

### Data

The `data` screen has five options: `load a file`, `change the columns`, `units`, `energy`, `reference fit`. Before a
file is loaded it says `no data yet`.

**`load a file`** asks for a path (names hinted, Tab completes, `o` on an empty field opens the file chooser).
Any delimited text file (tab, comma, semicolon, pipe or aligned columns: `.dat`, `.csv`, `.tsv`, `.txt`, anything)
or an `.xlsx` workbook (its first sheet) is accepted. The **import screen** opens:

```
 data · demo · SASDMJ9.dat

 ╭────────────────────────────────╮ ╭─────────────────────────────────────────╮
 │ > separator auto (whitespace)  │ │     line │ col:1  │ col:2  │ col:3      │
 │   comments  on                 │ │ ─────────┼────────┼────────┼────────    │
 │   skip rows 0                  │ │        6 │ 0.671… │ 0.226… │ 0.174…     │
 │   header    auto (no)          │ │        7 │ 0.698… │ 0.222… │ 0.142…     │
 │   I(q)      col:2              │ │        8 │ 0.725… │ 0.180… │ 0.121…     │
 │   q         col:1              │ │        9 │ 0.753… │ 0.226… │ 0.103…     │
 │   sigma     col:3              │ │       10 │ 0.780… │ 0.174… │ 0.908…     │
 ╰────────────────────────────────╯ ╰─────────────────────────────────────────╯









 ╭╮ ╭╮╷ ╷╭╮╭╮╷
 ├┴╮├┤╰┬╯╰╮│││    import: ^w   ┃ move: ↓ tab
 ╰─╯╵╵ ╵ ╰╯╰╯╰─   change: ⏎ ←→ ┃ back: ^x
```

| Option | Values | Notes |
| :-- | :-- | :-- |
| `separator` | auto, tab, comma, semicolon, whitespace | not shown for an `.xlsx`; `auto` tries tab, comma, semicolon, pipe and runs of blanks |
| `comments` | on, off | lines starting with `#`, `;`, `%` or `!` are skipped |
| `skip rows` | a number | counts every line of the file; Enter opens a prompt |
| `header` | auto, yes, no | auto: the line above the data is the header if it has as many fields as the data |
| `I(q)`, `q`, `sigma` | a number, `col:N` or a header name | Enter opens a prompt with suggestions (case-insensitive, Tab completes); sigma is required |

Enter or the left and right arrows cycle a choice. Up and down, or **Tab** (down) and **Shift+Tab** (up), move
through the options and stop at the ends; in a prompt Tab completes as before. **How the data are found:** they start at the first line that
splits into at least two numbers and end at the first line that is not a data row (a footer); everything before
is header text. So the five header lines of a SASBDB `.dat` file need no `skip rows` (the preview above starts
at line 6); use `skip rows` when a header contains numbers. The right panel is a live preview with the file's own
line numbers, and the three chosen columns come first. The columns start as a guess (known names such as `q`,
`I`, `error`, `sigma`, then the order) until you type one.

**`^w` imports.** The first problem stops the import with one message and writes nothing:

| Message | Cause |
| :-- | :-- |
| `line 7, column err: "abc" is no number` (`row` for a workbook) | a cell of a chosen column is not a number |
| `no value` | an empty cell |
| `q must increase` | a q that goes back (an exactly repeated row is dropped, not an error) |
| `only N points: need 3` | fewer than 3 points |

Rows whose q or sigma is not above 0, and rows repeated exactly (real files have them: SASDCQ2 repeats one), are
dropped and counted; the note says `loaded 4 points, dropped 2 rows (bad q or sigma)`. The import writes a **clean `data.tsv`** in the project (three tab-separated columns q, I, sigma,
one measurement per row, no header, no comments, no unit text); your file is never touched. Afterwards:

```
 data · demo

 ╭────────────────────────────────────────────────────────────────────────────╮
 │ points   2048                                                              │
 │ q range  0.067102 to 5.6685 nm⁻¹                                           │
 │ source   …/files/SASDMJ9.dat                                                │
 │ columns  I(q)=col:2, q=col:1, sigma=col:3                                  │
 │ read as  auto, skip 0, comments on, header auto                            │
 │ units    nm⁻¹                                                              │
 │ energy   12000 eV                                                          │
 ╰────────────────────────────────────────────────────────────────────────────╯

   load a file
   change the columns
   units
 > energy



                  energy 12000 eV saved
 ╭╮ ╭╮╷ ╷╭╮╭╮╷    back: ^x
 ├┴╮├┤╰┬╯╰╮│││    select: ⏎
 ╰─╯╵╵ ╵ ╰╯╰╯╰─   move: ↑↓
```

- **`units`**: Enter turns the unit of q between `Å⁻¹` and `nm⁻¹` and saves it at once into `data.json` (the
  TSV is never rewritten). A new curve starts as `Å⁻¹`. Julia divides q by 10 when it reads nm⁻¹.
- **`energy`**: the X-ray energy in eV, above 0, saved at once. There is **no default**.
- **`change the columns`** reopens the import on the stored source with the stored choices. If the source file
  is gone it says `source is gone: <name>`; an old `data.json` without a mapping says `no source recorded:
  load a file`.

- **`reference fit`** opens the list of the project's **reference curves** (the depositor's CRYSOL or FoXS fit, ...)
  that a run draws in its comparison figure. They are the files of `<project>/reference-fit/` (the folder was `references/` before 2026-11-09: when the list or an add finds only the old one it is renamed, nothing is lost, and a run snapshot with only `logs/references/` is still read by Julia). The summary of the data
  screen says `reference fit  2 (name1, name2)` when there are some. The list opens at any time, but adding needs data
  (`import the data first`), because a reference is in the **same units as the data** (`units` turns them for
  both). The list shows each curve's name,
  its points (those with q and I above 0, the ones a run draws) and its q range. `^n` adds one: a path prompt as for
  `load a file`, then the same import screen (titled `reference fit`, the units in its subtitle) with roles `q` and
  `I(q)` and an optional `sigma`. The columns start as the depositors' fit files come: `q` is `col:1`, `I(q)` is
  `col:3` (the model's intensity; a table of two columns takes `col:2`) and `sigma` is `none` (a chosen sigma is
  written, but a run reads and ignores it); the preview rounds numbers to five digits. `^w` adds. Rows with q (or a chosen sigma) not above 0 are dropped as in the data import, at least 3 points are
  needed. The file written is clean: `<name>.tsv`, two or three tab-separated columns, no header. The name is the
  source's file name without its extension, with every character that is not a letter, digit, `-`, `_` or `.` made
  `_`; a taken name gets `-2`, `-3`, ..., so nothing is ever overwritten. `^r` (or Delete) deletes the highlighted
  one after the question. A file in the folder that a run could not read is listed as `unusable` (its reason, such
  as `line 3: a cell is no number`, is the note when it is highlighted) and is never changed by the program; put
  the files there by hand if you like (`.tsv`, `.dat`, `.txt`, two or three numeric columns). A run copies the folder, `model-settings.json` and `model-references.json`, into its
  run folder with the other inputs (the curves as `reference-fit-<file>`).

- **A wrong file or wrong columns is a warning, never a stop.** The note line says so while the columns are
  chosen and again after the import: `sigma is about I: a fit file? wrong file?` (the `sigma` column of a
  measured curve is as big as I(q) and follows it: a SASBDB `.fit` file read as q, I, sigma, whose third column is
  the model); for a reference fit, `same numbers as the data: the model column?`, `5.2x off the data: wrong
  column?` (the median distance from the measured curve on its q) or `q range does not meet the data: units?`.

- **The reference curve of one model.** On the models list `^f` (`reference`) opens the model's reference fit:
  `model` (its file), `curve` (one of the project's reference curves or `none`; left, right or Enter go through them),
  `software` (`MultiFoXS 2-state`), `tag` (`fit3_model1`), `chi2` (the depositor's, with its method:
  `MultiFoXS 2-state 0.79`) and `rescale` (scale the curve onto the data by least squares, for a normalized fit).
  Every change is saved at once into `<project>/model-references.json` (`{"<model>": {"tag", "software",
  "ref_chi2", "fit", "rescale"}}`, sparse; the columns and units of the curve were chosen when it was imported).
  A run then draws, on that model's figure (`<model>_comparison.tex`), the data, the reference curve (`software tag
  (chi2)` in the legend) and the MAP curve with its own χ², and writes `ref_chi2` in the model's LOG.

A project can run only with valid data **and** an energy. A data file that cannot be used is told, never
written over, and `r` puts it aside as `.corrupt`.

### Buffer

`buffer` is a small page with up to five rows, `buffer (N solutes)`, `custom solutes (N)`, `load a recipe`,
`new recipe` and, for a buffer that has solutes, `save current recipe globally`, and a one-line status of
each file (`buffer: none yet`, `pH not set`, `buffer: unusable!`). `r` on an unusable file offers to reset it.

**Recipes** are named buffers kept in the data folder (`recipes.json`, shared by every project). `save current
recipe globally` asks a name (`replace "NAME"?` if one has it) and saves the buffer as it is on disk, with its
pH and σ. `load a recipe` lists the saved recipes with their solute counts (`^r` deletes the highlighted one,
after a question) and opens the buffer table with the recipe's rows as unsaved ones (`*`); the recipe's pH and σ,
when it has them, come in as an unsaved change of the pH row (a recipe without leaves the buffer's own). At the
first `^w` a buffer that has solutes asks `replace N solutes with recipe "NAME"?`. `new recipe` opens the table
empty and replaces nothing before `^w`. Nothing is written before `^w`; the recipe is copied, not linked. The
unit `^k` is not part of a recipe. **Global settings** has two more options under the four groups: `recipes` (`y`) and `solutes` (`t`) open the recipes table and the custom solutes table; `r` on an option whose file cannot be used offers to reset it (the old file stays as `<name>.corrupt`).
In the recipes table, the custom solutes table and the buffer table, `/` finds a row by name (type part of it, `⏎` puts the cursor on it) and `s` puts the rows in alphabetical order (shown only while they are not); the recipes and the custom solutes also open in that order. The `r` reset legend shows only on the row whose file cannot be used. The path prompts (data, reference fit, models) are boxed like the other dropdowns.
The recipes table has the columns name, solutes, kinds (`3 solute 1 polymer 2 custom 4 seq`), pH and σ (blank for
a recipe without); Enter asks the name (prefilled: the rename) and opens the recipe's own solutes table (its pH
row too); `^n` a new recipe, `^r` deletes (after a question, at once), `^u` undoes, `^w` saves, `^x` goes back.

**The solutes table** has a pH row above the solute rows, then one row per solute:

```
 buffer · demo

     pH         │ σ
 ───────────────┼────────────
     7.4        │ 0.1

     solute                │ params                       │    [mM] │   ±[mM]
 ──────────────────────────┼──────────────────────────────┼─────────┼─────────
 >   nacl                  │ n/a                          │     200 │      10


 ╭╮ ╭╮╷ ╷╭╮╭╮╷    back: ^x       ┃ add polymer: ^p ┃ edit pH: ^g
 ├┴╮├┤╰┬╯╰╮│││    edit: ⏎        ┃ add protein: ^f ┃ remove: ^r
 ╰─╯╵╵ ╵ ╰╯╰╯╰─   add solute: ^n ┃ add DNA/RNA: ^e
```

Concentrations are in **mM** and `±` is their uncertainty (headers `[mM]`, `±[mM]`). `^k` turns the unit mM,
M, µM, mM...: the headers, the cells, the prompt labels (`µM:`) and what you type follow it; the file keeps
mM, and a cell that does not fit shows as `1.37e-1` (the digits that fit, never ambiguous). The unit is kept
while the program runs; an unsaved draft is unchanged by the switch. A `*` marks a change that is
not saved; `^w` saves everything, `^u` undoes the change under the cursor or a removal mark, `^r` marks a row
for removal (the mark goes at `^w`), Enter edits a cell.

| Key | Adds | Flow |
| :-- | :-- | :-- |
| `^n` | a non-biological solute (salt, buffer, sugar, ...) | name (suggestions, Tab completes), then mM, then ± |
| `^p` | a polymer by grade or family (`PEG 3350`, `PEG n=22`, Pluronic, dextran, ...) | name, then the family's form (units `n` or `Mn`), then mM, ± |
| `^f` | a protein | the path of a FASTA or FASTQ file, or the sequence itself (typed or pasted); every record becomes a row |
| `^e` | DNA or RNA | `DNA or RNA:` choice, then a path or the sequence itself, as for `^f` |
| `^g` | (edits) the pH | one prompt `pH σ` (σ optional; default 0.1) |

**Sequences as text.** The `path:` prompt of `^f` and `^e` takes a file path or the sequence itself. Text with
a `/`, `\`, `.`, `~` or `:` is a path (an existing file is read; otherwise `no such file` or `use a full path`);
anything else is linted as a sequence. A paste of several lines (a whole FASTA) or longer than the field is taken at
once and counted (`pasted 12 residues: enter takes them`); Enter takes it, typing forgets it. One lint serves
text and files: a `>` header line, spaces, line breaks and the numbers of a GenBank-style listing are dropped and
letters are upper-cased; nothing else is repaired. A wrong character is an error that names it and its place
(`invalid residue '-' at 12`, `U is RNA, not DNA (at 4)`, `T is DNA, not RNA (at 4)`, `empty sequence`); the
letters allowed are the ones Julia accepts (DNA/RNA: ACGT or ACGU plus the IUPAC codes; protein: every letter, `X`
and `*` count as no residue). Text with no header is one row, `seq1`.

Rows made from one file share its mM and ±; edit them afterwards. The `params` column shows `n/a` for a small
molecule and the sequence (with its length) for a protein or nucleic acid. These rows are what is *in the
buffer blank*: **never list the molecule you measured.**

**The pH and its σ.** Both are saved together in `buffer.json` (`pH` and `sigma-pH`, each from 0 to 14); a pH
without a σ, or out of range, makes the file unusable. A buffer with no pH is not ready to run.
The unit `^k` turns (mM, M, µM) is kept in the same file as `conc-unit` (written at once, and with every
save); a missing or unknown value opens in mM, and Julia ignores the key.

**Custom solutes** are your own non-biological solutes and polymers, kept in the data folder and offered by
`^n` (small molecules) and `^p` (polymers) in every project. A name the built-in list does not know says
`no match (custom: buffer>custom solutes)`. The custom table has the columns name, formula, Z, PMV @ 25 °C and
±; a polymer shows its units by their labels (`A:C2H4O B:C3H6O`, Z `24A+32B+10`, PMV `36.9A+53.1B+9`). In
the table, `^n` opens the form of a small molecule:

```
 new custom solute · non-biological

 > name
   formula                C7H13NO3S
   Z                      102
   PMV @ 25 °C (cm³/mol)  118.4
   ± (cm³/mol)            (3.04)

 7 C + 13 H + 1 N + 3 O + 1 S = 102 electrons, charge 0
 Z = 102   PMV = 118.4 cm³/mol   σ = 3.04 cm³/mol (fallback)
```

`name`; `formula`, a chemical formula (`NaCl`, `Ca(OH)2`, `CuSO4·5H2O`, `SO4 2-`; `D` counts as hydrogen) that
gives `Z` as soon as it is taken, to keep or to type over (a formula that does not change keeps the Z typed; an
unknown element or a bad formula says so in the note and leaves Z to be typed); `Z`, the number of electrons;
`PMV`, the partial molar volume at 25 °C in cm³/mol; and `±`, its uncertainty (left empty, the fallback `(3.04)`
is used, the `PMV_FALLBACK_UNCERT` setting). Under the fields the live preview says how the electrons add up
and what BAYSOL will use. Enter edits a field, `^w` adds the solute to the table, `^w` again saves the table;
Enter on a row edits it, `^r` deletes it (after a question, at once).

`^p` opens the form of a **custom polymer**, a chain of one to four kinds of repeat unit with PMV = `pmv-ends` +
sum of slope times count and Z likewise:

```
 new custom polymer

 > name        chain-2
               │ unit │ formula │ Z / unit │ PMV / unit │ ± / unit
 ──────────────┼──────┼─────────┼──────────┼────────────┼─────────
    unit 1     │ A    │ C2H4O   │ 24       │ 36.73      │ (2%)
    unit 2     │ B    │ C3H6O   │ 32       │ 53.13      │ (2%)
    unit 3     │      │         │          │            │
    unit 4     │      │         │          │            │
    end groups │      │         │ 10       │ 9          │

 PMV = 9 + 36.73·nA + 53.13·nB
 Z = 10 + 24·nA + 32·nB
 n = 10 of each: Z = 570, PMV = 909.5 cm³/mol, σ = 18.19 cm³/mol
 n = 100 of each: Z = 5610, PMV = 9014 cm³/mol, σ = 180.28 cm³/mol
```

A unit row is used when it has anything in it (the first always; clearing a row removes a unit); a used row with no
label gets the one offered for its place (`(A)`). A unit's Z comes from its formula (a trailing `( )n` is
dropped, no charge), to keep or type over; its ± is absolute and blank shows `(2%)`. The end groups have no
default: their Z (or a formula that gives it) and PMV are required, the ± is optional. The preview gives the chain
in words with your labels and, once everything is given, its Z, PMV and σ for 10 and for 100 of each unit (the
rule of Julia's `CustomPolymer`). In the buffer, `^p` offers the polymers by name next to the built-in
grades and families, then asks the number of each unit (`nA`, `nB`, ...), mM and ±; Enter on such a row
re-types the counts.

### Settings

The main menu's `settings` edits the **global** settings; a project's `settings` edits that project's own. Four
sheets, hotkeys `u` output, `m` model, `a` sampler, `p` plots. A sheet is a list `name | value` of one *group*
(left and right switch group; the group title and `[1 / 2]` are at the bottom right), with the description of
the highlighted setting under it:

```
 sampler settings · project settings · demo

     name          │ value
 ──────────────────┼──────────────────────────────────────────────────────────
 >*  N_ADAPT       │ 400
     N_DRAWS       │ 700
     RNG_SEED      │ 0
     TARGET_ACCEPT │ 95

 Number of warm-up iterations per chain, used to tune the sampler before draws
 are kept.







                  back: ^x ┃ next group: →
                  save: ^w ┃ move: ↓
 ╭╮ ╭╮╷ ╷╭╮╭╮╷    edit: ⏎                                  ╭──────────────────╮
 ├┴╮├┤╰┬╯╰╮│││    undo: ^u                                 │ sampling [1 / 5] │
 ╰─╯╵╵ ╵ ╰╯╰╯╰─   reset group: ^r                          ╰──────────────────╯
```

| Sheet | Groups and settings |
| :-- | :-- |
| sampler | sampling: `N_ADAPT`, `N_DRAWS`, `RETRY_N_ADAPT`, `RETRY_N_DRAWS`, `RNG_SEED`, `TARGET_ACCEPT`; chains: `N_CHAINS`, `CHAIN_START_RADII`, `OPTIMUM_CHAIN_CAP`, `OPTIMUM_MIN_CHAINS`, `OPTIMUM_CHAIN_RADIUS`, `OPTIMUM_CHAIN_FRACTION`; MAP search: `MAP_MAX_ITER`, `MAP_N_STARTS`, `MAP_F_SUCCESSIVE`, `MAP_OPTIMA_KEPT`; MAP jitter: `MAP_JITTER_RADII`, `MAP_JITTER_DIRECTIONS`, `MAP_JITTER_MAX_OPTIMA`, `MAP_JITTER_WITHIN_NATS`; basins and harvest: `BASIN_RESTART_NATS`, `HARVEST_COVER`, `HARVEST_DIVERGENT` |
| model | data selection: `Q_MIN`, `Q_MAX`, `SIGMA_SCALE`, `EXCLUDE_Q`; structure: `CHAINS`, `MODEL`, `ADD_HYDROGENS`; contrast priors: `BOUNDS_δρ₁₂`, `MODE_δρ₁₂`, `κ_δρ₁₂`, `κ_δρ₃`, `φ_max`; excluded volume: `EXCL_VOL_CORR_BOUNDS`, `EXCL_VOL_CORR_EPS`, `PMV_FALLBACK_UNCERT`; hydration shell: `SHELL_THICKNESS`, `PROBE_RADIUS`, `SHELL_AREA_PER_POINT`, `SHELL_MIN_POINTS`, `SHELL_SAMPLE`, `SASA_N_OCC`; bead model: `BEAD_RAY_RANGE`, `BEAD_RAY_DIRS`, `LMAX` |
| output | tables: `TABLE_SIGFIGS`, `VAL_SIGMA` (2), `TABLE_DIR` (the data dir; empty: `<BAYSOL data folder>/data`); figures: `FIGURES_TEX`, `FIGURES_FORMATS`, `FIGURES_DIR` (the plot dir; empty: `<BAYSOL data folder>/plots`), `FIGURES_COMPILER` (the LaTeX compiler path; empty: `lualatex`, then `xelatex`, on the `PATH`). The three are typed as one line of text and are settings of the whole run |
| plots | colours, line widths, markers, comparison (`PLOT_COMPARE`, `PLOT_COMPARE_COLOURS`, `PLOT_COMPARE_MARKERS`, `PLOT_LW_COMPARE`), size and text (fonts, `PLOT_PREVIEW_SIZE`, `PLOT_TUI_SIZES`), histogram and ranges, ticks: the `PLOT_*` settings |

Every setting is on a sheet. A run that does not converge at the first pass is rerun once with `RETRY_N_ADAPT` and `RETRY_N_DRAWS` (2000 each by default), so a small `N_ADAPT`/`N_DRAWS` can end as a longer run; extra chains are also started at other optima (`OPTIMUM_MIN_CHAINS`), so a run can have more chains than `N_CHAINS`. `RNG_SEED` makes a run reproducible; `VAL_SIGMA` is the
half-width of the reported interval in standard deviations; `FIGURES_FORMATS` (`pdf png svg`) sets the file types of compiled figures (`shift+c` in `open runs`; the
setting `FIGURES_COMPILE` is off the sheets, it stays a keyword of `results` for the command line).

- **Enter** edits: a yes/no turns over; a colour is picked from a list of about 6,400 names (the 148 CSS names, x11, Federal Standard 595C, tailwind, xkcd, NBS/ISCC, Winsor & Newton, Crayola, Paul Tol, Resene, and government, international and university sets; sources and licences in `dev/data/colours/README.md`; type to narrow: the
  letters may be anywhere in the name, `brown` also finds `dark brown` and `saddlebrown`, best matches first;
  case, accents (`quebec` finds `québec blue`), blanks, `-` and `_` do not count; Tab completes) or typed as a code: `#rgb`, `#rrggbb`,
  `rgb(165, 42, 42)`, `hsl(0, 59.42%, 40.59%)` or `cmyk(0%, 74.55%, 74.55%, 35.29%)`. A typed code lists every
  named colour with exactly that 8-bit sRGB value (several names may share one), and a panel beside the list writes
  the highlighted colour in each notation (HEX, RGB, HSL, CMYK) and its family, so the editor also converts between them.
  `family: all` above the field is the family filter: `^g` goes through red, orange, yellow, green, cyan, blue, purple, pink,
  brown, gray, black and white and back to all, and the list (and its `n of m` counter) shows only that family, together
  with the typed text; a typed code ignores the filter. Every name has exactly one family, computed by the harvest from its
  colour (`colour-families.json`; the boundaries are constants of `dev/scripts/harvest_colours.jl`), and a name whose last
  word is a family (`dark brown`, `light pink`) takes it when its colour is that family or next to it. A name two sets spell with different colours is listed once for each set (`green`, `green (xkcd)`); the CSS name keeps the CSS colour. The setting keeps a CSS name or a code as typed and any other name as the `#rrggbb` of its colour (Julia reads CSS names and codes, not the rest of the list; `crimson` stays `crimson`, `nunavut yellow` is saved as `#e7a615`).
  The list is made by `bysl harvest colours` (no network); every named colour was tested to read back as the same 8-bit value from each notation; a font is picked from the fonts installed on this machine (`PLOT_TEXT_FONT`: text fonts;
  `PLOT_MATH_FONT`: only fonts with an OpenType `MATH` table), narrowed and completed the same way, a name not in
  the list is refused (on a machine where no font is found the name is taken as typed); anything else is typed
  on one line (Esc gives up): a number, the figure formats separated by blanks (`pdf png`), a pair such as a
  colour and its opacity as `darkorange, 0.15`.
- **The font list** is read from the font files themselves (family from the `name` table, math fonts by the
  `MATH` table; nothing is guessed from a name): the system font folders (Linux `/usr/share/fonts`,
  `~/.local/share/fonts`, plus `fc-list`; macOS `/System/Library/Fonts`, `/Library/Fonts`, `~/Library/Fonts`;
  Windows `C:\Windows\Fonts`, the user's font folder and the registry) and, with TeX installed, the LuaLaTeX font
  database or the `texmf` trees. The result is cached in `fonts.json` of the cache folder with a fingerprint of
  the files (paths, sizes, times), so an installed or removed font makes the scan run again. The macOS and
  Windows parts are untested.
- **Three list settings** are typed as one line and shown the same way. `PLOT_COMPARE_COLOURS`: colour names or
  any colour code or name separated by commas (names may have blanks: `green (xkcd), rgb(1, 2, 3), red`; a name outside the CSS set is saved as its `#rrggbb`;
  without a comma, blanks separate; at
  least one; repeats allowed; the first model has the first colour, and so on, starting again). `PLOT_COMPARE_MARKERS`:
  marker names of the catalog, `o, square, triangle` (`o * square square* triangle triangle* diamond diamond*
  pentagon pentagon* star x + asterisk oplus otimes`; an ordered list, not on/off). `PLOT_TUI_SIZES`: sizes of
  the terminal plots as `76x5, 100x9` (`76 x 5` and `×` are read too; whole numbers, each 24x3 to 400x100 and
  larger than the one before in both). A wrong line is refused with a short message and stays on screen. In
  `settings.json` they are lists: `["#D55E00", "red"]`, `["o", "square"]` and `[[76, 5], [100, 9]]`.
- The data and structure settings (project settings; the data screen shows nothing new): `Q_MIN` and `Q_MAX` are
  optional q limits in Å⁻¹ (blank, `none` or `auto` clears one; `Q_MIN` must be below `Q_MAX`, an error on both
  rows at save), `SIGMA_SCALE` multiplies the standard errors, `LMAX` is an optional whole number (blank or
  `auto`: automatic). `EXCLUDE_Q` is one line of `lo-hi` pairs separated by commas, `0.1-0.2, 0.5-0.6` (blank or
  `none`: no range; `0 <= lo < hi`). `CHAINS` is the chain ids to keep as letters or digits separated by
  commas or blanks or written together (`A B`, `A,B` and `AB` are alike; case counts; a repeat is refused; blank
  or `all`: every chain). In `settings.json` they are `null`, `[[0.1, 0.2], [0.5, 0.6]]` and `["A", "B"]`.
- `*` marks a change not saved, `!` a setting that cannot be saved (its message stays until the next key).
  **`^w`** saves them all, **`^u`** undoes the one under the cursor, **`^r`** resets the group to its default
  (in a project: to the **global** value).
- Every value is checked as you enter it, and again at save and when a project opens. An invalid *saved* value
  is reset to its default (in a project: to the global value) with a note, and a line in `settings.log` beside
  `settings.json` says which value and why.

### Run

The project must have a model, a buffer with at least one solute and a pH, and data with its energy. Then the
project menu shows `run: shift+r`. **Shift+R** asks one thing:

```
temperature °C: 25
```

The range is 0 to 100 °C (`a number, please` / `from 0 to 100 °C` otherwise); the start value is the
temperature of the newest finished run, else 25. There is no temperature uncertainty. Enter starts the run. If a
run of this project is already going the start is refused with `a run is in progress (pid N)`.

```
 run · demo · 20:58:27:000 EST -05:00 · 2026-11-07

 ╭────────────────────────────────────────────────────────────────────────────╮
 │ (the tail of Julia's output: the sampler's progress, the log)              │
 │                                                                            │
 │                                                                            │
 ╰────────────────────────────────────────────────────────────────────────────╯
 ╭╮ ╭╮╷ ╷╭╮╭╮╷                                                 ╭──────────────╮
 ├┴╮├┤╰┬╯╰╮│││                                                 │ running 0:03 │
 ╰─╯╵╵ ╵ ╰╯╰╯╰─   abort and quit: ^c                           ╰──────────────╯
```

The **run screen** is a live view of the last lines of Julia's output (the full text is also written to the
run's `run.LOG`); the plots are not shown here, they are in the results. The counter reads `running 0:42`,
`aborting`, `packing` (the run is over and its files are being put into the run's archive, see "The run archive" below), `done`, `failed` or `aborted`. Keys are locked except `^t` and:

- **Ctrl-C or Ctrl-D**: abort and **quit the whole program**. Julia is asked to stop (SIGTERM) and given a few
  seconds to finish its log, then killed. Julia prints a stack trace for the signal; it is not an error of the
  run.
- at the end, **Enter** returns to the project menu. A failed run shows the first line of its `ERRORS` section
  in the note row.

The run works on a **copy** of the project's files made at its start, so editing the project meanwhile (even in
another copy of the program) changes nothing. One run per project can be live. If the program or the machine dies,
Julia ends its run when its input closes, and a `running` run whose heartbeat is over a minute old is marked
`interrupted` by whichever copy of the program notices it.

### Logs (`logs`, `g`)

`logs` in the project menu is for **reading and restoring what a run used**; `open...` > `open runs` (below) is for
the results workbook and plots. It lists the runs, newest first (by the instant in the name; the screens show `23:35:29:123 EST -05:00 · 2026-11-07` for the folder `23-35-29-123_EST_-0500_2026-11-07`, and runs made before this form, `yyyyMMddTHHmmssZ`, the same way with `UTC`; the zone label is the abbreviation of the zone (`EST`, `CEST`, `TRT`) when the zone has one that fits the offset of that moment, else the official name of its main city with its accents, `SãoPaulo`, `Istanbul`: never a stand-in such as `GMT`; the data come from `moment-timezone` and `@vvo/tzdb`, installed by `npm install`): the time, how it ended (`done`, `failed`,
`aborted`, `interrupted`, `unknown` for a damaged `run.json`; `*` marks the live run, `!` an interrupted one), its
models and its size. The list refreshes every two seconds; `project: <name>` is at the top right. **Enter** opens
the run's options (`project: <name> · run: <run>` at the top right). Nothing is deleted from the logs menu: a
run is deleted in `open...` > `open runs`.

| Option | Does |
| :-- | :-- |
| view run.LOG | the full log in a pager (Enter, Space, PgDn page down, `b`, PgUp page up, arrows, Home, End, Esc or `^x` closes) |
| view / restore settings | the run's `settings.json`; restore sets the project's settings to it |
| view / restore buffer | the run's `buffer.json`; restore puts its solutes and its pH and σ back together |
| view / restore units | the run's `data.json`; restore sets only the units and the energy |
| view conditions | the temperature, pH, σ and energy as the run's `run.LOG` records them |
| view solutes, models | the run's `solutes.json` and `models.json` in the pager |

A restore asks one short question (`replace buffer (pH 7.4, σ 0.1)?`, Enter replaces, Esc keeps) and goes through
the same checks as editing the file yourself; it is refused while a run is live
(`a run is in progress (pid N)`), and fails with a note if another copy of the program changed the file after the
question. Nothing is ever written into a run, and there is no way to delete a single log file. A page open on a run
that another copy deletes says `this run was deleted` and closes.

### The run archive

When Julia has finished (a run that is done, failed or aborted) the program **packs the run folder**: the screen
says `packing`, then `done`. EVERYTHING of `<run>/` goes into ONE 7z archive beside the folder, `runs/<run>.7z`, and
the folder is removed: `run.json`, the workbooks, the logs, the inputs and the plots, as FLAT names (`run.json`,
`run.LOG`, `plots.txt`, `settings.json`, ..., `<model>.LOG`, `<model>.xlsx`, `<model>.tex`, `<model>-plots.txt`,
`<model>-76x10.txt`, `compare.tsv`, `compare.tex`, `compare-plots.txt`, ...), at the best compression (`-mx=9`). The
run's name is the same with or without the archive, a run that is still going (or whose pack failed) is the plain
folder `runs/<run>/`, and the readers take either; `run.json` of an archive is read once and kept while the archive
stays as it is, so the run list stays fast. Runs of the older layouts still read: a folder with a `run.7z` inside
(`run.json` and the workbooks beside it, the rest under `logs/`, `<model>/output/`, `compare/`), and plain nested
folders. A workbook that is only in the archive is opened from a copy in a temporary folder that is removed when the
program ends.

The pack is **atomic**: the archive is made as `<run>.7z.tmp.<pid>`, tested with `7z t` and compared with the list of
what was packed, and only then renamed to `<run>.7z`; the packed originals are removed after that and never before.
If anything fails (a full disk, a failed test) the run folder stays exactly as it was, the staged file is
removed, and the note row on the run screen says why (`not packed: ...`); the run's
own outcome is unchanged. While a pack runs, deleting that run is refused with `this run is being packed`.

**Reading is the same for packed and older runs.** The viewer's plots (`^p`), `run.LOG` (`^l` and `view run.LOG`),
the logs menu (every view, `conditions`, the restores) and the temperature the next run starts at read the archive
or, for a run that was never packed, the plain folder; the plots are read straight out of the archive (nothing is
extracted to disk), always read-only, with a check of every entry name (no `..`, no absolute path) and a size cap
per entry. Extracting (move and compile plots) uses a temporary folder that is always removed. The archive is made
by 7-Zip (the `7zip-bin` binary, run through `node-7z`; a `7z`, `7zz` or `7za` on the `PATH` is the fallback when
the bundled one cannot run).

### Results (`open...`)

With a run in the project, `open...` offers `open project folder` and `open runs`. **`open runs`** lists the runs,
newest first, with their models:

```
 open · runs                                                      project: demo

 > 10:15:00:000 EST -05:00 · 2026-11-07 lyz  done


 ╭╮ ╭╮╷ ╷╭╮╭╮╷
 ├┴╮├┤╰┬╯╰╮│││    open: ⏎    ┃ delete run: ^r
 ╰─╯╵╵ ╵ ╰╯╰╯╰─   run.LOG: ^l ┃ back: ^x
```

A run with several models shows a heading with its models under it; a run with one model is that row; a run with
none is a row of its own. The state of a model is `done`, `failed`, `aborted`, `interrupted`, `running` or
`pending`. The list refreshes itself every two seconds. The top right of every page shows
`project: <name> · run: <run>`.

- **Enter** on a `done` model opens its **results workbook** (`<model>.xlsx`) in a read-only viewer; on any
  other model the note row says why there is none (running, failed with its error line, aborted, ...).
- A model with settings of its own is marked `*` after its name; with the row highlighted the note row says
  which (`overrides: Q_MAX, N_CHAINS`).
- A run that made the **comparison** (one figure of the measured curve, every model and the references) has one
  more row, `comparison`, after its models: Enter opens `compare.tsv` in the same viewer (one table: the
  measured curve, each model's fit and each reference on the measured q; `^p` for the plot); a failed one says
  why in the note row.
- **`shift+d`, `shift+t`, `d`, `t` and `shift+c`** move and compile the files of a run. **Move data** (`shift+d`: the
  whole run, `d`: the highlighted row) copies the workbooks (`<model>.xlsx`) and the comparison table into the data
  folder; **move tex** (`shift+t` / `t`) copies the `.tex` figures into the plot folder; **compile plots**
  (`shift+c`, the highlighted row) extracts the figures to a temporary folder, runs the LaTeX compiler on each and puts
  the PDFs in the plot folder. The whole run is every model and the `comparison`; the legend shows each key where there
  is something to take. The files come from the run's archive (or its folder, or an older run's layout) and go FLAT
  into the folder, named for the model (`<model>.tex`, `<model>_hist_c1.tex`, `<model>.xlsx`; the comparison's are
  `<project>-compare.tsv`, `<project>-compare.tex`); when a name is taken, ALL the files of that model get `-2`, then
  `-3`, ... before the extension, and nothing is ever replaced (a copy that loses a race for a name starts again with
  the next number). The folders are the settings `plot dir` (default `<BAYSOL data folder>/plots`) and `data dir`
  (default `<BAYSOL data folder>/data`), one folder for all projects (output sheet). The compiler is the setting
  `latex compiler path`; empty means `lualatex`, then `xelatex`, found on the `PATH`
  (`pdflatex` cannot load the fonts of the figures, so it is only used when you set its path). A compiler that
  cannot be found is told in the note row, with where to set the path (a path that is set is never replaced by a
  different compiler); a figure that LaTeX rejects is named with the first line of its error, and the others are still
  made. A note, an error too, stays until the next key.
- **`^l`** on a run opens `run.LOG` in a pager: Enter, Space and PgDn page down, `b` and PgUp page up, arrows,
  Home and End move, Esc or `^x` closes. A live run can be read.
- **`^r`** deletes the whole run folder after a question (`... this cannot be undone!`); a live run is refused
  (`a run is in progress`). There is no way to delete a single log file.

**The viewer** shows one tab per sheet of the workbook (the `run` sheet first lists what ran: section, name,
value, unit, meaning):

```
 results · lyz.xlsx                       project: demo · run: 10:15:00:000 EST -05:00 · 2026-11-07

    fit   curve   third sheet name
 ╭────────────────────────────────────────────────────────────────────────────╮
 │     │ A         │ B     │ C     │ D    │ E                                 │
 │ ────┼───────────┼───────┼───────┼──────┼────────────────────────────────── │
 │   1 │ parameter │ value │ error │ unit │ note                              │
 │ ────┼───────────┼───────┼───────┼──────┼────────────────────────────────── │
 │   2 │ param1    │  1.25 │  0.01 │ A^-1 │ ok                                │
 │   3 │ param2    │   2.5 │  0.02 │ A^-1 │ ok                                │
 │                                                                            │
 │ A1 · row 1 / 61                                                            │
 ╰────────────────────────────────────────────────────────────────────────────╯
 ╭╮ ╭╮╷ ╷╭╮╭╮╷
 ├┴╮├┤╰┬╯╰╮│││    next sheet: tab ┃ plots: ^p
 ╰─╯╵╵ ╵ ╰╯╰╯╰─   move: ↑↓←→ ┃ back: ^x
```

(The sheet names and cells above are an example workbook; yours has the fit's own sheets.) **Tab** and **Shift+Tab** (or `]` and `[`) go to the
next and previous sheet and stop at the ends; the legend lists only what works now: `next sheet` is missing
on the last sheet, `prev sheet` on the first, and an arrow is missing when the cursor is at that edge. The arrows
move the cursor, `^x` goes back. **`^p`** switches to the **plots** of that model, one tab per
plot of its `plots.txt` (`fit`, `residuals`, one per parameter, ...), and back with `^p` again. In the plots
mode **`+`** and **`-`** zoom in and out: they step to the next larger or smaller saved size of the plots (the
largest that fits is chosen at first; the keys appear only while a larger or smaller size exists). A very large
sheet is cut at a limit, and the status line says so. The first row is frozen when it is text. The viewer never
writes, locks or changes a file.

In the sheets mode the viewer also has these keys (each shows in the legend only while it works):

| Key | What it does |
| :-- | :-- |
| `/` | **find**: a prompt (Enter searches, Esc cancels) for text; the cells that contain it, in any case, are underlined and the cursor jumps to the first one at or after it. The status line shows `match 3 / 12`; the text is kept while the viewer is open, for every sheet |
| `n`, `N` | the next and the previous match, wrapping round (shown while a search has matches; `no match` is a note when there is none) |
| `g` | **go to**: a prompt for a cell (`B7`), a row (`7`, the column stays) or a column (`B`, the row stays); text that is none of these, or a place outside the sheet (`outside the sheet (A1:H60)`), is a note that stays until the next key |
| `Space` | **mark** the cursor cell as one corner of a range; moving the cursor extends the range (drawn highlighted, `range A1:B2` in the status line); `Space` again or `Esc` clears it |
| `c` | **copy**: with a range marked it copies the range; without one the note asks `copy: cell (c), row (r), column (l)?` and the next key picks (`Esc` cancels) |
| `f` | **formulas**: shows the formula text of the cells that have one (`=SUM(A1:A2)`) instead of their values, and back; on a sheet without formulas it says `no formulas here` (the key is in the legend only when the sheet has formulas) |

A copy is TAB-separated text, one line per row, sent to the clipboard through the terminal (the OSC 52 sequence,
which also works over SSH; a terminal that does not accept it ignores it). The note says what went:
`copied A1:B2 (4 cells)`, `copied row 7 (12 cells)`, `copied column C (61 cells)`. More than 70 KB is refused
(`too much to copy (70 KB at most)`). Control characters in a cell become a space, so a cell can never send an escape
sequence to the terminal.

The plots exist at several sizes (`PLOT_TUI_SIZES`, written by a run started from the terminal interface). The
plots mode shows the **largest that fits the panel** (width and rows), the smallest if none does (then it
scrolls), and picks again when the window is resized; the plot tab stays. The status line says which, `plot 1 / 9 ·
76x10 · lines 1-12 of 12`. A run made before the sizes existed shows its `plots.txt`.

## Keys at a glance

| Key | Does |
| :-- | :-- |
| arrows, Enter | move, select or edit; a letter on a menu picks its option |
| `Esc` | closes what is open (prompt, list, question, pager); never quits |
| `^x` | back one screen; never quits |
| `q` (main menu), `^c`, `^d` | quit (`^c` and `^d` stop a running fit first) |
| `^t` | the theme list |
| `^w` | save every change on the screen |
| `^u` | undo (a removal mark, or the change under the cursor) |
| `^r` | remove a buffer row (mark), delete a project, recipe, custom solute, model, reference curve or run (asks), reset a settings group (on a model's sheet: `inherit group`) |
| `^n` `^p` `^f` `^e` | buffer: add a small molecule, a polymer, a protein, DNA or RNA; `^n` also adds a reference curve (`data`, `references`) and a recipe (recipes table); the global settings menu has the options `recipes` (`y`) and `solutes` (`t`) |
| `^o` `^f` | models list: the settings, the reference fit of the highlighted model |
| `^g` | buffer: edit pH and σ |
| `^k` | buffer: turn the unit of the concentrations (mM, M, µM) |
| `o`, `m` | on an empty path field: the file chooser, the list of models |
| `r` | on an unusable file: reset it (the old file is kept as `.corrupt`) |
| `Shift+R` | project menu: run (shown only when ready) |
| `Tab`, `Shift+Tab` (also `]` `[`) | viewer: next and previous sheet or plot |
| `+` `-` | viewer, plots mode: zoom in and out (a larger or smaller saved size) |
| `^p` | viewer: switch between sheets and plots (in the buffer it adds a polymer) |
| `/`, `n`, `N`, `g` | viewer: find, next and previous match, go to a cell |
| `Space`, `c`, `f` | viewer: mark a range, copy (OSC 52), show formulas |
| `l` | `open runs`: read the run's `run.LOG` |
| `shift+d`, `shift+t`, `shift+c` | `open runs`: move the data, move the tex plots (whole run), compile the highlighted row's plots; `d`, `t`: move the highlighted row's data, tex |
| `b`, `Space`, PgUp, PgDn | pager: page up and down |
| menu hotkeys | main: `n` `l` `o` `s` `h` `q`; project: `m` `d` `b` `g` `s` `o`; settings: `u` `m` `a` `p` |

## Files on disk, with examples

Everything the interface writes is JSON (or the clean `data.tsv`), UTF-8, written through a temporary file and
renamed, so a reader never sees half a file.

```
<data folder>/
    settings.json            global settings, sparse: only what you changed
    settings.log             (a line for each saved value that a load reset)
    theme.json               {"theme": "graphite"}
    custom-solutes.json      your custom solutes
    recipes.json             your saved recipes (named buffers, with their pH and σ)
    projects/<name>/
        project.json         {"id": "demo", "created": "2026-11-07T20:54:18.767Z"}
        settings.json        this project's settings, sparse
        buffer.json          solutes, pH, sigma-pH
        data.tsv             q, I, sigma: three tab-separated columns
        data.json            units, energy, source, import choices
        references/          reference curves: clean <name>.tsv (q, I[, sigma]), same units as data.tsv
        model-settings.json  per-model overrides {"<model>": {sheet: {NAME: {"value": ...}}}}, sparse
        model-references.json  per-model reference fit {"<model>": {tag, software, ref_chi2, fit, rescale}}, sparse
        models/              copies of your .cif and .pdb files
        runs/<HH-MM-SS-mmm_TZ_±HHMM_YYYY-MM-DD>.7z   e.g. 23-35-29-123_EST_-0500_2026-11-07.7z: ONE archive
                                   per run with everything in it, flat (while the run goes it is the folder
                                   <name>/ with the same files; see "The run archive")
            run.json         status, versions, models (their files), timings (written by Julia)
            run.LOG plots.txt   the log of the run; every terminal plot
            settings.json buffer.json solutes.json data.tsv data.json models.json
            model-settings.json model-references.json reference-fit-<file>   (what the run read)
            <model>.xlsx <model>.LOG <model>*.tex <model>-plots.txt <model>-<W>x<H>.txt
            compare.tsv compare.tex compare-plots.txt compare-<W>x<H>.txt
```

`settings.json` (global or project; the keys are the sheet, then the setting):

```json
{
  "sampler": {
    "N_ADAPT": { "value": 400 }
  }
}
```

`model-settings.json` has the shape of `settings.json` for each model, named by the model's file name without
its extension, and holds only what differs from the project:

```json
{
  "crambin": {
    "model": { "Q_MAX": { "value": 0.3 } },
    "sampler": { "N_CHAINS": { "value": 4 } }
  }
}
```

`buffer.json`: solutes in mM, the pH and its σ together or not at all. `kind` is `nonbiological` or `polymer`
(with an `arg` such as `"PEG n=22"`), `dna`, `rna` or `protein` (with the sequence in `arg` and the file and
record it came from), `custom-nonbio` (a snapshot of a custom solute) or `custom-polymer` (a snapshot of a custom
polymer with the `counts` of its units):

```json
{
  "solutes": [
    { "name": "nacl", "mM": 200, "kind": "nonbiological",
      "arg": "sodium chloride", "sigma-mM": 10 },
    { "kind": "custom-nonbio", "name": "NACET", "custom": "N-acetylcysteine ethyl ester",
      "z": 102, "pmv": 118.4, "sigma-pmv": 4, "mM": 5, "sigma-mM": 0.1 },
    { "kind": "custom-polymer", "name": "chain", "custom": "chain-1", "mM": 0.01, "sigma-mM": 0.0001,
      "units": [ { "label": "A", "formula": "C2H4O", "z": 24, "slope": 36.73, "sigma": null } ],
      "counts": [ 22 ], "z-ends": 10, "pmv-ends": 19.24, "sigma-ends": null }
  ],
  "pH": 7.4,
  "sigma-pH": 0.1
}
```

`custom-solutes.json` (a `null` sigma means the fallback uncertainty):

```json
{
  "solutes": [
    { "kind": "nonbiological", "name": "glycol-x", "formula": "C2H6O2", "z": 34, "pmv": 20.5,
      "sigma": null },
    { "kind": "polymer", "name": "chain-1", "z-ends": 10, "pmv-ends": 19.24, "sigma-ends": null,
      "units": [ { "label": "A", "formula": "C2H4O", "z": 24, "slope": 36.73, "sigma": null } ] }
  ]
}
```

`data.tsv` (no header, no units):

```
0.0671017	22.6596	17.4896
0.0698361	22.2021	14.2179
```

`data.json` (Julia reads only `units`, `energy`, and the TSV; `mapping` is the interface's memory of the
import; `units` is `"nm-1"` or `"A-1"`):

```json
{
  "units": "nm-1",
  "energy": 12000,
  "source": "SASDMJ9.dat",
  "points": 2048,
  "mapping": {
    "path": "/path/to/SASDMJ9.dat",
    "separator": "auto", "sheet": "", "skipRows": 0, "comments": true, "header": "auto",
    "columns": {
      "i": { "spec": "col:2", "column": 2 },
      "q": { "spec": "col:1", "column": 1 },
      "sigma": { "spec": "col:3", "column": 3 }
    }
  }
}
```

`runs/<name>/run.json` is written by Julia alone while the run lives (atomically, every change and every 10 s;
`heartbeat` is the time of the last rewrite). `status` is `running`, `done`, `failed`, `aborted` or
`interrupted`; each model has its own `status`, `seconds` and `error`:

```json
{
  "schema": 1,
  "status": "done",
  "pid": 4242,
  "host": "mybox",
  "ui": "tui",
  "project": "/home/me/.local/share/baysol/projects/demo",
  "started": "2026-11-07T10:15:00Z",
  "heartbeat": "2026-11-07T10:15:42Z",
  "ended": "2026-11-07T10:15:42Z",
  "julia": "1.12.7",
  "baysol": "v0.4.0",
  "rng_seed": 0,
  "models": [
    { "name": "lyz", "path": ".../models/lyz.cif", "size": 98765, "sha256": "...",
      "status": "done", "seconds": 41.3, "error": null }
  ],
  "timings": { "seconds": 42.1, "models": { "lyz": 41.3 } }
}
```

`run.LOG` has flat `name<TAB>value` rows: the setup (with `temperature_c`, `ph`, `sigma_ph`,
`energy_ev`), then the output, a `--- result ---` block and, if anything failed, an `=== ERRORS ===` section with
each message and its stack. Nothing in a run folder is ever overwritten; the deletions are the explicit
`delete run` and, once its archive has passed `7z t`, the files that were packed into it. A file that cannot be used is never written over: it is told, and `r` resets it, keeping the old
one as `<name>.corrupt`.

## Two copies at once

Two copies of the program, or the program and a Julia script, can use the same data folder safely. Saving takes
a short lock on the file. Settings changed in two copies are merged (the same setting: the last save wins). A
buffer or custom-solute list that another copy saved meanwhile is not overwritten (`changed on disk: reopen it`). A project deleted in one copy is not brought back by the other. Starting a run
takes a lock too, so two copies starting at the same instant cannot both win; a refused start says
`a run is in progress (pid N)`, and `delete run` and `delete project` refuse a live run.

## If something goes wrong

| What you see | What to do |
| :-- | :-- |
| `BAYSOL: this program needs a terminal` | run it from a terminal window, not a pipe |
| a message instead of the screen | the terminal is under 80 x 24: enlarge it |
| `<file> unusable!` and `r: reset` | the file was edited by hand or damaged; `r` then Enter resets it to empty and keeps the old one as `<name>.corrupt` |
| `changed on disk: reopen it` | another copy of BAYSOL saved the file meanwhile: leave the screen and open it again |
| no `run: shift+r` | a model, a buffer with a solute and a pH, or data with its energy is missing |
| `a run is in progress (pid N)` | a run of this project is live (maybe in another window); wait or stop it |
| `could not start julia: ...` | `julia` is not on the PATH: install it or set `JULIA` to its full path |
| `not packed: ...` | the run finished but its archive could not be made or did not test; read the reason; the run reads fine unpacked |
| `no LaTeX compiler found ...` | `compile plots` found no `lualatex` or `xelatex` on the `PATH`: set `latex compiler path` (output sheet) |
| `julia ended unexpectedly (...)` | Julia died; read `run.LOG` (`l` in `open runs`) |
| a model is `failed`, with its first error line on the run screen | the whole message and stack are in the `ERRORS` section of `run.LOG`; the other models still ran |
| `WLSError` in `run.LOG` | too few points (fewer than 3) or the model curve is flat across the q window; check the curve, `units` and `energy` |
| an unknown residue or element | the model has a residue BAYSOL does not know; it looks it up online, so reconnect and retry |
| the terminal looks broken after a crash | `reset` in the shell; the program restores the terminal on every normal exit |
| a setting was reset with a note | `settings.log` beside `settings.json` lists each wiped value and why |

## For contributors

The interface only reads and writes the project's JSON files and starts programs; Julia knows nothing about it.
`BAYSOL.run_project` (Julia) is the one entry the interface calls, with the arguments `project_dir`,
`temperature`, `ui = :tui` and `run_dir`; the same JSON files are read by Julia's `load_settings` and
`load_buffer`, and the test fixtures `test/fixtures/settings/*.json` and `test/fixtures/buffer/*.json` at the
repository root are shared by both sides, so a change to a file format changes both.

**Layout of `tui/src`** (four folders):

| Folder | What lives there |
| :-- | :-- |
| `core/` | no UI: `environment.ts` (folders, the cache, asset lookup, the `RUN_FLOW` and `LOGS_FLOW` constants, the Julia command), `terminal.ts` (text width, wrapping, number parsing, `hasTerminal`), `file-system.ts` (JSON files, atomic writes, locks), `archive.ts` (7-Zip: atomic packing, read-only listing and reading of entries, extraction into a temporary folder), `fonts.ts` |
| `store/` | the data layer, no React: settings, projects and the run folder, buffer and solutes, the add flow, custom solutes, data import, the run session and its logs, the run archive (`run-archive.ts`), the plots actions (`plots.ts`), the viewer's data |
| `ui/` | the kit every screen is built from: `interaction.tsx` (the navigation stack, **all key definitions**, text input, cursor lists), `theme.tsx`, `grid.tsx` (menus and legends), `input.tsx` (prompts, dropdowns, questions, the theme picker), `frame.tsx` (the screen frame and forms) |
| `screens/` | the screens: menus, data, solutes, custom solutes, settings, the run screen, the viewer and `open runs` |

`main.tsx` is start-up only (it needs a terminal, sweeps stale runs, installs the SIGHUP and SIGTERM handlers);
`app.tsx` is the `App` component (theme, size guard, the Ctrl-C handler, the navigation stack). `assets/` has the
logos, the menu pictures and the data files (`setting_sheets.json` is the settings sheets).

**Architecture in short.** Every key goes through one route: a screen calls `useKeys(handler, active)` and the
handler asks `press.is(keys.x)`; keys are defined once in `ui/interaction.tsx` (and the menu hotkeys in
`ui/grid.tsx`), never spelled elsewhere, and legends are built from the same definitions, so the hint can only
list keys that work. State lives in `store/`; a screen is a thin view. A run is a Julia child process in its own
process group, started by `RunSession` after the claim of a run folder under a lock; `run.json` has one writer
(Julia) and liveness is `status running` plus a heartbeat under 60 s; the session aborts the group with SIGTERM
and a grace time, then SIGKILL.

**Commands** (from `tui/`, or the repository root with `-w tui`):

```bash
npm start       # run it
npx tsc         # type-check (strict, no emit; also `npm run check`)
npm test        # the node:test suite (tsx --test test/*.test.ts); takes minutes
```

Formatting and lint are the repository's: `bysl fmt` runs Biome (installed at the root) and the TypeScript
whitespace rule, `bysl fmt --lines` fails on a line over 92 columns or an indentation that is not a multiple of
4 (**exactly 4 spaces per level, continuation lines too**), and `bysl precommit` runs everything before a commit.
Every source file starts with `# SPDX-License-Identifier: LGPL-3.0-or-later` in its comment syntax (`bysl fmt`
adds it).

**Tests.** Pure logic is unit-tested with `node:test` (`test/*.test.ts`); the run flow is tested with real
processes (`concurrency.test.ts`: two processes claim a run, exactly one wins; a killed child becomes
`interrupted`) and a stand-in for Julia, `test/support/fake-julia.ts` (modes `done`, `failed`, `hang`, ...; the
environment variable `JULIA=<script>` makes the whole program use it). Tests never touch your data or cache
folders: they use throwaway ones.

**Checking a screen by hand.** Screens have no render tests; drive the real program in a pseudo-terminal: start
`npm start` with `BAYSOL_HOME` and `BAYSOL_CACHE` pointing at scratch folders, a window size of 80 x 24 set with
`TIOCSWINSZ`, wait a few seconds for the start, feed keystrokes, and read the screen with a terminal emulator
library (for example Python's `pty` and `pyte`). Decode the output as a stream (a multi-byte character can be
split between reads). The blocks in this guide were captured that way. Never point such a run at the real data
folder.

The earlier Clojure interface is gone; `tui/SPEC.md` is its specification, kept as the reference of the rules,
numbers and messages the TypeScript version preserves.
