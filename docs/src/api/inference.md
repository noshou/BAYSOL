# Inference: model and priors

Stage-1 Bayesian fitting (`src/Inference/`), the model side: the shared types, the WLS
profile/marginal likelihoods, the profiled excluded-volume correction c1, the ξ-space
priors, and the ξ<->θ reparameterization. The NUTS sampler that drives `infer`,
and the MAP search and whitening before it, are on [Inference: sampler](@ref).

```@autodocs
Modules = [BAYSOL.Inference]
Pages   = ["Inference.jl", "Shannon.jl", "WLS.jl", "ProfiledCorrs.jl", "DensityOfSolvent.jl",
           "DeltaRho.jl", "ParamTransform.jl"]
```
