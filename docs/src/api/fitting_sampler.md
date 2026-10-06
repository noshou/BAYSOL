# Fitting: sampler

Stage-1 Bayesian fitting (`src/Fitting/`), the sampler side: the log posterior and the
NUTS wiring (`AdvancedHMC.jl`) that drives `run_fitting` (`Sampler.jl`), and the
multi-start MAP search and Laplace whitening that run before it (`MAP.jl`). The model,
likelihoods and priors it samples are on [Fitting: model and priors](@ref).

```@autodocs
Modules = [BAYSOL.Fitting]
Pages   = ["Sampler.jl", "MAP.jl"]
```
