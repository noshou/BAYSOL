# tui/julia/src

The module `BAYSOLRun` (`baysol-run.jl`, which includes the other files).

| file | what it does |
| ---- | ------------ |
| `baysol-run.jl` | `runProject`: reads the project, fits every model, writes `<project>/runs/<stamp>/` (`run.json`, the workbooks, the figures, the LOG) |
| `cli.jl` | `runProjectCli`: `baysol run PROJECT --temperature T [--<setting> VALUE ...]`; every flag becomes a keyword of `runProject`, checked like `settings.json` |
| `settings-file.jl` | `loadSettings`: reads and checks `settings.json` and `model-settings.json` |
| `buffer.jl` | `loadBuffer`, `loadBufferPh`: `buffer.json` into the solutes `seedModel` takes, and the pH |
| `model-references.jl` | `model-references.json`: the reference curve and the depositor's χ² of single models |

A setting can come from five places; the first one that gives it wins: the `modelSettings` keyword for one model, `<project>/model-settings.json` for one model, the other keywords of the call (or the command-line flags), `settings.json`, the default in `params.jl`. Settings that belong to the whole run (not to one model) cannot be given per model. A run folder's layout and its rules for concurrent writers are in `notes/run-design.md` (not part of the repository).
