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

using ...MolecularStructure: Residues, Molecule, elms, coords_cartesian, n_atoms
using ..SASA: SASA
using ...Helpers.Constants: ELEMENTARY_CHARGE, VACUUM_PERMITTIVITY, BOLTZMANN, BOND_CUTOFF,
                            AVOGADRO, ANGSTROM, MV_PER_CM, PHOSPHATE_NET_CHARGE
using ...Interfaces: Interfaces
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
- `ionic_strength_M::Float64 = 0.15`: physiological monovalent salt concentration, mol/L
- `eps_r::Float64 = 80.0`: water's static relative permittivity.
- `T::Float64 = 300.0`: temperature, K.
"""
function debye_length(; 
    ionic_strength_M::Float64 = 0.15, 
    eps_r::Float64 = 80.0, 
    T::Float64 = 300.0
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
    _protein_charge_sites(mol, residues) -> Vector{Tuple{Int,Float64}}

Every ionizable protein atom in `mol`, as `(atom_index, charge_e)` pairs.

Throws `ArgumentError` if `residues`' vectors don't match `mol`'s atom
count. A molecule with no ionizable residues (or `residues` covering none
of `mol`'s charged atoms) returns an empty vector.
"""
function _protein_charge_sites(mol::Molecule, residues::Residues)::Vector{Tuple{Int,Float64}}
    n = n_atoms(mol)
    (length(residues.resname) == n && length(residues.atomname) == n) ||
        throw(ArgumentError("residues' resname/atomname must each have length $n (mol's atom count)"))

    sites = Tuple{Int,Float64}[]
    @inbounds for i in 1:n
        q = Interfaces.residue_charge(residues.resname[i], residues.atomname[i])
        q === nothing && continue
        push!(sites, (i, q))
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
over every `(atom_index, charge_e)` pair in `sites` within
`cutoff_debye_lengths` Debye lengths, then the mean/std across `sel`.

# Arguments
- `mol`: molecule the beads belong to.
- `pts::Matrix{Float64}`, `(3, M)`: bead positions, `mol`'s centered frame.
- `sel::Vector{Int}`: column indices into `pts` to aggregate over.
- `sites::Vector{Tuple{Int,Float64}}`: `(atom_index, charge_e)` pairs to sum
    the screened field over.
"""
function _aggregate(
    mol::Molecule, pts::Matrix{Float64}, sel::Vector{Int}, sites::Vector{Tuple{Int,Float64}};
    ionic_strength_M::Float64     = 0.15,
    eps_r::Float64                = 80.0,
    T::Float64                    = 300.0,
    cutoff_debye_lengths::Float64 = 5.0,
)::Tuple{Float64,Float64}
    isempty(sel) && return (0.0, 0.0)
    isempty(sites) && return (0.0, 0.0)

    crds  = coords_cartesian(mol)
    κinv  = debye_length(; ionic_strength_M = ionic_strength_M, eps_r = eps_r, T = T)
    cutoff = cutoff_debye_lengths * κinv

    vals = Vector{Float64}(undef, length(sel))
    @inbounds for (k, i) in enumerate(sel)
        bx, by, bz = pts[1, i], pts[2, i], pts[3, i]
        total = 0.0
        for (o, q) in sites
            r = sqrt((bx - crds[1, o])^2 + (by - crds[2, o])^2 + (bz - crds[3, o])^2)
            (r == 0.0 || r > cutoff) && continue
            total += _screened_field(q, r, κinv, eps_r)
        end
        vals[k] = total
    end

    μ = sum(vals) / length(vals)
    σ = length(vals) > 1 ? _sample_std(vals, μ) : 0.0
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
- `probe::Float64 = 1.4`: solvent probe radius, forwarded to `SASA.shell_points`.
- `n_target::Union{Nothing,Int} = nothing`: shell point budget, forwarded to
    `SASA.shell_points`.
- `ionic_strength_M::Float64 = 0.15`, `eps_r::Float64 = 80.0`,
    `T::Float64 = 300.0`: forwarded to [`debye_length`](@ref).
- `cutoff_debye_lengths::Float64 = 5.0`: charge sites beyond this many Debye
    lengths from a bead are dropped (`exp(-5) ≈ 0.007`, already negligible
    next to the screened `1/r` prefactor).
"""
function nucleic_acid_cavity_electrostatics(
    mol::Molecule;
    probe::Float64                 = 1.4,
    n_target::Union{Nothing,Int}   = nothing,
    ionic_strength_M::Float64      = 0.15,
    eps_r::Float64                 = 80.0,
    T::Float64                     = 300.0,
    cutoff_debye_lengths::Float64  = 5.0,
)::Tuple{Float64,Float64}
    pts, _, class = SASA.shell_points(mol; probe = probe, n_target = n_target)
    sel = findall(==(SASA.CAVITY), class)
    sites = _phosphate_charge_sites(mol)
    return _aggregate(
        mol, pts, sel, sites;
        ionic_strength_M = ionic_strength_M, eps_r = eps_r, T = T,
        cutoff_debye_lengths = cutoff_debye_lengths,
    )
end

"""
    protein_cavity_electrostatics(
    mol, 
    residues; 
    probe, 
    n_target, 
    ionic_strength_M, 
    eps_r, 
    T, 
    cutoff_debye_lengths
) -> (μ_χ, σ_χ)

Screened-electrostatic cavity-water contrast signal for `DeltaRho.δρ_prior`'s
`(μ_χ, σ_χ)` keywords, from `mol`'s ionizable protein side chains (see
[`_protein_charge_sites`](@ref) and `Interfaces.ResidueNetCharge`). Runs
`SASA.shell_points`, then delegates every `CAVITY`-class bead to
[`_aggregate`](@ref).

# Arguments
- `mol`: molecule to score; only its cavity-facing surface and ionizable
    side-chain positions are used.
- `residues::Residues`: per-atom resname/atomname identity for `mol`.

# Keywords
Same as [`nucleic_acid_cavity_electrostatics`](@ref).
"""
function protein_cavity_electrostatics(
    mol::Molecule,
    residues::Residues;
    probe::Float64                 = 1.4,
    n_target::Union{Nothing,Int}   = nothing,
    ionic_strength_M::Float64      = 0.15,
    eps_r::Float64                 = 80.0,
    T::Float64                     = 300.0,
    cutoff_debye_lengths::Float64  = 5.0,
)::Tuple{Float64,Float64}
    pts, _, class = SASA.shell_points(mol; probe = probe, n_target = n_target)
    sel = findall(==(SASA.CAVITY), class)
    sites = _protein_charge_sites(mol, residues)
    return _aggregate(
        mol, pts, sel, sites;
        ionic_strength_M = ionic_strength_M, eps_r = eps_r, T = T,
        cutoff_debye_lengths = cutoff_debye_lengths,
    )
end

end # module Electrostatics
