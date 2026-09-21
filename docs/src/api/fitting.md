# Fitting

Stage-1 Bayesian fitting (`src/Fitting/`): the WLS profile/marginal
likelihoods, the ξ-space priors (`src/Fitting/Priors/`), the ξ<->θ
reparameterization, and the NUTS sampler wiring (`AdvancedHMC.jl`) that
drives `run_fitting`.

```@autodocs
Modules = [BayeSol.Fitting]
```
