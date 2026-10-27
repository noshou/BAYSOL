# BAYSOL: Bayesian CRYSOL

Bayesian CRYSOL SAS fitting for proteins, with DNA/RNA support.

BAYSOL builds the five-species (vacuum, excluded volume, convex/concave/cavity hydration shell) multipole forward model for a structure. It then samples the posterior over ξ = (ρₑ, δρ₁, δρ₂, δρ₃) with NUTS (AdvancedHMC.jl), using ForwardDiff gradients. Before sampling, a multi-start L-BFGS search finds the mode and the coordinates are whitened around it (the map is affine, so the target is unchanged). ρₑ is the buffer's electron density and δρ₁–δρ₃ are the hydration-shell contrasts. Scale and background are fitted in closed form, and CRYSOL's excluded-volume correction c1 is profiled at every evaluation.

```julia
using BAYSOL
seed = BAYSOL.seed_model(structure, energy, q, I, σ, pH, σ_pH, solutes)
res  = BAYSOL.run_model(seed)                 # NUTS: 300 warm-up + 700 draws, 8 chains
BAYSOL.results(res, seed; dir = "out")   # terminal plots, pgfplots .tex files, the workbook out/res.xlsx
BAYSOL.write_log(res)  # the run log out/out.LOG: timings and what is worth tracking (or results(...; run_log = true))
BAYSOL.print_summary(res)                      # the verdict: χ², the parameters, the checks, where the files are
```

`results` prints the fit, the residuals and the posterior histograms in the terminal, and writes each figure as a standalone pgfplots `.tex` file (set `compile = true`, or run `bb render-plots`, to turn them into PDF, SVG or PNG; that needs `lualatex` or `xelatex`) and one workbook, `res.xlsx`, with the results as numbers (and, with `run_log = true`, the run's section of a small tracked run log, `<folder>.LOG`, that benchmarks read): the run's settings and sampler statistics, the MAP, the posterior quantiles, the curves, the histogram counts and every draw, one sheet each (the [Pipeline guide](src/Pipeline/README.md) explains every sheet). Every posterior histogram is a figure of its own. The font is an option: any font LuaLaTeX can find (TeX Gyre PagellaX with TeX Gyre Pagella Math by default; `BAYSOL.font_available("Name")` or `bb fonts "Name"` checks one, `bb fonts --list` lists them). See the [Pipeline guide](src/Pipeline/README.md).

- Documentation: [BAYSOL](https://noshou.github.io/BAYSOL/). Each module's README under `src/` is also a Guides page there.
- Worked analyses of 27 protein SASBDB entries and 30 DNA/RNA entries: [fitting tests](test/fitting_tests/)
- Several threads: start Julia with `julia -t auto` (or `-t 6,1`) to use them; results are bit-identical at any thread count. What is threaded and what it buys: the Parallel section of the [Runtime guide](src/Runtime/README.md)
- Test runners and developer tools (fitting tests, result comparison, sampler diagnostics, benchmarks, rendering the figures, the font list): [dev](dev/README.md)

 BAYSOL’s reported parameters and uncertainties are conditional on the gaussian scattering model, measurement errors, and priors. Validation across 53 fits and three synthetic cases found no general justification for global error inflation, while an experimental correlated-discrepancy model risked absorbing systematic misfit and shifting estimates.
