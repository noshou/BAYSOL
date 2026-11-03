# BAYSOL: Bayesian CRYSOL

Bayesian CRYSOL-style fitting of SAXS curves for proteins and DNA/RNA. Give it a measured curve, a 3D structure and the buffer recipe, and it returns the fit parameters with their uncertainties, not just one best guess.

- Documentation: [BAYSOL](https://noshou.github.io/BAYSOL/). Each module's README under `src/` is also a page there.
- Worked analyses of 27 protein and 30 DNA/RNA SASBDB entries: [fitting tests](test/fitting_tests/README.md)
- Developer tools (test runners, comparison, benchmarks, figure rendering): [dev](dev/README.md)

## Run an RNA/DNA experiment (macOS, Linux, Windows; no coding)

This guide takes you from a computer with nothing installed to a finished fit of your RNA or
DNA scattering curve, on **macOS, Linux or Windows**. You will copy and paste commands into a
terminal and edit one small text file. You do not need to write any code.

> **Status, said plainly.** BAYSOL does not have an app or a "Run" button yet. You run one
> short text file (a "script") from a terminal. The developers have run BAYSOL on **Linux
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
