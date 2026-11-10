# Pipeline: entry points

The pipeline entry points `seed_model` and `run_model` and their result types (`src/Pipeline/`): `seed_model` loads the structure and the data and builds the forward cache and priors, `run_model` samples the posterior, and `run_project` does all of it for every model of a project folder and writes the run folder. The package root re-binds the entry points (including `results`, `write_log` and `print_summary`) as `BAYSOL.seed_model` etc. The figures and the workbook are on [Pipeline: results and figures](@ref), the run log, summary and tables on [Pipeline: run log and tables](@ref), and the tunable constants and the settings file on [Pipeline: settings](@ref).

```@autodocs
Modules = [BAYSOL.Pipeline]
Pages   = ["Pipeline.jl", "SeedModel.jl", "RunModel.jl", "RunProject.jl"]
```
