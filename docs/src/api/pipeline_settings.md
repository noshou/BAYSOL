# Pipeline: settings

The tunable constants of the pipeline (`params.jl`: sample counts, retry and plot defaults, and the data and structure settings `Q_MIN`, `Q_MAX`, `SIGMA_SCALE`, `EXCLUDE_Q`, `LMAX`, `CHAINS`, `MODEL`, `ADD_HYDROGENS`) and the settings as keywords (`settings.jl`: `seedKeywords`, `runKeywords`, `runArguments`, `resultsKeywords`, the setting tables, the checks of a value and `InvalidSettingsError`). The settings file, the buffer of a project and the run of a project folder are the terminal interface's (`tui/src/store/`), not part of this module. They configure the calls on [Pipeline: entry points](@ref) and [Pipeline: results and figures](@ref).

```@autodocs
Modules = [BAYSOL.Pipeline]
Pages   = ["params.jl", "settings.jl"]
```
