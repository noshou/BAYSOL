# Inference: sampler

Stage-1 Bayesian fitting (`src/inference/`), the sampler side: the log posterior and the
NUTS wiring (`AdvancedHMC.jl`: the seed and the chain runner in `posterior.jl`, the driver
`infer` in `infer.jl`), the posterior modes, their mass by bridge sampling and the convergence
statistics (`modes.jl`), and the multi-start MAP search, chain starts and optima that run before
it (`map.jl`). The model,
likelihoods and priors it samples are on [Inference: model and priors](@ref).

```@autodocs
Modules = [BAYSOL.Inference]
Pages   = ["posterior.jl", "infer.jl", "modes.jl", "map.jl"]
```
