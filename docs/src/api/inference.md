# Inference: model and priors

Stage-1 Bayesian fitting (`src/inference/`), the model side: the shared types, the WLS
profile likelihood, the profiled excluded-volume correction c1 and its kink check, the ξ-space
priors, and the ξ<->θ reparameterization. The NUTS sampler that drives `infer`,
and the MAP search and whitening before it, are on [Inference: sampler](@ref).

```@autodocs
Modules = [BAYSOL.Inference]
Pages   = ["inference.jl", "params.jl", "priors.jl", "profiled-corrs.jl"]
```
