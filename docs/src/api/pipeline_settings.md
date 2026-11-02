# Pipeline: settings

The tunable constants of the pipeline (`Params.jl`: sample counts, retry and plot defaults) and the settings file (`Settings.jl`: `load_settings`, `settings_file`, the setting tables and `InvalidSettingsError`). They configure the calls on [Pipeline: entry points](@ref) and [Pipeline: results and figures](@ref).

```@autodocs
Modules = [BAYSOL.Pipeline]
Pages   = ["Params.jl", "Settings.jl"]
```
