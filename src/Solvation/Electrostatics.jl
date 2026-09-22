# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Screened electrostatic field at cavity beads, aggregated over
`SASA.CAVITY`-class hydration beads. Physics follows Laage, Elsaesser &
Hynes, "Water Dynamics in the Hydration Shells of Biomolecules" (Chem. Rev.
2017, 117, 10694-10725), section 5.1: the linearized Poisson-Boltzmann
(Debye-Huckel) screened potential/field of a point charge in an ionic
solution.

"""
module Electrostatics

using ...MolecularStructure: Residues, Molecule, Ionization, elms, coords_cartesian
using ..SASA: SASA
using ...BayesolUtils.Constants: ELEMENTARY_CHARGE, VACUUM_PERMITTIVITY, BOLTZMANN, BOND_CUTOFF,
                            AVOGADRO, ANGSTROM, MV_PER_CM, PHOSPHATE_NET_CHARGE,
                            IONIC_STRENGTH_M, WATER_EPS_R, DEBYE_TEMPERATURE_K,
                            CUTOFF_DEBYE_LENGTHS, PROBE_RADIUS, SHELL_N_TARGET
using JSON3: JSON3
using NearestNeighbors: KDTree, inrange

# ---------------------------------------------------------------------------
#                          Debye screening length
# ---------------------------------------------------------------------------

"""
    debye_length(; ionic_strength_M, eps_r, T) -> Float64

Debye screening length `1/κ` (Å) of a 1:1 electrolyte, from the linearized
Poisson-Boltzmann equation's `κ² = 2 N_A e² I / (ε₀ ε k_B T)` (Laage,
Elsaesser & Hynes 2017, section 5.1, eq. 2's screening term). At the default
keywords this evaluates to `≈ 8 Å`, matching the paper's observation that
interfacial fields are confined to roughly the first two hydration layers.

# Keywords
- `ionic_strength_M::Float64 = IONIC_STRENGTH_M`: physiological monovalent salt concentration, mol/L
- `eps_r::Float64 = WATER_EPS_R`: water's static relative permittivity.
- `T::Float64 = DEBYE_TEMPERATURE_K`: temperature, K.
"""
function debye_length(;
    ionic_strength_M::Float64 = IONIC_STRENGTH_M,
    eps_r::Float64 = WATER_EPS_R,
    T::Float64 = DEBYE_TEMPERATURE_K
)::Float64
    ionic_strength_M > 0.0 || throw(DomainError(ionic_strength_M, "ionic_strength_M must be > 0"))
    eps_r > 0.0 || throw(DomainError(eps_r, "eps_r must be > 0"))
    T > 0.0 || throw(DomainError(T, "T must be > 0"))
    c_si = ionic_strength_M * 1000.0   # mol/L -> mol/m^3
    κ2 = (2 * c_si * AVOGADRO * ELEMENTARY_CHARGE^2) / (VACUUM_PERMITTIVITY * eps_r * BOLTZMANN * T)
    return 1.0 / sqrt(κ2) / ANGSTROM
end

# ---------------------------------------------------------------------------
#                     phosphate charge-site identification
# ---------------------------------------------------------------------------

"""
    _bonded(tree, crds, i, exclude) -> Vector{Int}

Indices of atoms within [`BOND_CUTOFF`](@ref) of atom `i`, excluding `i`
itself and `exclude`.
"""
function _bonded(tree::KDTree, crds::Matrix{Float64}, i::Int, exclude::Int)::Vector{Int}
    nb = inrange(tree, view(crds, :, i), BOND_CUTOFF)
    return [j for j in nb if j != i && j != exclude]
end

"""
    _phosphate_charge_sites(mol) -> Vector{Tuple{Int,Float64}}

Every nucleic-acid phosphate group in `mol`, as `(atom_index, charge_e)`
pairs. A phosphate group is found by element symbol  (a `"p"` atom and
its bonded `"o"` neighbours), since `Molecule` carries no residue identity.

Within each group, an oxygen bonded to nothing but the phosphorus is
non-bridging (the charge-bearing `PO₂⁻`-type oxygens); one also bonded to a
further heavy atom (the sugar carbon) is bridging and carries no charge.

A molecule with no phosphorus atoms returns an empty vector.
"""
function _phosphate_charge_sites(mol::Molecule)::Vector{Tuple{Int,Float64}}
    els  = elms(mol)
    crds = coords_cartesian(mol)
    n    = length(els)
    n == 0 && return Tuple{Int,Float64}[]
    tree = KDTree(crds)

    sites = Tuple{Int,Float64}[]
    @inbounds for p in 1:n
        els[p] == "p" || continue
        o_neighbors = [j for j in _bonded(tree, crds, p, 0) if els[j] == "o"]
        isempty(o_neighbors) && continue

        nonbridging = [o for o in o_neighbors if isempty(_bonded(tree, crds, o, p))]
        targets = isempty(nonbridging) ? o_neighbors : nonbridging

        q_each = PHOSPHATE_NET_CHARGE / length(targets)
        for o in targets
            push!(sites, (o, q_each))
        end
    end
    return sites
end

# ---------------------------------------------------------------------------
#                    protein charge-site identification
# ---------------------------------------------------------------------------


"""
    _protein_charge_sites(residues, ionization) -> Vector{Tuple{Int,Float64,Float64}}

Every atom [`Ionization`](@ref) actually assigned a nonzero charge or
charge-uncertainty to, as `(atom_index, charge, σ_charge)` triples.

Throws `ArgumentError` if `residues.resname` and `ionization.charge` don't
have matching length. A molecule with no ionizable residues (or an
`ionization` that assigned zero to every atom) returns an empty vector.
"""
function _protein_charge_sites(residues::Residues, ionization::Ionization)::Vector{Tuple{Int,Float64,Float64}}
    n = length(residues.resname)
    length(ionization.charge) == n ||
        throw(ArgumentError("ionization.charge must have length $n (residues' atom count)"))

    sites = Tuple{Int,Float64,Float64}[]
    @inbounds for i in 1:n
        q, σq = ionization.charge[i], ionization.σ_charge[i]
        (q != 0.0 || σq != 0.0) || continue
        push!(sites, (i, q, σq))
    end
    return sites
end

# ---------------------------------------------------------------------------
#                            screened field
# ---------------------------------------------------------------------------

"""
    _screened_field(q_e, r_angstrom, kappa_inv_angstrom, eps_r) -> Float64

Magnitude of the linearized-PB (Debye-Huckel) screened electric field, in
MV/cm, at distance `r_angstrom` (> 0) from a point charge `q_e` (elementary-
charge units), screened over `kappa_inv_angstrom`:

`E(r) = |q|/(4πε₀ε) · exp(-κr) · (1/r² + κ/r)`

The sign of `q_e` is discarded: per Merzel & Smith 2002, both cationic and
anionic surface groups correlate with denser hydration, so only the field
magnitude (not its direction) feeds the aggregate signal.
"""
function _screened_field(
    q_e::Float64, 
    r_angstrom::Float64, 
    kappa_inv_angstrom::Float64, 
    eps_r::Float64
)::Float64
    r = r_angstrom * ANGSTROM
    κ = 1.0 / (kappa_inv_angstrom * ANGSTROM)
    q = abs(q_e) * ELEMENTARY_CHARGE
    e_si = q / (4π * VACUUM_PERMITTIVITY * eps_r) * exp(-κ * r) * (1.0 / r^2 + κ / r)
    return e_si / MV_PER_CM
end

# ---------------------------------------------------------------------------
#                             aggregation
# ---------------------------------------------------------------------------

"""
    _sample_std(v, μ) -> Float64

Sample standard deviation of `v` about a precomputed mean `μ`; `v` must have
at least 2 elements.
"""
function _sample_std(v::Vector{Float64}, μ::Float64)::Float64
    s = 0.0
    @inbounds for x in v
        s += (x - μ)^2
    end
    return sqrt(s / (length(v) - 1))
end

"""
    _aggregate(mol, pts, sel, sites; ionic_strength_M, eps_r, T, cutoff_debye_lengths) -> (μ_χ, σ_χ)

Screened-field signal at each selected bead: the sum of [`_screened_field`](@ref)
over every `(atom_index, charge_e, σ_charge_e)` triple in `sites` within
`cutoff_debye_lengths` Debye lengths, then the mean/std across `sel`.

`σ_χ` combines two genuinely different sources of spread, in quadrature
(`σ_χ = sqrt(σ_χ,spatial² + σ_χ,pH²)`):

- `σ_χ,spatial`: the existing purely-geometric spread of the deterministic
  per-bead signal across `sel` (unchanged from before `Ionization` was
  wired in) — how much the *signal itself* varies bead-to-bead.
- `σ_χ,pH`: first-order (delta-method) propagation of each site's
  `σ_charge` (itself derived from a shared solution `σ_pH`, see
  [`Ionization`](@ref)) into the field. `_screened_field` is exactly linear
  in `|q|` (`field = |q|·C(r)` for a `q`-independent `C(r)`), so a single
  site's field-uncertainty contribution is `σ_field,i = (field_i/|q_i|)·σ_charge_i`
  (special-cased to `0` when `q_i == 0`, since that site then contributes no
  field and no field-uncertainty regardless).

  **Documented approximation, not an exact treatment**: every site's
  `σ_charge` ultimately derives from the *same* shared `σ_pH`, so the
  sites' charge fluctuations are correlated, not independent — the
  mathematically correct combination would need *signed*
  `∂charge_i/∂pH` sensitivities summed linearly before taking a magnitude,
  which `Ionization.σ_charge` (a magnitude-only quantity) doesn't carry.
  Absent that sign information, each bead's per-site field-uncertainty
  contributions are combined via quadrature too
  (`σ_χ,pH,bead = sqrt(Σᵢ σ_field,i²)`), the same independence assumption
  applied consistently at every level of this calculation rather than
  mixing rigor levels arbitrarily. Per-bead `σ_χ,pH,bead` values are then
  aggregated across `sel` the same way the spatial term already is (mean
  of `vals`, `_sample_std` of `pH_vals` about that mean).

  When every site's `σ_charge == 0` (e.g. `σ_pH == 0`), every
  `σ_field,i == 0`, so `σ_χ,pH` is exactly `0.0`, recovering the
  purely-spatial `σ_χ` as a special case.

# Arguments
- `mol`: molecule the beads belong to.
- `pts::Matrix{Float64}`, `(3, M)`: bead positions, `mol`'s centered frame.
- `sel::Vector{Int}`: column indices into `pts` to aggregate over.
- `sites::Vector{Tuple{Int,Float64,Float64}}`: `(atom_index, charge_e,
    σ_charge_e)` triples to sum the screened field (and its pH-driven
    uncertainty) over.
"""
function _aggregate(
    mol::Molecule, pts::Matrix{Float64}, sel::Vector{Int}, sites::Vector{Tuple{Int,Float64,Float64}};
    ionic_strength_M::Float64     = IONIC_STRENGTH_M,
    eps_r::Float64                = WATER_EPS_R,
    T::Float64                    = DEBYE_TEMPERATURE_K,
    cutoff_debye_lengths::Float64 = CUTOFF_DEBYE_LENGTHS,
)::Tuple{Float64,Float64}
    isempty(sel) && return (0.0, 0.0)
    isempty(sites) && return (0.0, 0.0)

    crds  = coords_cartesian(mol)
    κinv  = debye_length(; ionic_strength_M = ionic_strength_M, eps_r = eps_r, T = T)
    cutoff = cutoff_debye_lengths * κinv

    vals    = Vector{Float64}(undef, length(sel))
    pH_vals = Vector{Float64}(undef, length(sel))
    @inbounds for (k, i) in enumerate(sel)
        bx, by, bz = pts[1, i], pts[2, i], pts[3, i]
        total    = 0.0
        total_pH_sq = 0.0
        for (o, q, σq) in sites
            r = sqrt((bx - crds[1, o])^2 + (by - crds[2, o])^2 + (bz - crds[3, o])^2)
            (r == 0.0 || r > cutoff) && continue
            field = _screened_field(q, r, κinv, eps_r)
            total += field
            σ_field = q == 0.0 ? 0.0 : (field / abs(q)) * σq
            total_pH_sq += σ_field^2
        end
        vals[k]    = total
        pH_vals[k] = sqrt(total_pH_sq)
    end

    μ = sum(vals) / length(vals)
    σ_spatial = length(vals) > 1 ? _sample_std(vals, μ) : 0.0

    # σ_χ,pH: mean across beads of each bead's own pH-driven field-uncertainty
    # (the same "fold an array of per-bead values into one scalar via their
    # mean" reduction _aggregate already uses to turn `vals` into `μ`) --
    # not a second std-across-beads, since `pH_vals` are themselves already
    # per-bead uncertainties, not per-bead point estimates.
    σ_χ_pH = sum(pH_vals) / length(pH_vals)

    σ = sqrt(σ_spatial^2 + σ_χ_pH^2)
    return (μ, σ)
end

# ---------------------------------------------------------------------------
#                            public entry point
# ---------------------------------------------------------------------------

"""
    nucleic_acid_cavity_electrostatics(
        mol; 
        probe, 
        n_target, 
        ionic_strength_M, 
        eps_r, 
        T, 
        cutoff_debye_lengths
    ) -> (μ_χ, σ_χ)

Screened-electrostatic cavity-water contrast signal for `DeltaRho.δρ_prior`'s
`(μ_χ, σ_χ)` keywords, from `mol`'s nucleic-acid phosphate groups (see
[`_phosphate_charge_sites`](@ref)). Runs `SASA.shell_points`, then delegates
every `CAVITY`-class bead to [`_aggregate`](@ref).

Protein ionizable side chains carry no charge here.

# Arguments
- `mol`: molecule to score; only its cavity-facing surface and phosphate
    positions are used.

# Keywords
- `probe::Float64 = PROBE_RADIUS`: solvent probe radius, forwarded to `SASA.shell_points`.
- `n_target::Union{Nothing,Int} = SHELL_N_TARGET`: shell point budget, forwarded to
    `SASA.shell_points`.
- `ionic_strength_M::Float64 = IONIC_STRENGTH_M`, `eps_r::Float64 = WATER_EPS_R`,
    `T::Float64 = DEBYE_TEMPERATURE_K`: forwarded to [`debye_length`](@ref).
- `cutoff_debye_lengths::Float64 = CUTOFF_DEBYE_LENGTHS`: charge sites beyond this many Debye
    lengths from a bead are dropped (`exp(-5) ≈ 0.007`, already negligible
    next to the screened `1/r` prefactor).
"""
function nucleic_acid_cavity_electrostatics(
    mol::Molecule;
    probe::Float64                 = PROBE_RADIUS,
    n_target::Union{Nothing,Int}   = SHELL_N_TARGET,
    ionic_strength_M::Float64      = IONIC_STRENGTH_M,
    eps_r::Float64                 = WATER_EPS_R,
    T::Float64                     = DEBYE_TEMPERATURE_K,
    cutoff_debye_lengths::Float64  = CUTOFF_DEBYE_LENGTHS,
)::Tuple{Float64,Float64}
    pts, _, class = SASA.shell_points(mol; probe = probe, n_target = n_target)
    sel = findall(==(SASA.CAVITY), class)
    # Phosphate charges carry no pH-driven uncertainty (fixed stoichiometry,
    # not `Ionization`-derived); pad with σ_charge = 0.0 to match _aggregate's
    # shared (atom_index, charge, σ_charge) triple contract -- this leaves
    # the deterministic signal and its (purely spatial) σ_χ unchanged, since
    # every σ_field this contributes is 0.
    sites = [(o, q, 0.0) for (o, q) in _phosphate_charge_sites(mol)]
    return _aggregate(
        mol, pts, sel, sites;
        ionic_strength_M = ionic_strength_M, eps_r = eps_r, T = T,
        cutoff_debye_lengths = cutoff_debye_lengths,
    )
end

"""
    protein_cavity_electrostatics(
    mol,
    residues,
    ionization;
    probe,
    n_target,
    ionic_strength_M,
    eps_r,
    T,
    cutoff_debye_lengths
) -> (μ_χ, σ_χ)

Screened-electrostatic cavity-water contrast signal for `DeltaRho.δρ_prior`'s
`(μ_χ, σ_χ)` keywords, from `mol`'s ionizable protein side chains (see
[`_protein_charge_sites`](@ref) and [`Ionization`](@ref)). Runs
`SASA.shell_points`, then delegates every `CAVITY`-class bead to
[`_aggregate`](@ref), which also folds `ionization`'s per-atom `σ_charge`
(pH-driven) into `σ_χ` alongside the purely-spatial spread across beads --
see [`_aggregate`](@ref)'s docstring for the exact combination.

# Arguments
- `mol`: molecule to score; only its cavity-facing surface and ionizable
    side-chain positions are used.
- `residues::Residues`: per-atom residue identity for `mol` (only its
    `resname` field's length is consulted here; matched against `ionization`).
- `ionization::Ionization`: per-atom charge/σ_charge for `residues`, from
    real per-residue-instance pKa's via Henderson-Hasselbalch (see
    [`Ionization`](@ref)).

# Keywords
Same as [`nucleic_acid_cavity_electrostatics`](@ref).
"""
function protein_cavity_electrostatics(
    mol::Molecule,
    residues::Residues,
    ionization::Ionization;
    probe::Float64                 = PROBE_RADIUS,
    n_target::Union{Nothing,Int}   = SHELL_N_TARGET,
    ionic_strength_M::Float64      = IONIC_STRENGTH_M,
    eps_r::Float64                 = WATER_EPS_R,
    T::Float64                     = DEBYE_TEMPERATURE_K,
    cutoff_debye_lengths::Float64  = CUTOFF_DEBYE_LENGTHS,
)::Tuple{Float64,Float64}
    pts, _, class = SASA.shell_points(mol; probe = probe, n_target = n_target)
    sel = findall(==(SASA.CAVITY), class)
    sites = _protein_charge_sites(residues, ionization)
    return _aggregate(
        mol, pts, sel, sites;
        ionic_strength_M = ionic_strength_M, eps_r = eps_r, T = T,
        cutoff_debye_lengths = cutoff_debye_lengths,
    )
end

end # module Electrostatics
