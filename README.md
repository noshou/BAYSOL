# BAYSOL: Bayesian CRYSOL

Bayesian CRYSOL-style fitting of SAXS curves for proteins and DNA/RNA. Give it a measured curve, a 3D structure and the buffer recipe, and it returns the fit parameters with their uncertainties, not just one best guess.

Two ways to use it, both without writing code:

1. **The terminal interface** (the first guide below, full reference in the [terminal interface guide](tui/README.md)): menus and forms in a terminal window; you make a project, add a model, your curve and your buffer, press one key to run, and read the results there.
2. **A script** (the second guide below, "Second way: run it from a script"): you edit one short text file and run it. This is the way to script and to run batches; Julia users can also call the package directly ("For Julia users", at the end).

- Documentation: [BAYSOL](https://noshou.github.io/BAYSOL/). Each module's README under `src/` is also a page there.
- Worked analyses of 27 protein and 30 DNA/RNA SASBDB entries: [fitting tests](test/fitting_tests/README.md)
- Developer tools (test runners, comparison, benchmarks, figure rendering): [dev](dev/README.md)

## Use BAYSOL from the terminal interface (no coding)

The terminal interface (TUI) is the first way to use BAYSOL: a full-screen program that runs in
a terminal window, with menus, forms and tables, and no code to write. You make a *project*, put
a 3D model, your curve and your buffer into it, press one key to fit, and read the results in the
same window. It runs on **Linux, macOS and Windows**. The second way, for scripting and for
batches, is the script guide ("Second way: run it from a script") further down. The full
reference of every screen, key and file is the [terminal interface guide](tui/README.md).

> **Status, said plainly.** The developers have run the interface on **Linux (ARM)**. The
> macOS and Windows parts (opening a folder or a file chooser from the interface, stopping a
> run) are written from the documentation of those systems and **have not been tested**; on
> Windows, WSL is the safest route (see Step 1 of the script guide). Everything you do inside
> the interface (menus, forms, tables, viewers) works the same on every system.

### What you need

| What | Version | Check it with |
|------|---------|---------------|
| **Julia** | 1.12 | `julia --version` |
| **Node.js** (runs the interface) | 22 or newer | `node --version` |
| **BAYSOL** itself | a folder with `tui/` in it | |
| A terminal at least **80 columns by 24 rows**, ideally with 24-bit colour | | |

- *Julia*: install it as in Step 2 of the script guide below (`juliaup`, `winget`).
- *Node.js*: from <https://nodejs.org> (the LTS download), or `winget install OpenJS.NodeJS` on
  Windows, or your package manager, or `nvm`. `npm` comes with it.
- *BAYSOL*: download and unzip it as in Step 3 of the script guide, or `git clone` it, **from a
  version that contains the `tui/` folder**. In the commands below the folder is `BAYSOL`.
- *Your data*: a 3D model of your molecule (a `.cif` or `.pdb` file), your curve as a text file or
  a spreadsheet (`.xlsx`) with the columns q, I(q) and its error, and your buffer recipe (what is
  in the buffer, in mM, and its pH). You also need the X-ray energy in eV and the buffer
  temperature in °C (kept in the buffer). Your measured molecule is **never** listed in the buffer; only what is in
  the blank is.

### Install and start (once, then every time)

In a terminal, in the BAYSOL folder:

```
cd BAYSOL
npm install                                                 # once: the interface's libraries
julia --project=. -e 'using Pkg; Pkg.instantiate(); using BAYSOL'   # once: the fitting code
cd tui
npm start                                                   # every time: starts the interface
```

`npm install` is run **once, at the BAYSOL folder** (not in `tui/`): the repository has one
`node_modules`, shared by the `tui` folder. The `julia` line downloads and compiles BAYSOL and
takes several minutes; it is only so that your first fit is not the one that waits. The first
fit still downloads the helper programs PROPKA and pdb2pqr (they add hydrogen atoms) and needs
internet.

The interface needs a real terminal: started with its output redirected it prints `BAYSOL: this
program needs a terminal` and stops. If the terminal is smaller than 80 x 24 it shows a message;
make the window bigger and the screen comes back as it was.

**Where BAYSOL keeps your work** (the *data folder*, made on first start):

| System | Data folder | Downloaded structures (a cache you may delete) |
|--------|-------------|---------------------------------|
| Linux | `$XDG_DATA_HOME/baysol`, else `~/.local/share/baysol` | `$XDG_CACHE_HOME/baysol/_cache`, else `~/.cache/baysol/_cache` |
| macOS | `~/Library/Application Support/baysol` | `~/Library/Caches/baysol/_cache` |
| Windows | `%LOCALAPPDATA%\baysol` | `%LOCALAPPDATA%\baysol\_cache` |

Set the environment variable `BAYSOL_HOME` (an absolute path) to use another folder, and
`BAYSOL_CACHE` for the cache; a relative path is ignored. To try the interface without touching
your real work: `BAYSOL_HOME=/tmp/baysol-try npm start`.

### The main menu

The first screen is the main menu with the logo, the release name and six options: **new
project**, **load project**, **open** (the data folder in your file manager, with a shell in it
until you leave it), **settings** (the global ones), **help** (a placeholder: it says it is not
built yet) and **quit**.

- Move with the arrow keys and press **Enter**, or press the option's letter: `n`, `l`, `o`, `s`,
  `h`, `q`. The box at the bottom lists the keys that work from where the cursor is, and nothing else.
- **`q`** in the main menu quits. **Ctrl-C** and **Ctrl-D** quit from anywhere (they also stop a
  run that is going). **Esc never quits**: it only closes what is open (a prompt, a list, a
  viewer). **Ctrl-X** goes back one screen.
- **Ctrl-T** opens the theme list, on any screen: 20 themes (10 light, 10 dark), each with an
  emoji and its colours. Arrows move, Enter picks, Esc leaves. The theme you leave in is the one the
  next start uses.

### Make a project

A project is a folder that holds one analysis: models, data, buffer, settings and the runs.

1. Press `n` (**new project**), type a name and press Enter. A name has letters, digits, `.`,
   `_` and `-`, starts with a letter or digit, has at most 40 characters, and is unique
   (capital letters do not count).
2. The **project menu** opens: `models`, `data`, `buffer`, `logs`, `settings`, `open...` (hotkeys
   `m`, `d`, `b`, `g`, `s`, `o`). `^x` goes back to the main menu; later, `l` (**load project**) in the main menu
   lists your projects (`^r` there deletes one, after a question).

A new project gets a copy of the global settings; its own can then differ.

### 1. Add the 3D model

Open **models** (`m`). Type or paste the **full path** of a `.cif` or `.pdb` file and press Enter
(Tab completes a name; on an empty field, `o` opens your system's file chooser, and `m` lists the
models already in the project). The file is **copied** into the project's `models/` folder; your
original is never touched. You can add several models: each is fitted in turn, in one run.
`^r` on the model list deletes a model from the project (after a question). `^o` on the list opens the
**settings of that model**: the project's sheets, showing which settings the model overrides (`overridden`)
and which it takes from the project (`inherited`, muted); `^r` there gives a group the project's values
again. They are saved in `model-settings.json` of the project, only what differs. Settings of the whole run
(the figures' look, `TABLE_SIGFIGS`, `FIGURES_*`) are not offered for a model.

If you only have a sequence, make a 3D model with another program first: BAYSOL fits a
structure, not a sequence.

### 2. Import the curve

Open **data** (`d`) and choose **load a file**. Give the full path of your curve: any delimited
text file (`.dat`, `.fit`, `.csv`, `.tsv`, `.txt`, anything; the path suggestions and the file picker list those and the usual curve names; tabs, commas, semicolons, `|` or aligned
columns) or an `.xlsx` workbook (its first sheet). The **import screen** opens: on the left the
options, on the right a live preview of how the file is read, with the file's own line numbers.

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
```

- **Header text is found for you.** The data start at the first line that splits into at least two
  numbers, and end at the first line that is not data (a footer); the text above it (such as the
  five header lines of a SASBDB `.dat` file, shown above as "line 6" onward) is skipped.
  Use `skip rows` only if a header has numbers in it.
- `separator` (auto, tab, comma, semicolon, whitespace), `comments` (lines starting with `#`,
  `;`, `%` or `!`) and `header` (auto, yes, no: is there a row of column names?) turn with
  **Enter** or the left and right arrows. `skip rows` takes a number. Up and down, or **Tab** and
  **Shift+Tab**, move between the options.
- **The three columns** `I(q)`, `q` and `sigma` start as a guess. Enter on one opens a prompt:
  type a **column number** (`2` or `col:2`) or a **header name** (any capitals; Tab completes).
  Sigma, the error of each point, is required.
- Press **`^w`** to import. The first problem stops the import, names the line and column
  (`line 7, column err: "abc" is no number`) and writes nothing. A row whose q or sigma is not above 0, and a row
  repeated exactly, is dropped and counted (`dropped 2 rows (q or sigma <= 0, or repeated)`). At least 3
  points are needed, and q must not go back (a repeated q is fine).

The import writes a clean `data.tsv` in the project (q, I, sigma; no header); your file is never
changed. Back on the data screen, two more things are required:

```
 data · demo

 ╭────────────────────────────────────────────────────────────────────────────╮
 │ points   2048                                                              │
 │ q range  0.067102 to 5.6685 nm⁻¹                                           │
 │ source   …/files/SASDMJ9.dat                                               │
 │ columns  I(q)=col:2, q=col:1, sigma=col:3                                  │
 │ read as  auto, skip 0, comments on, header auto                            │
 │ energy   12000 eV                                                          │
 ╰────────────────────────────────────────────────────────────────────────────╯

   load a file
   change the columns
   units
 > energy
```

- **`q units`**: Enter or `^k` turns `nm⁻¹` and `Å⁻¹` and saves it at once (`^k` is the unit key of q, energy and concentrations). A new
  curve starts as `Å⁻¹`, so **set it right**: a curve in nm⁻¹ read as Å⁻¹ gives absurd fits.
- **`energy`**: the X-ray energy as a wavelength in nm by default (above 0; `^k` relabels the unit nm, Å, eV or keV: the number is kept, Julia converts at run time). There is no default.
- **`change the columns`** reopens the import with the choices you made, so you can correct them.
- **`reference fit`** lists the **reference curves** of the project (the depositor's CRYSOL or FoXS fit, for
  the comparison figure of a run). `^n` adds one from any table, through the same import screen with
  only `q` and `I(q)` (and an optional `sigma`, `none` by default); the curve must be in the same units as
  the data. It is saved as a clean `<name>.tsv` in the project's `reference-fit/` folder (a taken name gets
  `-2`, `-3`; nothing is overwritten) and `^r` deletes the highlighted one, after a question. Adding needs the
  data first. On macOS and Windows the file chooser of this option is untested like the others.

### 3. Set up the buffer

Open **buffer** (`b`). It has the rows `buffer (N solutes)`, `custom solutes (N)`, `load a recipe`,
`new recipe` and, once the buffer has solutes, `save current recipe globally`. Open the first for the table of
solutes. A **recipe** is a named buffer saved for every project (with its pH and σ): save the current buffer as
one, or load one into this project's table (the list narrows as you type; nothing changes on disk until `^w`; a buffer that has solutes asks
`replace N solutes with recipe "NAME"?`). `^e` in the global settings menu opens the recipes and the custom
solutes. The recipes table saves every edit by itself; `^r` marks a recipe and `^w` (shown only then) deletes the marked ones. The project, the buffer and each recipe can carry titled **notes** (`shift+n` in the project menu and on the
buffer table and the recipes table; a small built-in editor, no length limit; `^w` saves and so does leaving it; the buffer's notes are written at once, only solutes and pH wait for `^w`); the project's notes travel in
every run's archive.

**Buffer templates (`shift+b` on the table):** pick a standard buffer (Tris, HEPES, MES, phosphate, citrate, PBS, ...), type the concentration and the pH, and the rows of the buffer and of the counter-ion that titrating it to that pH adds are filled in, with uncertainties, from sourced constants (pK at the temperature of the pH, Davies activity, self-consistent ionic strength; assumptions: pH set at the buffer's temperature unless you choose 22 °C or another, HCl for amine bases, NaOH otherwise). The rows follow the pH row (and the temperature, when set at the buffer's) until you edit one by hand; pick the template again to change it. Two rows of the same solute (`cl-`, `chloride`) are refused.

```
 buffer · demo

     pH         │ σ          │ T °C
 ───────────────┼────────────┼────────────
     7.4        │ 0.1        │ 25

     solute                │ params                       │    [mM] │   ±[mM]
 ──────────────────────────┼──────────────────────────────┼─────────┼─────────
 >   nacl                  │ n/a                          │     200 │      10
```

- **`^g`** sets the **pH and its uncertainty σ** in one prompt (`7.4 0.1`; σ is optional and
  defaults to 0.1), then the **temperature** in °C in a second prompt (0 to 100; it starts at the
  buffer's, else your last run's, else 25). Without a pH and a temperature the buffer is not ready.
- **`^n`** adds a small molecule (salt, buffer, sugar, ...): type a name, pick a suggestion with
  Enter (Tab completes), then the concentration (**in mM**, until you turn the unit) and its **uncertainty ±**.
  **`^p`** adds a polymer by grade or family (for example `PEG 3350`: type the molar mass in g/mol from the bottle label; the second choice, number of repeat units, gives `PEG n=22`), **`^f`** a protein, and
  **`^e`** DNA or RNA, from a FASTA or FASTQ file (the full path; every record of the file becomes a
  row, all with the same concentration and uncertainty, which you can then edit) or from the sequence
  itself, typed or pasted (a whole FASTA is fine). A PDB or mmCIF file works as a source too (its `SEQRES` chains or `_entity_poly` entities of that kind; chains with the same sequence are one row; a file with none of the kind names the key that adds the kind it has; a PDB without `SEQRES`, as most SASBDB models, gives its chains from the ATOM records of the first MODEL). Spaces, line breaks, the `>` line and the numbers of a
  GenBank-style listing are dropped and letters made upper-case; any other wrong character is an error
  that names it and its place (`invalid residue '-' at 12`), and nothing is repaired silently. These are things *in the buffer*, not your measured molecule.
- **`^k`** turns the unit of the concentrations and their ± (mM, then M, then µM, then mM again). It
  changes only what is shown and typed: the file keeps mM. Small or large numbers show as `3e-7`. The unit
  is kept per buffer (`conc-unit` in its `buffer.json`, saved at once) and the table opens in it again.
- **`⏎`** edits the row under the cursor, **`^r`** marks it for removal, **`^u`** undoes, and
  **`^w`** saves every change (a `*` marks what is not saved yet).
- A name BAYSOL does not know shows `no match (custom: buffer>custom solutes)`. Open
  **custom solutes** on the buffer page, press `^n`, and type its name, its **formula** (it gives the
  **Z**, the number of electrons, and a preview shows how it adds up; an unknown element is told), its
  partial molar volume (PMV, cm³/mol) and optionally its uncertainty; press `^w` to add it to the table and
  `^w` again to save. It is then offered by `^n` in every project. For a polymer of your own, press `^p`
  instead: a name, up to four kinds of repeat unit (label, formula, Z, PMV per unit, ±), the end groups,
  and a preview of the chain's Z and PMV; it is offered by `^p` in the buffer, which then asks how many
  of each unit there are.

### 4. Settings (usually leave them)

`settings` in the project menu opens four sheets: `output`, `model`, `sampler` and `plots`
(hotkeys `u`, `m`, `a`, `p`). Each is a list of settings in groups (left and right arrows switch
group), with a description of the highlighted one under it. The defaults are sound: 300 warm-up
and 700 kept draws on each of 8 chains is the sampler default.

- **Enter** edits: yes/no turns over, a colour is picked from a list (or typed as `#rrggbb`),
  a font from the fonts installed on this machine (the math font only from fonts with a `MATH` table),
  anything else is typed on one line. Every value is checked as you type it.
- `*` marks a change not saved yet, `!` a setting that cannot be saved (its message stays until
  the next key). **`^w`** saves, **`^u`** undoes the one under the cursor, **`^r`** resets the
  group to its default (in a project: to the global value).
- Every setting is on a sheet. A run that does not converge at the first pass is rerun once longer
  (`RETRY_N_ADAPT`, `RETRY_N_DRAWS`), so a small sampler can end as a longer run. The ones you may want: `N_ADAPT` and `N_DRAWS` (the
  sampler's length), `RNG_SEED` (the same seed gives the same result), `N_CHAINS`,
  `VAL_SIGMA` (the half-width of the reported interval in standard deviations; 2 is about 95 %),
  `FIGURES_FORMATS` (PDF/PNG/SVG figures; needs LaTeX), `FIGURES_DIR` (the plot folder),
  `TABLE_DIR` (the data folder) and `FIGURES_COMPILER` (the LaTeX compiler) and the colours,
  line widths and fonts of the `plots` sheet.
- The comparison figure's colours, markers and sizes of the terminal plots are lists typed on one line:
  `#D55E00, #0072B2, red`, `o, square, triangle` and `76x5, 100x9` (a wrong line is refused and stays).
- The `model` sheet also selects data and structure: `Q_MIN`/`Q_MAX` (q limits in Å⁻¹, `none` for no limit),
  `SIGMA_SCALE`, `EXCLUDE_Q` (ranges typed `0.1-0.2, 0.5-0.6`), `CHAINS` (`A B`, empty for all chains),
  `MODEL` and `ADD_HYDROGENS`.
- The main menu's `settings` edits the **global** settings, which new projects copy.

### 5. Run

When the project has a model, a buffer (with at least one solute, a pH and a temperature) and data (with its
energy), the project menu shows **`run: shift+r`** at the bottom. Press **Shift+R**.

1. The run starts at once, at the buffer's temperature (set with `^g` after the pH and σ; a project
   made before that needs it set once: the prompt starts at your last run's temperature, so Enter
   does it).
2. The **run screen** shows Julia's output live. The keys are locked; the footer says `abort
   and quit: ^c`. A fit takes from minutes to much longer, and the first one is slower because
   of the compile.
3. At the end the counter says `done`, `failed` or `aborted` and **Enter** goes back to the project
   menu. A failed run shows the first line of its error.

**Ctrl-C (or Ctrl-D) stops the run and quits the program**: Julia is asked to finish its log, then
stopped. Only one run per project can be live at once: another start says `a run is in progress
(pid N)`. While it runs you can edit nothing that it uses: it works on a copy of your project
files made at the start.

### 6. Read the results

`open...` (`o`) in the project menu. With no run yet it opens the project folder in your file
manager. Once a run exists it offers `open project folder` and **`open runs`**.

```
 open · runs                                                      project: demo

 > 10:15:00:000 EST -05:00 · 2026-11-07 lyz  done


 ╭╮ ╭╮╷ ╷╭╮╭╮╷
 ├┴╮├┤╰┬╯╰╮│││    open: ⏎    ┃ delete run: ^r
 ╰─╯╵╵ ╵ ╰╯╰╯╰─   run.LOG: ^l ┃ back: ^x
```

- The list shows each run (named by its UTC start time, newest first) and, under it, one row per
  model with its state: `done`, `failed`, `aborted`, `interrupted`. A model that did not finish
  says why in the note row.
- **Enter** on a `done` model opens the **results workbook** (`<model>.xlsx`) in a viewer, one
  tab per sheet: **`[`** and **`]`** change sheet, the arrows move the cursor.
  **`^p`** switches to the **plots** of that model (the same text plots a script prints; one tab per
  plot), and back.
  The plots are written at several sizes; the viewer shows the largest that fits its window and picks
  again when you resize it.
- A run that made the **comparison** (the measured curve, every model and the references on one plot) has one
  more row, `comparison`, after its models: Enter opens its workbook and plots. A model that has settings of
  its own is marked `*`, and the note row says which.
- **`^l`** on a run reads its `run.LOG` (the full log, including the sampler's output and the
  errors) in a pager: Enter, Space and PgDn page down, `b` and PgUp page up. Esc closes it.
- **`shift+d`**, **`shift+t`** and **`shift+c`** take files out of a run. **`shift+d`** *moves the data*
  (every model's workbook and the comparison table `.tsv`) to your data folder and **`shift+t`** *moves the tex
  plots* (every `.tex` figure of every model and the comparison) to your plot folder: each opens a dropdown,
  **`move all`** (the whole run) or **`move by model: NAME`** (one model, or the `comparison`). **`shift+c`**
  *compiles* the highlighted row's figures with LaTeX into PDFs in the plot folder. The folders are the
  settings `plot dir` and `data dir` (`output` settings), by default the `plots` and `data` folders of the
  BAYSOL data folder, one folder for all projects. The files go into a folder named for the run inside it
  (`<plot folder>/<run>/`, `<data folder>/<run>/`), named for the model (`<model>.tex`, `<model>.xlsx`,
  `<project>-compare.tsv`); when a name is taken the files of that model get `-2`, `-3`, ... and nothing is
  ever replaced. Compiling needs a LaTeX compiler: with
  `latex compiler path` empty it looks for `lualatex`, then `xelatex`, on the `PATH`, and if there is none it says so
  (set the path in the output settings; a path you set is never replaced by another compiler).
- **`^r`** deletes the whole run, after a question (never one that is still running).

When a run ends, the program **packs** it (the run screen says `packing`): EVERYTHING of the run (`run.json`, the
workbooks, the logs, the inputs, the plots) goes into ONE 7z archive, `runs/<stamp>.7z`, which is tested before the
run folder is removed; if packing fails the folder stays as it was and the note says why. Runs, logs and plots read
the archive, or the plain folder of a run that is still going, alike.

### Logs: read and restore what a run used

`logs` (`g`) in the project menu lists the runs of the project, newest first, with how each ended
(`*` live, `!` interrupted), its models and its size. **Enter** opens a run's options: view its
`run.LOG`, settings, buffer, units and energy, the conditions (temperature, pH, σ, energy as the
log records them), solutes and models; and **restore** its settings, buffer (with pH and σ) or units and
energy into the project. A restore asks one short question (`replace buffer (pH 7.4, σ 0.1)?`) and is
refused while a run is live. Nothing is ever written into a run, and nothing is deleted from here.
(`open...` > `open runs` is for the results workbook and plots, and is where a run is deleted.)

The same files are on disk, for your spreadsheet program, your LaTeX and your records: see below.

### Where everything is on disk

```
<data folder>/
    settings.json            the global settings (only what you changed)
    theme.json               your theme
    custom-solutes.json      your custom solutes
    recipes.json             your saved recipes
    projects/<name>/
        project.json   settings.json   buffer.json
        data.tsv       data.json
        models/                  your .cif / .pdb copies
        runs/<local time, zone, offset, date>.7z  (23-35-29-123_EST_-0500_2026-11-07.7z; the zone is its
                                         abbreviation or, without one, its city: SãoPaulo), ONE file per run
                                         with everything of the run in it, flat:
            run.json run.LOG plots.txt   status, versions, models, timings; the log; the unicode plots
            settings.json buffer.json data.tsv data.json project.json ...   the inputs the run used
                                         (project.json holds the project's notes)
            <model>.xlsx <model>.LOG <model>*.tex <model>-plots.txt   per model
            compare.tsv compare.tex      the comparison
```

Open the project's folder with `open...` > `open project folder` (the main menu's `open` opens
the data folder). Everything is plain JSON, TSV or text, and the interface writes every file
through a temporary file, so a crash never leaves half a file.

### The keys at a glance

| Key | Does |
|-----|------|
| arrows, `⏎` | move, select, edit (a letter on a menu picks its option) |
| `Esc` | closes the open prompt, list, question or viewer; never quits |
| `^x` | back one screen; never quits |
| `q` (main menu), `^c`, `^d` | quit (`^c`/`^d` also stop a run) |
| `^t` | theme list |
| `^w` | save every change on the screen |
| `^u` | undo |
| `^r` | remove or delete the highlighted item (asks first); reset a group of settings |
| `^n`, `^p`, `^f`, `^e` | buffer: add a small molecule, a polymer, a protein, DNA/RNA |
| `^g` | buffer: edit pH, σ and temperature |
| `^k` | buffer: turn the unit of the concentrations (mM, M, µM) |
| `o`, `m` (empty path field) | open the file chooser; list the models |
| `r` (on an unusable file) | reset it |
| `Shift+R` | run (project menu, when ready) |
| `Tab`, `Shift+Tab`, `^p`, `+` `-` | viewer: next/previous sheet or plot; sheets or plots; plots zoom |
| `/`, `n`, `N`, `g` | viewer: find, next/previous match, go to a cell (`B7`, `7`, `B`) |
| `Space`, `c`, `f` | viewer: mark a range, copy it as TSV to the clipboard, show formulas |
| `^l`, `b`, `Space` | `open runs`: read `run.LOG`; pager: page back, forward |
| `shift+d`, `shift+t`, `shift+c` | `open runs`: move the data, move the tex plots (a dropdown: all, or one model), compile the highlighted row's plots |

### If something goes wrong in the terminal interface

| What you see | What to do |
|---|---|
| `BAYSOL: this program needs a terminal` | Run it from a terminal window, not from a pipe. A launcher with no terminal opens one (on Linux your `$TERMINAL`, the desktop's terminal, or the first known one) that runs the program again. |
| A message instead of the screen | The window is under 80 x 24. Enlarge it. |
| `buffer.json unusable!` (or `data`, `settings`, ...) with `r: reset` | The file was changed outside the interface or is damaged. `r` and Enter **reset** it to empty and keep the old one beside it as `<name>.corrupt`, so nothing is lost. |
| `changed on disk: another copy of BAYSOL saved it; reopen it` | A second copy of the program saved this file meanwhile. Leave the screen and reopen it. |
| `missing components: ...` where `run: shift+r` should be | The box names what is missing (`models`, `solutes`, `pH`, `temperature`, `data`, `energy`); `run: shift+r` replaces it once the list is empty. |
| `a run is in progress (pid N)` | The project already has a live run (maybe in another window). Wait for it, or stop it. A crashed run is marked `interrupted` after a minute and stops blocking. |
| `could not start julia: ...` | `julia` is not on the PATH. Install it, or set the environment variable `JULIA` to its full path. |
| A model is `failed`; its first error line is on the run screen | Read the `ERRORS` section at the end of `run.LOG` (`l` in `open runs`). Other models in the run are still fitted. |
| `WLSError` in the log | The fit had too few points (fewer than 3) or the model curve is flat across your q range. Check the curve, the q units and the energy. |
| `a number, please` / `from 0 to 100 °C` | The temperature prompt of `^g` in the buffer wants a number in that range. |
| An unknown residue or element error | The model has a residue BAYSOL does not know. It looks names up online: reconnect and retry. |
| Anything else | Send the developers `run.LOG` of the run and the error text. |

---

## Second way: run it from a script, an RNA/DNA experiment (macOS, Linux, Windows; no coding)

*This is the second way to use BAYSOL. The first, the terminal interface above, needs no script.*

This guide takes you from a computer with nothing installed to a finished fit of your RNA or
DNA scattering curve, on **macOS, Linux or Windows**. You will copy and paste commands into a
terminal and edit one small text file. You do not need to write any code.

> **Status, said plainly.** Here you run one short text file (a "script") from a terminal; for
> menus and a run key, use the terminal interface above. The developers have run BAYSOL on **Linux
> (ARM)**. **macOS, Windows and Intel/AMD machines have not been tested yet.** The steps below
> use only standard tools, so they should work, but if one fails, copy the error message from
> the terminal and send it to the developers. **On Windows, the safest route is to use WSL**
> (Windows Subsystem for Linux, a free Linux inside Windows) and follow the Linux steps; see
> Step 1. "If something goes wrong" lists the problems most likely to come up.

---

### What you need before you start

You need four things. Gather them first.

| # | What | Where it usually comes from | Format |
|---|------|-----------------------------|--------|
| 1 | **The scattering curve** | your beamline, or the SASBDB entry | a text file with three columns: `q`, `intensity`, `error` |
| 2 | **A 3D model of your RNA/DNA** | the PDB (rcsb.org), a model you built, or a prediction | a `.pdb` or `.cif` file, **or** a 4-character PDB ID such as `1EHZ` |
| 3 | **The buffer recipe** | your lab notebook or the SASBDB entry | list of components with concentrations, plus the pH |
| 4 | **The X-ray energy or wavelength**, and the temperature | the beamline | numbers |

#### The most important point: your strand goes in as a 3D model, not as a sequence

BAYSOL calculates the scattering of a **3D structure**. It does not read the sequence of the
molecule you measured, and it cannot predict a 3D structure from one.

- If you have a structure file (`.pdb` or `.cif`), you give BAYSOL the file's location. It reads
  the file itself. You never type or paste the strand, however long it is. See "Loading a very
  long strand without typing it".
- If you only have a sequence, you must first make a 3D model with another program (for example
  an RNA or DNA 3D-modelling server, or a structure predictor). That is outside BAYSOL. The
  quality of the fit depends on how good that model is. Models made only of dummy atoms or
  beads are not what BAYSOL is built for.
- The **sequence** does matter in one case: when the *buffer* contains free DNA or RNA that was
  also in the blank (for example carrier tRNA). "When the buffer itself contains DNA or RNA"
  shows how to load that sequence from a file instead of typing it.

**Never list your measured molecule in the buffer recipe.** BAYSOL measures contrast against the
buffer, so only list what is in the buffer blank.

### What to install (the bare minimum)

You need exactly three things, plus an internet connection for the first run.

1. **Julia**, the programming language BAYSOL runs in (free).
2. **The BAYSOL files** (a free download from GitHub, a single ZIP).
3. **A plain-text editor** to edit one file (one you already have is fine).

You do **not** need to install Python, conda, Git, a C compiler or LaTeX. BAYSOL downloads its
own small helper programs (PROPKA and pdb2pqr, which add hydrogen atoms to your structure) the
first time it runs.

#### Step 1. Open a terminal

A terminal is a window where you type commands. Each command below is typed or pasted there,
followed by **Enter** (**Return** on a Mac).

| Platform | How to open it |
|----------|----------------|
| **macOS** | Press **Cmd + Space**, type `Terminal`, press Return. |
| **Linux** | Open the application called *Terminal* (often **Ctrl + Alt + T**). |
| **Windows** | Open the Start menu, type `PowerShell`, and open **Windows PowerShell**. Use PowerShell, **not** "Command Prompt". |

**Windows only: should you use WSL?** Because the developers have not tested BAYSOL on Windows,
the most reliable route is WSL. In PowerShell run `wsl --install`, restart the computer when
asked, open **Ubuntu** from the Start menu, and then follow every step below **as Linux**. Your
Windows files are visible inside Ubuntu under `/mnt/c/Users/<your name>/`. If you would rather try
plain Windows first, the steps below also cover it.

In the rest of this guide, commands marked **macOS / Linux** go in a macOS or Linux terminal (or
Ubuntu under WSL), and commands marked **Windows** go in PowerShell.

#### Step 2. Install Julia

**macOS / Linux.** Paste this line and press Enter:

```
curl -fsSL https://install.julialang.org | sh
```

Accept the defaults when it asks (answer `y`, or press Enter). When it finishes, **close the
terminal completely and open a new one**.

**Windows.** In PowerShell:

```
winget install --name Julia --id 9NJNWW8PVKMN -e -s msstore
```

(Or install "Julia" from the Microsoft Store, or from <https://julialang.org/downloads/>.) Then
**close PowerShell and open a new one**.

**All platforms.** In the new terminal, ask for Julia 1.12 (the version BAYSOL was tested with)
and check it:

```
juliaup add 1.12
juliaup default 1.12
julia --version
```

The last command should print something starting with `julia version 1.12`.

#### Step 3. Download BAYSOL

1. In your browser, open
   <https://github.com/noshou/BAYSOL/archive/refs/tags/v0.4.0.zip>. A ZIP file downloads.
2. Unzip it: double-click it (macOS), right-click and choose *Extract* (Linux), or right-click
   and choose *Extract All* (Windows). A folder called `BAYSOL-0.4.0` appears.
3. Move that folder into your **home folder**: the folder named after you (in Finder's sidebar
   on a Mac, in *Files* on Linux, or `C:\Users\<your name>` on Windows). Do not put it inside
   OneDrive on Windows if you can avoid it.

From here on, the folder is written `~/BAYSOL-0.4.0` on macOS and Linux, and
`$HOME\BAYSOL-0.4.0` on Windows.

#### Step 4. A plain-text editor

You will edit one text file, `run.jl`. It must be saved as **plain text** with **straight
quotes** (`"`), not curly ones (`“ ”`), which break it.

- **Any platform:** the free editor **Visual Studio Code** works everywhere and never changes
  your quotes.
- **macOS, TextEdit** (already installed): open **TextEdit > Settings** (**Preferences** on
  older macOS), then *New Document* > **Plain text**, and under *Options* untick **Smart quotes**
  and **Smart dashes**.
- **Windows, Notepad** (already installed): it saves plain text. When you save, set *Save as
  type* to **All files** and type `run.jl` as the name, so that it does not become `run.jl.txt`.
  In File Explorer, switch on *View > Show > File name extensions* to check.
- **Linux:** any editor (gedit, Kate, nano, …) is fine.

Do **not** use Word, Pages or Google Docs.

### First-time setup of BAYSOL (once)

This downloads BAYSOL's building blocks. It needs internet and takes several minutes. Wait until
the prompt comes back.

**macOS / Linux:**

```
cd ~/BAYSOL-0.4.0
julia --project=test/fitting_tests -e 'using Pkg; Pkg.instantiate()'
```

**Windows:**

```
cd $HOME\BAYSOL-0.4.0
julia --project=test/fitting_tests -e 'using Pkg; Pkg.instantiate()'
```

`cd` means "go into this folder". The second command installs what BAYSOL needs.

#### Check that it works with a ready-made RNA example (recommended)

BAYSOL ships with real RNA examples. This one is a 186-nucleotide ribozyme dimer. Run it from the
same folder:

```
julia --project=test/fitting_tests test/fitting_tests/SASDAC9/SASDAC9.jl
```

(The same line works on every platform.) The first run compiles a lot of code and downloads the
helper programs, so it is slow. It prints progress, draws small text plots, and ends with a
summary. If it reaches the summary, your installation works. Later runs start much faster. (I
have not timed this outside the developers' machine; expect several minutes the first time.)

To stop any run, press **Ctrl + C**.

### Set up your own experiment

#### Make a folder for it

In your file manager, create a folder, for example `my_rna_experiment`, in your home folder. Put
three things inside:

| File | What it is |
|------|------------|
| `data.dat` | your scattering curve (rename your file to this, or change the name in the script) |
| `structure.pdb` | your 3D model (or `structure.cif`) |
| `run.jl` | the script you edit and run (see "The script") |

#### What the curve file must look like

Three columns separated by spaces, tabs or commas: `q`, `intensity`, `error`. Lines at the top or
bottom that are not numbers (headers, comments) are skipped. For example:

```
  0.2098   3456.9   19.47
  0.2159   3432.7   15.36
  0.2219   3378.7   17.39
```

**Check the units of `q`.** BAYSOL works in inverse ångström (Å⁻¹). Many beamlines and SASBDB
files give `q` in inverse nanometres (nm⁻¹). The numbers then run from about 0.2 to 3, not
0.02 to 0.3. The script has one setting for this (`Q_UNITS`). Getting it wrong is the easiest way
to get nonsense, so check it. A `q` that runs up to about 0.3–0.5 is Å⁻¹; one that runs up to
3–5 is nm⁻¹.

#### The script

In your editor, make a new plain-text document and paste everything between the two lines of
`=====` below. Then change **only the "YOUR SETTINGS" block** at the top. Save it as `run.jl` in
your experiment folder.

```julia
# =========================== run.jl ===========================
using BAYSOL
using BAYSOL.MolecularStructure: LocalPathSource, PDBIDSource
using BAYSOL.BulkElectronDensity: Solute, NonBiological, DNA, RNA
using BAYSOL.PhysicalConstants: HC_EV_ANGSTROM

# ------------------------- YOUR SETTINGS -------------------------

const HERE = @__DIR__                     # the folder this file is in; leave as it is

# 1. The curve
const DATA_FILE = joinpath(HERE, "data.dat")
const Q_UNITS   = "1/nm"                  # "1/nm" or "1/A"  (see "What the curve file must look like")
const Q_MAX     = 0.3                     # fit up to this q, in 1/A. 0.3 is a common choice.

# 2. The 3D model. Use ONE of the next two lines (put a # at the start of the other).
const STRUCTURE = LocalPathSource(joinpath(HERE, "structure.pdb"))
# const STRUCTURE = PDBIDSource("1EHZ")   # a PDB ID instead of a file (needs internet)

# 3. The measurement
const PH             = 7.5
const PH_UNCERTAINTY = 0.1                # how well you know the pH; 0.1 is a normal choice
const TEMPERATURE_C  = 25.0
const WAVELENGTH_A   = 1.03               # X-ray wavelength in ångström (0.103 nm = 1.03 A)
const ENERGY_EV      = HC_EV_ANGSTROM / WAVELENGTH_A
# If you know the energy instead, comment the line above and write:  const ENERGY_EV = 12000.0

# 4. The buffer: one line per component, in this form:
#        NonBiological(concentration in mol/L, uncertainty in mol/L, "name"),
#    25 mM = 0.025.  A 1 % uncertainty on 0.025 M is 0.00025.
#    Do NOT list your own RNA/DNA here (see "When the buffer itself contains DNA or RNA").
const SOLUTES = Solute[
    NonBiological(0.025, 0.00025, "potassium chloride"),
    NonBiological(0.010, 0.0002,  "tris"),
    NonBiological(0.005, 0.0001,  "magnesium chloride"),
    # the chloride that comes from adjusting Tris to the pH with HCl:
    NonBiological(0.008462, 0.000441, "chloride"),
]

# ----------------------- END OF YOUR SETTINGS -----------------------

# Reads the curve file: three number columns, anything else is skipped.
function read_curve(path)
    q = Float64[]; I = Float64[]; σ = Float64[]
    for line in eachline(path)
        t = split(replace(strip(line), ',' => ' '))
        length(t) ≥ 3 || continue
        v = tryparse.(Float64, t[1:3])
        any(isnothing, v) && continue
        push!(q, v[1]); push!(I, v[2]); push!(σ, v[3])
    end
    return q, I, σ
end

q, I, σ = read_curve(DATA_FILE)
isempty(q) && error("no numbers found in $DATA_FILE; is it three columns?")
Q_UNITS == "1/nm" && (q = q ./ 10)        # BAYSOL wants 1/A
keep = [i for i in eachindex(q) if q[i] ≤ Q_MAX && σ[i] > 0]
q, I, σ = q[keep], I[keep], σ[keep]
println("Using $(length(q)) data points, q from $(minimum(q)) to $(maximum(q)) 1/A")

# Build the model, sample it, write the results.
seed   = BAYSOL.seed_model(STRUCTURE, ENERGY_EV, q, I, σ, PH, PH_UNCERTAINTY, SOLUTES;
                           t = TEMPERATURE_C)
result = BAYSOL.run_model(seed)
BAYSOL.results(result, seed; dir = HERE, name = "res", font = nothing, run_log = true)
BAYSOL.print_summary(result)
# =========================== end ===========================
```

**What the buffer names mean.** The names (`"potassium chloride"`, `"tris"`) are looked up in a
table BAYSOL ships with. Common names, abbreviations and formulas work for most chemicals. To
check a name (replace `glycerol` with your word):

**macOS / Linux:**

```
grep -i "glycerol" ~/BAYSOL-0.4.0/src/BulkElectronDensity/NonBiological/nonbio_lookup.json
```

**Windows:**

```
Select-String -Pattern "glycerol" -Path "$HOME\BAYSOL-0.4.0\src\BulkElectronDensity\NonBiological\nonbio_lookup.json"
```

If a line comes back, the name works. If nothing does, try a synonym or the formula. BAYSOL does
not guess buffer components you leave out; list everything that was in the blank. For real
recipes, open one of the example scripts in the `test/fitting_tests` folder of BAYSOL (each
`SASD….jl` file there has its buffer written out with comments) and copy the buffer lines that
look like yours.

### Loading a very long strand without typing it

For the molecule you **measured**, the strand comes in through the structure file, so there is
nothing to type:

- **A file on your computer:** put it in the experiment folder as `structure.pdb` (or `.cif`). The
  line `LocalPathSource(joinpath(HERE, "structure.pdb"))` in the script reads it, however many
  thousands of atoms it holds. If the file has another name, change the name inside the quotes.
- **A file somewhere else:** give its full path inside the quotes, for example
  `LocalPathSource("/Users/yourname/Documents/my_model.pdb")` (macOS), `"/home/yourname/…"`
  (Linux), or `"C:/Users/yourname/Documents/my_model.pdb"` (Windows). **Use forward slashes `/`
  even on Windows**; backslashes need to be doubled (`\\`). To get a file's path, drag the file
  from your file manager into the terminal window (macOS, most Linux terminals and PowerShell
  type the path for you), or on Windows hold **Shift**, right-click the file and choose *Copy as
  path*.
- **A structure from the PDB:** use the commented line `PDBIDSource("1EHZ")` with your own
  4-character ID. BAYSOL downloads it.
- **A link to a file on the web:** `URLSource("https://…/model.pdb", "my_model")`. The second
  text is a short name you choose for it.

BAYSOL reads standard RNA and DNA residues and the usual modified bases (for example
pseudouridine). It adds the hydrogen atoms itself. Bigger structures take longer: the largest
RNA example in the test set has about 12,000 atoms.

### When the buffer itself contains DNA or RNA (long sequence from a file)

This applies only if free DNA or RNA was in the buffer blank. Then BAYSOL needs its sequence
and its concentration. Put the sequence in a text file and let the script read it.

1. Save the sequence as `buffer_strand.txt` in the experiment folder. A plain sequence on one
   or several lines works, and so does the FASTA format (a first line starting with `>`). Use
   `T` for DNA and `U` for RNA.
2. In `run.jl`, add this block **just above** the line `const SOLUTES = Solute[`:

```julia
# Reads a sequence from a file: ignores the ">" name line, spaces and line breaks.
function read_sequence(path)
    lines = [strip(l) for l in eachline(path) if !isempty(strip(l)) && !startswith(strip(l), ">")]
    seq = uppercase(join(lines))
    occursin(r"^[ACGTUNRYSWKMBDHV]+$", seq) ||
        error("$path contains characters that are not nucleotide letters")
    return seq
end
const BUFFER_STRAND = read_sequence(joinpath(HERE, "buffer_strand.txt"))
```

3. Add one line inside the `SOLUTES` list, with `RNA` or `DNA` as appropriate:

```julia
    RNA(5e-5, 5e-6, BUFFER_STRAND),     # concentration in mol/L, then its uncertainty
```

**Working out the concentration.** BAYSOL wants **moles of strands per litre**. If you know
grams per litre (the same number as mg/mL) and the molecular weight of the strand in g/mol:

```
molarity = (g per litre) / (molecular weight)
example: 0.5 mg/mL = 0.5 g/L, for a 10 000 g/mol strand  →  0.5 / 10000 = 0.00005 = 5e-5 mol/L
```

The script stops with a message if the file contains something that is not a nucleotide letter.
Several different buffer strands: save each in its own file and add one `read_sequence` line and
one `RNA(…)` or `DNA(…)` line for each.

### Run it, and read the result

From the BAYSOL folder, run your script. Use your folder's real name.

**macOS / Linux:**

```
cd ~/BAYSOL-0.4.0
julia --project=test/fitting_tests ~/my_rna_experiment/run.jl
```

**Windows:**

```
cd $HOME\BAYSOL-0.4.0
julia --project=test/fitting_tests $HOME\my_rna_experiment\run.jl
```

Tip: type the second command up to `julia --project=test/fitting_tests ` (with the trailing
space) and then drag `run.jl` from your file manager into the terminal window to fill in the
path.

BAYSOL shows its steps, draws small text plots (the fit, the residuals, and one histogram per
parameter), and finishes with a summary. Each run uses a fresh random seed, so repeated runs
differ slightly.

#### What appears in your experiment folder

| File | What it is |
|------|------------|
| `res.xlsx` | A workbook that opens in Excel, Numbers or LibreOffice. It holds the fit, the residuals, the parameter values and uncertainties, and every sample. The `run` sheet explains each row. |
| `plots/` | The figures as `.tex` files (see below). |
| `my_rna_experiment.LOG` | A short record of the run: versions, the fit's χ², the sampler's health, and timings. Keep it with your results. |

#### Reading the summary

The run ends with a few lines that start with `Fit finished:`.

- **`reduced χ² = …`**: how far the model is from the data, scaled by the error bars. A value
  near 1 is a good fit. A value far above 1 means the 3D model does not describe the data well
  (or the error bars are too small). The number is calculated on your measured points.
- **The four parameter lines**: ρₑ is the buffer's electron density, and δρ₁, δρ₂, δρ₃ are the
  contrasts of the water layers around your molecule. Each is printed with an interval.
- **`Checks:`** says whether the sampler converged. Look for `converged` and `no divergent
  transitions`. `NOT converged` means the chains did not agree, and the intervals should not be
  trusted.
- **`Note:` lines** explain anything unusual. For example, that more than 1 % of the steps
  diverged, that the posterior has several modes (two or more equally plausible answers), or
  that a fit parameter sits on its limit. Read them before using the numbers.
- The last lines name the workbook, the figure folder, the log file and the time the run took.

BAYSOL does **not** check your buffer list for you. If a component that was in the blank is
missing from `SOLUTES`, the fit will simply be less accurate, so check the list yourself.

#### Making PDF figures

The figures are written as `.tex` files, which need LaTeX to turn into pictures. LaTeX is a large
install and **is not needed** to run BAYSOL. The easy way: create a free account on the website
Overleaf, upload a `.tex` file from `plots/`, and compile it. (I have not tried Overleaf with
these files; they are standard "standalone" plots from pgfplots, written to work with any
LaTeX engine.) Alternatively, draw your own figures from the numbers in `res.xlsx`.

### If something goes wrong

| What you see | What to do |
|---|---|
| `command not found: julia` (macOS/Linux) or `julia is not recognized` (Windows) | Close the terminal, open a new one and try again. If it still fails, redo Step 2. |
| `could not find file …` or `No such file` | A name or path is wrong. Check the spelling and capital letters of `data.dat`, `structure.pdb` and the folder; drag the file into the terminal to get its exact path. |
| `syntax: invalid character` or strange errors right at the start | Curly quotes crept into `run.jl`. Redo Step 4 and check every `"` is a straight quote. |
| (Windows) `run.jl` is not found although you saved it | It may have been saved as `run.jl.txt`. Turn on *File name extensions* in File Explorer and rename it. |
| `no numbers found in …` | The curve file does not have three number columns. Open it and look. |
| Results look absurd (huge χ², tiny `q` range) | Wrong `Q_UNITS`. See "What the curve file must look like". |
| It stops at "propka" or "pdb2pqr" with a download error | These helpers are fetched on first use and need internet. Connect and rerun. |
| (Windows) errors about a file path or a program that cannot be started | Windows is the least tested platform. Use WSL (Step 1) and follow the Linux steps. |
| An error that mentions an unknown residue | Your structure has a residue name BAYSOL does not know. It looks unknown names up online, so reconnect and retry; if it persists, tell the developers the name. |
| A log message about **undefined behaviour** or dummy atoms | Your model looks like a bead or dummy-atom model. BAYSOL expects an atomic model. |
| It seems frozen | The first run can take many minutes with no output while code compiles. Wait; use Ctrl + C only if nothing has happened for a very long time. |
| Anything else | Copy the complete error text from the terminal, plus the `.LOG` file if one exists, and send them to the developers. |

### Checklist

- [ ] Julia installed and `julia --version` shows 1.12
- [ ] The `BAYSOL-0.4.0` folder is in your home folder
- [ ] The first-time setup command finished without errors
- [ ] The RNA example (`SASDAC9`) reached its summary
- [ ] Your folder has `data.dat`, `structure.pdb`, `run.jl`
- [ ] `Q_UNITS`, pH, temperature, wavelength or energy and the buffer in `run.jl` match your measurement
- [ ] Your own RNA/DNA is **not** in the buffer list
- [ ] You ran the script and kept `res.xlsx`, `plots/` and the `.LOG` file together

### Words used here

- **q**: how steeply the X-rays were scattered; the horizontal axis of your curve.
- **Buffer blank**: the same solution without your RNA/DNA, measured and subtracted.
- **Contrast**: how much denser (in electrons) your molecule or its water layer is than the buffer.
- **PDB / mmCIF**: the two standard file types for 3D structures.
- **Terminal**: the text window where you type commands.
- **Script**: a text file of instructions, here `run.jl`.

## For Julia users

```julia
using BAYSOL
seed = BAYSOL.seed_model(structure, energy, q, I, σ, pH, σ_pH, solutes)
res  = BAYSOL.run_model(seed)                    # NUTS: 300 warm-up + 700 draws, 8 chains
BAYSOL.results(res, seed; dir = "out")           # terminal plots, pgfplots .tex files, out/res.xlsx
BAYSOL.print_summary(res)                        # χ², the parameters, the checks, the files
```

`results` also takes `compile = true` (PDF, SVG or PNG; needs `lualatex` or `xelatex`), a `PlotStyle`, a `font`, and `run_log = true` for the run log. Every option is explained in the [Pipeline guide](src/Pipeline/README.md). Start Julia with `julia -t auto` to use several threads; results are the same at any thread count ([Runtime guide](src/Runtime/README.md)).

## For developers: the tools and the tests

BAYSOL is Julia, and so are the tools around it (tests, result comparison, formatting, benchmarks, figures, the docs build). They are the package `Dev` in [`dev/`](dev/README.md), started with one script, `dev/bysl.jl`, on Linux, macOS and Windows.

### What to install

| Tool | Used for | Needed? |
|------|----------|---------|
| **Julia 1.12** | the package, the tools, the unit suite, the docs build | yes (as in "Step 2" above; `JULIA=/path/to/julia` picks another) |
| **git** | `bysl results compare` reads other revisions | for that |
| **LuaLaTeX or XeLaTeX** (TeX Live), plus poppler for PNG/SVG | `bysl plots` | optional |

### One-time setup

Instantiate the Julia environments you will use, from the repository root:

```
julia --project=dev -e 'using Pkg; Pkg.instantiate()'                   # the tools
julia --project=dev/test -e 'using Pkg; Pkg.instantiate()'              # the tools' tests
julia --project=test -e 'using Pkg; Pkg.instantiate()'                  # the unit suite
julia --project=test/fitting_tests -e 'using Pkg; Pkg.instantiate()'    # the fitting tests
julia --project=test/format -e 'using Pkg; Pkg.instantiate()'           # JuliaFormatter, for bysl fmt
julia --project=docs -e 'using Pkg; Pkg.instantiate()'                  # the docs build
```

### Running the tools

```
alias bysl='julia --startup-file=no -O0 --compile=min /path/to/BAYSOL/dev/bysl.jl'
bysl help                    # every tool with a line each
bysl <tool> --help           # the usage of one tool
```

| Command | What it does |
|---------|--------------|
| `bysl unit [names]` | the Julia unit suite (names pick the files: `bysl unit shannon wls`) |
| `bysl test [names]` | the tests of the tools themselves |
| `bysl fits list`, `bysl fits run SASDMJ9` | the fitting tests, and running one (all if none is named) |
| `bysl precommit` | every check before a commit (`--quick`: only the fast ones) |
| `bysl fmt`, `bysl fmt --lines` | format the code, find lines over 92 characters |
| `bysl docs` | build this documentation site (strict) |
| `bysl plots render DIR` | turn the figures' `.tex` files into PDF, SVG or PNG |
| `bysl results compare REV` | compare fitting-test results with a git revision |
| `bysl results table --update` | regenerate the Results table in the fitting-test README |
| `bysl fits bench` | the cold/steady benchmark (prints its plan unless `--approved`) |

### Where things are

- [dev/README.md](dev/README.md): every tool, its options, the benchmark protocol and the diagnostics.
- [test/README.md](test/README.md): the test tree. [Unit tests](test/unit_tests/README.md), [fitting tests](test/fitting_tests/README.md) (worked examples, with the Results table), [baselines](test/baselines/README.md) (the reference benchmark of each release), [fixtures](test/fixtures/README.md) (the data the tests read) and [visualizations](test/visualize/README.md).
- `dev/test/`: the tests of the tools (run by `bysl test`).
- Before a commit, run `bysl precommit`: the tool tests, the unit suite, formatting, the line-length check, the Results-table check and a strict docs build.

## What the numbers mean

The reported parameters and uncertainties are conditional on the Gaussian scattering model, the measurement errors and the priors. Validation across 53 fits and three synthetic cases found no general justification for inflating the errors; an experimental correlated-discrepancy model risked absorbing systematic misfit and shifting estimates.
