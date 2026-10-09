# BAYSOL: Bayesian CRYSOL

Bayesian CRYSOL SAS fitting for proteins, with nucleotide (DNA/RNA) support in progress.

BAYSOL builds the five-species (vacuum, excluded volume, convex/concave/cavity hydration shell) multipole forward model for a structure. It then samples the posterior over ξ = (ρₑ, δρ₁, δρ₂, δρ₃) with NUTS (AdvancedHMC.jl), using ForwardDiff gradients. Before sampling, a multi-start L-BFGS search finds the mode and the coordinates are whitened around it (the map is affine, so the target is unchanged). ρₑ is the buffer's electron density and δρ₁–δρ₃ are the hydration-shell contrasts. Scale and background are fitted in closed form, and CRYSOL's excluded-volume correction c1 is profiled at every evaluation.

- Documentation: [BAYSOL](https://noshou.github.io/BAYSOL/). Each module's README under `src/` is also a Guides page there.
- Worked analyses of 27 SASBDB entries: [fitting tests](test/fitting_tests/)
- Test runners and developer tools (fitting tests, result comparison, sampler diagnostics, benchmarks): [test/run](test/run/README.md), [test/utils](test/utils/README.md)

```
# unit tests
julia --project=test test/run/unittests.jl

# example of an end-to-end fit
julia --project=test/fitting_tests test/fitting_tests/SASDMJ9/SASDMJ9.jl

# build the docs (copies src/*/README.md into docs/src/guides/ and the test READMEs into docs/src/testing/)
julia --project=docs docs/make.jl
```

 BAYSOL’s reported parameters and uncertainties are conditional on the gaussian scattering model, measurement errors, and priors. Validation across 53 fits and three synthetic cases found no general justification for global error inflation, while an experimental correlated-discrepancy model risked absorbing systematic misfit and shifting estimates.
