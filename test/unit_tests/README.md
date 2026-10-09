# Unit tests

| path | contents |
|---|---|
| `testsetup.jl` | the shared baseline every test file includes (`using Test`, `using BAYSOL`, `DEFAULT_ATOL`, `check_float`); include-guarded, so each file also runs standalone |
| `units/` | the tests, one file per module or concern, each self-contained |

The runner is [`../run/unittests.jl`](../run/README.md): it runs everything in `units/`, in name order with `test_quality.jl` last, and a new `units/test_*.jl` is picked up by creating it. The helpers the tests include, `floatcompare.jl` (`close_(a, b; atol)`, a float comparison with an explicit per-call absolute tolerance) and `geometry.jl` (synthetic point-cloud geometry for the SASA tests), are in [`../utils/`](../utils/README.md). Test data is not here: structures, form-factor oracle values and the sequence corpus are in [`../fixtures/`](../fixtures/README.md).
Absolute tolerances in tests are `DEFAULT_ATOL` or `k * DEFAULT_ATOL`.

```bash
julia --project=test test/run/unittests.jl
julia --project=test test/unit_tests/units/test_atomicradii.jl
```

## `units/`

| file | covers |
|---|---|
| `test_cache.jl` | `Cache`: `Lazy`/`force` and `KeyedCache` |
| `test_timing.jl` | `Timing`: `StageLog`, `timed!`, `tick`/`tock!` |
| `test_atomicradii.jl` | `AtomicRadii`: ion-string parsing and the radius lookup |
| `test_molecules.jl` | `MolecularStructure.Mols`: construction, centring, radii, excluded-volume pieces |
| `test_structuresource.jl` | `MolecularStructure.StructureSource`: local paths, PDB IDs, URLs (uses `fixtures/molecules/`) |
| `test_propka.jl`, `test_pdb2pqr.jl` | the propka3 and pdb2pqr subprocess wrappers (need both tools installed) |
| `test_protonation.jl` | the Henderson-Hasselbalch protonation helpers |
| `test_pipeline.jl` | the structure-loading primitives composed end to end (resolve, pKa, hydrogens, load) |
| `test_shannon.jl` | `Utils.Shannon`: the exact diameter, the Shannon binning and its band limit, the interpolation back to the measured grid, the residual statistics, and `seed_model` → `run_model` → `write_report` end to end on crambin |
| `test_gcpause.jl` | `GCPause`: the collector off inside a pause, nesting, restoration on exceptions, the byte-budget checkpoint |
| `test_formfactor.jl` | `FormFactor` against the xraydb oracle values in `fixtures/form-factors/` |
| `test_pmv.jl` | `PartialMolarVolumes`: bulk water, protein, non-biological solutes, memoization per `(sequence, pH, σ_pH)` |
| `test_plasticmap.jl` | `PlasticSequence`: the low-discrepancy point sets |
| `test_sasa.jl` | `SASA`: accessible surface, the shell classes, the sphere-occlusion tests |
| `test_sphfuncs.jl`, `test_partialwave.jl`, `test_scatterers.jl`, `test_forwardcache.jl` | the scattering stack from spherical functions up to the `ForwardCache` |
| `test_dns.jl` | `Inference.DensityOfSolvent`: the buffer electron density and its prior, including DNA/RNA and mixed buffers |
| `test_deltarho.jl`, `test_paramtransform.jl` | the δρ priors and the ξ ↔ θ parameter transform |
| `test_wls.jl`, `test_profiledcorrs.jl` | closed-form scale/background and the profiled c1 correction |
| `test_sampler.jl` | `Inference.Sampler` and the MAP-whitened NUTS pipeline, end to end |
| `test_seed_diagnostics.jl` | `test/utils/seed_diagnostics.jl` on a small toy seed, so the sampler diagnostics cannot rot unnoticed |
| `test_allocations.jl` | allocation guards for the fitting hot path (AllocCheck) |
| `test_integration.jl` | the whole pipeline from structure to posterior on a small protein |
| `test_quality.jl` | package hygiene (Aqua, ExplicitImports) and type stability (JET, `@inferred`); runs last |
