# Inference: sampler

Stage-1 Bayesian fitting (`src/inference/`), the sampler side: the log posterior and the
NUTS wiring (`AdvancedHMC.jl`) that drives `infer`, the several-chains logic and
convergence statistics (all in `infer.jl`), the posterior modes and their mass by bridge sampling (`modes.jl`), and the
multi-start MAP search and Laplace whitening that run before it (`map.jl`). The model,
likelihoods and priors it samples are on [Inference: model and priors](@ref).

```@autodocs
Modules = [BAYSOL.Inference]
Pages   = ["posterior.jl", "infer.jl", "modes.jl", "map.jl"]
```
