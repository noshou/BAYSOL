# Fitting tests

Status: placeholder, no tests here yet.

`test/unit_tests/` checks correctness of individual pieces (forward model,
priors, WLS, the NUTS wiring in `test_sampler.jl`, etc.) against synthetic
data and hand-derived reference formulas. This directory is for the next
tier up: running the real stage-1 fit (`seed_model`/`run_model` in
`src/BayeSol.jl`, backed by `AdvancedHMC.jl`) against real experimental
scattering data and checking recovery/convergence, not just wiring
correctness -- the thing `test_sampler.jl`'s own docstring explicitly says
is out of scope for it.

See `CLAUDE.md` for the planned two-stage pipeline (Bayesian SH-coefficient
fit, then the not-yet-implemented ML shape-reconstruction stage). Fixture
data for this tier lives in `test/fixtures/SASDMJ9/` (a real SASBDB entry:
experimental curve + fitted model + source structure), each case runnable on
its own the same way `test/visualize/` scripts are.
