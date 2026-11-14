# Pipeline: entry points

The pipeline entry points `seedModel` and `runModel` and their result types (`src/pipeline/`): `seedModel` loads the structure and the data and builds the forward cache and priors, and `runModel` samples the posterior. (`runProject`, which does all of it for every model of a project folder and writes the run folder, belongs to the terminal interface: `tui/src/store/run-project.jl`.) The package root re-binds the entry points (including `results`, `writeLog` and `printSummary`) as `BAYSOL.seedModel` etc. The figures and the workbook are on [Pipeline: results and figures](@ref), the run log, summary and tables on [Pipeline: run log and tables](@ref), and the tunable constants and the settings as keywords on [Pipeline: settings](@ref).

```@autodocs
Modules = [BAYSOL.Pipeline]
Pages   = ["pipeline.jl", "seed-model.jl", "run-model.jl"]
```
