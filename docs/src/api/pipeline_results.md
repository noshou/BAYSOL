# Pipeline: results and figures

`results` and the figure options `PlotStyle` and `Reference` (`src/Pipeline/Results.jl`): the terminal plots, the pgfplots `.tex` figures and the optional LaTeX compile; and `compare_results` (`src/Pipeline/Compare.jl`), the models of a run and the reference curves on one figure, with the reader of a project's reference curves. The end-of-run summary, the run log and the workbook sheets are on [Pipeline: run log and tables](@ref); the entry points are on [Pipeline: entry points](@ref) and the defaults of the figure look on [Pipeline: settings](@ref).

```@autodocs
Modules = [BAYSOL.Pipeline]
Pages   = ["Results.jl", "Compare.jl"]
```
