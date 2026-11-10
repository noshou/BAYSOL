# Pipeline: settings

The tunable constants of the pipeline (`Params.jl`: sample counts, retry and plot defaults, and the data and structure settings `Q_MIN`, `Q_MAX`, `SIGMA_SCALE`, `EXCLUDE_Q`, `LMAX`, `CHAINS`, `MODEL`, `ADD_HYDROGENS`) and the settings file (`Settings.jl`: `load_settings`, `settings_file`, `seed_keywords`, `run_keywords`, `run_arguments`, `results_keywords`, the setting tables and `InvalidSettingsError`) and the buffer of a project (`Buffer.jl`: `load_buffer`, `load_buffer_ph` and `InvalidBufferError`). They configure the calls on [Pipeline: entry points](@ref) and [Pipeline: results and figures](@ref).

```@autodocs
Modules = [BAYSOL.Pipeline]
Pages   = ["Params.jl", "Settings.jl", "Buffer.jl"]
```
