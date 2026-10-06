# Fitting: model and priors

Stage-1 Bayesian fitting (`src/Fitting/`), the model side: the shared types, the WLS
profile/marginal likelihoods, the profiled excluded-volume correction c1, the ξ-space
priors, and the ξ<->θ reparameterization. The NUTS sampler that drives `run_fitting`,
and the MAP search and whitening before it, are on [Fitting: sampler](@ref).

```@autodocs
Modules = [BAYSOL.Fitting]
Pages   = ["Fitting.jl", "WLS.jl", "ProfiledCorrs.jl", "DensityOfSolvent.jl",
           "DeltaRho.jl", "ParamTransform.jl"]
```
