# Prior Distribution Modules

Files define prior distributions over fit parameters, allowing HMC to sample over a distribution of possible params instead of fixing to one.

## DeltaRho.jl

CRYSOL's `dro` parameters are contrast densities of the hydration shell's border layer, split by bead geometry: `dro1` convex beads, `dro2` concave beads, `dro3` cavity beads. CRYSOL's own default is `dr1 = dr2 = 1.0`, `dr3 = 0`.

`dro_prior(μ_χ=0; σ_χ=0.0)` returns `(dro1, dro2, dro3)`:

- `dro1`: `LogNormal(0, σ_ln)` with median 1 (matching CRYSOL's default exactly) and mean 1.15,  since convex beads run ~15% denser on the surface. Source: Merzel & Smith, PNAS 99(8):5378-5383 (2002), doi:10.1073/pnas.082335099, an MD explanation of the SAS/SANS measurement of Svergun et al.,  PNAS 95:2267-2272 (1998). `σ_ln` solves

  ```
  mean = exp(σ_ln²/2) = 1.15  =>  σ_ln = √(2·ln(1.15))
  ```
- `dro2`: `Normal(1, 0.15)`, concave beads, mostly positive but can go either way.
- `dro3`: `Normal(μ_χ, σ_χ)`, cavity-water contrast. Defaults to a point mass at 0, matching standard CRYSOL's fixed `dr3 = 0`. `μ_χ`/`σ_χ` can be set by hand or fed from `Molecule.Electrostatics.nucleic_acid_cavity_electrostatics`, a screened-field (Debye-Huckel) signal from nucleic-acid phosphate charges.
- \`dro4` (condensed-cation layer for nucleotides, Manning theory) is not implemented yet.

## DensityOfSolvent.jl

`dns_prior(pH, σ_pH, solutes; t=25.0)` returns a `LogNormal` prior for the bulk solution electron
density `ρₑ` (e·Å⁻³), moment-matched to the `(μ, σ)` computed by `_ρₑ`. `LogNormal` is used since
`ρₑ` has support only on `(0, ∞)`; at the CV this model produces it agrees with `Normal` in the bulk.

`_ρₑ` is linear in solute concentration:

```
ρₑ = ρ_w(T) + Σ_j C_j · (N_A·Z_j/1e27 − ρ_w(T)·ϕ°_j/1e3)
```

where `ϕ°_j` is solute `j`'s partial molar volume at infinite dilution (cm³/mol). Uncertainty is
propagated to first order assuming independence:

```
σ² = (1 − Σ_j C_j·ϕ°_j/1e3)² · σ_w²
    + Σ_j k_j² · σ_C_j²
    + Σ_j (C_j·ρ_w/1e3)² · σ_ϕ°_j²
```

with `k_j = N_A·Z_j/1e27 − ρ_w·ϕ°_j/1e3`. Given `μ = ρₑ`, `σ = √σ²`, the `LogNormal` parameters are

```
σ_ln = √(ln(1 + σ²/μ²))
μ_ln = ln(μ) − σ_ln²/2
```

Solutes are `Protein`, `NonBiological`, `DNA`, `RNA`, each carrying `molarity`,
`molarity_uncertainty`, and an `arg` (sequence or name) resolved through `Interfaces.ϕ°`.
