# Solvation

Models the molecule's solvent-accessible surface and the electrostatics of that surface, as inputs to the CRYSOL-style hydration-shell contrast terms (δρ1/δρ2/δρ3, see src/Fitting/Priors/DeltaRho.jl) used by the forward scattering model. 

- **SASA.jl**: solvent-accessible surface area, both as per-atom areas (Shrake–Rupley point sampling) and as a classified point cloud (convex / concave / cavity) standing in for CRYSOL's three hydration-shell bead populations.
- **Electrostatics.jl**: the screened (Debye–Hückel) electric field at SASA's CAVITY-class beads, aggregated from nucleic-acid phosphate charges or protein ionizable-side-chain charges, to give DeltaRho.`δρ_prior` a data-driven (`μ_χ`, `σ_χ`) for the cavity-water contrast term δρ3.

Ionization state (pKa via PROPKA, Henderson–Hasselbalch) and partial molar volumes live in src/MolecularStructure/ and
src/PartialMolarVolumes/ respectively.

## SASA - solvent-accessible surface area

### Per-atom area: sasa

Implements Shrake–Rupley: each atom's *expanded* sphere (radius + probe, probe = solvent probe radius, default 1.4 Å for water) is sampled at a set of directions, and a direction is *occluded* if it lands inside any other atom's expanded sphere. The exposed fraction times the sphere's full area 4π(r+probe)² is that atom's accessible area.

Sample points come from the plastic-sequence low-discrepancy set (Geometry.PlasticSequence, see src/Geometry/README.md) rather than i.i.d. random points or a fixed spherical-cap design, for even coverage at any point count.

1. **Exact, no sampling** (Geometry.Metrics.classify, see src/Geometry/README.md): comparing centre-to-centre distance d against ρᵢ = rᵢ+probe, ρⱼ = rⱼ+probe alone decides
   `ALL_EXPOSED` (no neighbour reaches the surface → area is exactly 4π(r+probe)²) or `ALL_BURIED` (one neighbour engulfs the atom whole → area is exactly 0.0). This shortcut, along with the point/ray occlusion tests (Metrics.blocked), is a general sphere-geometry primitive independent of SASA — not specific to surface-area sampling.
2. **Witness pass** (AMBIGUOUS case, `n_occ` points): if any of the first `n_occ` sampled directions is unoccluded, sampling continues to the full `n_exp` pass. If none is, the worst-case remaining exposed fraction is bounded by the rule of three (3/`n_occ`); if the worst-case area that  could still be hiding is under `area_tol`, the atom is treated as buried without paying for the full pass.
3. **Full pass** (`n_exp` points): exposed fraction = (unoccluded points) / `n_exp`, giving area = 4π(r+probe)² · (count/`n_exp`).

Non-existence of a witness in the coarse pass is *not* proof of burial, since a finite sample can prove exposure but never burial. This is why step 2 uses a worst-case bound (`area_tol`) rather than concluding an atom is burried.

```julia
using BAYSOL.MolecularStructure: create
using BAYSOL.Solvation.SASA: sasa

mol = create("my-mol", elements, coords_cartesian)
area, exposed = sasa(mol; probe = 1.4, n_occ = 512, n_exp = 4096, area_tol = 2.0)
# area:    (n,) Å² per atom, indexed like coords_cartesian(mol)'s columns
# exposed: (n,) Bool, true where the atom has ≥ 1 accessible sample point
```

Keywords:

- probe::Float64 = 1.4: solvent probe radius, Å; must be ≥ 0.
- `n_occ`::Int = 512: points for the witness pass; must be > 0 and ≤ `n_exp`.
- `n_exp`::Int = 4096: points for the full exposed-fraction pass; measured relative error against the analytic two-sphere-cap solution is ~0.065% at 4096 points.
- `area_tol`::Float64 = 2.0: Å² worst-case-exposed-area threshold below which an unwitnessed atom is called buried without the full pass.

### Point cloud: `shell_points`

The accessible surface as a (3, M) point cloud plus per-point area and a BeadClass (CONVEX / CONCAVE / CAVITY), matching CRYSOL 3's three hydration border-layer populations (each with its own fitted contrast).

Every atom is sampled at `_SHELL_SAMPLE` = 256 directions, occlusion-filtered the same way sasa does it, then thinned to a target point budget proportional to each atom's accepted-point share (`_prefix_thin`, cumulative-floor/Bresenham allocation). Points thinned this way all carry an equal share of the total area, so sum(areas) still matches sum(sasa(mol)[1]).

Classification (`_bead_class`) casts rays from each surviving bead: if the outward normal escapes the molecule within `_BEAD_RAY_RANGE` = 12.0 Å the bead is at least CONVEX; otherwise rays are cast over the bead's outward hemisphere and classified by escaping fraction against `_BEAD_CONVEX_ESCAPE` = 0.5: ≥ 0.5 escaping is CONVEX, > 0 but < 0.5 is CONCAVE, and 0 (every ray blocked) is CAVITY. Cavity detection is exact for voids up to `_BEAD_RAY_RANGE` across; a larger void degrades to open surface.

```julia
using BAYSOL.Solvation.SASA: shell_points, CONVEX, CONCAVE, CAVITY

pts, areas, class = shell_points(mol; probe = 1.4, n_target = nothing)
# pts:   (3, M) accessible points, mol's centred cartesian frame
# areas: (M,) Å² per point, equal across all M
# class: (M,) BeadClass per point
```

Keywords:

- probe::Float64 = 1.4: solvent probe radius, Å; must be ≥ 0.
- `n_target`::Union{Nothing,Int} = nothing: total points to keep, > 0 if given. nothing derives the budget from accessible area via `SHELL_AREA_PER_POINT` = 4.0 Å²/point (calibrated against CRYSOL's default --fb 17 Fibonacci grid, ~4 Å²/point on a typical globular protein), so spacing stays fixed as the molecule grows rather than the point count staying flat. Floored at `SHELL_MIN_POINTS` = 55.

### Quasi-random sphere sampling

The point-sampling primitive itself is no longer part of Solvation: it now
lives in the domain-agnostic Geometry.PlasticSequence module (see
src/Geometry/README.md), built on the plastic (R_d) family of
low-discrepancy sequences (Roberts, M. (2018). The Unreasonable Effectiveness of
Quasirandom Sequences.), since it knows nothing about atoms, molecules,
or surfaces. SASA calls its `plastic_points`(n; dim = 3) (default
shape = :surface, points lifted onto the unit sphere via Lambert's
cylindrical equal-area projection, uniform in area rather than clustered at
the poles) to get its sample directions; the raw 2-D layout (dim = 2), the
sphere-**volume** layout (shape = :volume, fills the ball rather than
sampling its surface), and the generalized `plastic_ratio`(d) are
general-purpose and unused here.

```julia
using BAYSOL.Geometry.PlasticSequence: plastic_points, PLASTIC_RATIO_2

pts = plastic_points(256)   # Vector{NTuple{3,Float64}}, unit-sphere points
```

## Electrostatics - screened cavity-water electric field

Computes the linearized Poisson–Boltzmann (Debye–Hückel) screened electrostatic field at SASA's CAVITY-class beads, aggregated over nearby charge sites, following Laage, Elsaesser & Hynes, "Water Dynamics in the Hydration Shells of Biomolecules" (*Chem. Rev.* 2017, 117, 10694–10725), section 5.1.

### Debye screening length: `debye_length`

```
κ² = 2 N_A e² I / (ε₀ ε_r k_B T)
```

for a 1:1 electrolyte of ionic strength I. At default keywords this evaluates to ≈8 Å, matching the source paper's observation that interfacial fields are confined to roughly the first two hydration layers.

```julia
using BAYSOL.Solvation.Electrostatics: debye_length

κinv = debye_length(; ionic_strength_M = 0.15, eps_r = 80.0, T = 300.0)  # ≈ 8 Å
```

Keywords (each must be > 0, else DomainError):

- `ionic_strength_M`::Float64 = `IONIC_STRENGTH_M` (0.15 M, physiological)
- `eps_r`::Float64 = `WATER_EPS_R` (80.0, water's static relative permittivity)
- T::Float64 = `DEBYE_TEMPERATURE_K` (300.0 K)

### Screened field of a point charge

```
E(r) = |q| / (4πε₀ε_r) · exp(-κr) · (1/r² + κ/r)
```

(`_screened_field`, internal). The charge's *sign* is discarded, per Merzel & Smith 2002, both cationic and anionic surface groups correlate with denser hydration, so only field magnitude feeds the aggregate signal.

### Charge-site identification

- **Nucleic-acid phosphates** (`_phosphate_charge_sites`, internal): finds every "p" atom and its bonded "o" neighbours (bond cutoff `BOND_CUTOFF` = 1.75 Å) purely by element symbol, since Molecule carries no residue identity. Non-bridging oxygens (bonded to nothing but the phosphorus) are the charge-bearing PO₂⁻-type sites and split `PHOSPHATE_NET_CHARGE` = -0.24 e evenly between them; if every oxygen is bridging, the charge is split across all of them as a fallback.
- **Protein ionizable side chains** (`_protein_charge_sites`, internal): reads MolecularStructure.Ionization's per-atom (charge, `σ_charge`) (already resolved from PROPKA pKa records via Henderson–Hasselbalch) and keeps every atom with a nonzero charge or charge-uncertainty.

### Aggregation over cavity beads: `_aggregate`

For each selected bead, sums `_screened_field` over every charge site within `cutoff_debye_lengths` * `debye_length`() (default `CUTOFF_DEBYE_LENGTHS` = 5.0, exp(-5) ≈ 0.007, already negligible), then takes the mean/std across the selected beads. The returned `σ_χ` combines two sources of spread in quadrature:

```
σ_χ = sqrt(σ_χ,spatial² + σ_χ,pH²)
```

- `σ_χ,spatial`: purely geometric spread of the deterministic per-bead signal across selected beads.
- `σ_χ,pH`: first-order (delta-method) propagation of each site's `σ_charge` (itself derived from a shared solution `σ_pH` via
  Ionization) into the field, exploiting that `_screened_field` is exactly linear in |q|. This is an approximation: every site's `σ_charge` derives from the same shared `σ_pH` (correlated, not independent), but since Ionization.`σ_charge` carries no sign
  information, per-site contributions are combined via quadrature throughout rather than mixing rigor levels. When every site's
  `σ_charge` == 0 (e.g. `σ_pH` == 0), `σ_χ,pH` is exactly 0.0, recovering the purely-spatial case.

### Public entry points

Both run SASA.`shell_points`, select the CAVITY-class beads, and delegate
to `_aggregate`:

```julia
using BAYSOL.Solvation.Electrostatics: nucleic_acid_cavity_electrostatics,
                                          protein_cavity_electrostatics

# Nucleic-acid phosphate groups only; protein side chains carry no charge here.
μ_χ, σ_χ = nucleic_acid_cavity_electrostatics(mol; probe = 1.4)

# Protein ionizable side chains, via MolecularStructure.Ionization.
μ_χ, σ_χ = protein_cavity_electrostatics(mol, residues, ionization; probe = 1.4)
```

Both share the same keywords: probe::Float64 = `PROBE_RADIUS` and `n_target`::Union{Nothing,Int} = `SHELL_N_TARGET` (forwarded to SASA.`shell_points`), plus `ionic_strength_M`, `eps_r`, T, `cutoff_debye_lengths` (forwarded to `debye_length`). A molecule with no CAVITY beads (e.g. a single exposed atom) or no charge sites returns (0.0, 0.0).

Feeds Fitting.Priors.DeltaRho.`δρ_prior`'s cavity-water contrast term δρ3 directly, replacing a manual (`μ_χ`, `σ_χ`) guess with a 
structure-derived one: 

```julia
using BAYSOL.Fitting: δρ_prior

μχ, σχ = protein_cavity_electrostatics(mol, residues, ionization)
δρ1, δρ2, δρ3 = δρ_prior(μ_χ = μχ, σ_χ = σχ)   # δρ3 == Normal(μχ, σχ)
```
