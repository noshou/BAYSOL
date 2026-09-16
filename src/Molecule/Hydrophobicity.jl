# SPDX-License-Identifier: LGPL-2.1-or-later
"""
Rough per-molecule hydrophilicity/hydrophobicity, from element-level atomic
solvation parameters (ASP) aggregated over `SASA.CAVITY`-class hydration
beads. Feeds `Fitting.DeltaRho.dro_prior`'s `(μ_χ, σ_χ)` keywords with a
structure-informed guess instead of a hand-picked one.
"""
module Hydrophobicity

using ..Molecules: Molecules, Molecule
using ..SASA: SASA
using ...Interfaces.AtomicRadii: tryparse_ion
using NearestNeighbors: KDTree, knn

export ASP, cavity_hydrophilicity

"""
Element-level atomic solvation parameters (ASP), cal/(mol·Å²): the
free-energy cost of moving an Å² of that element's surface from water into
the protein interior. Positive = burial-favorable (hydrophobic), negative =
burial-unfavorable (hydrophilic).

Figures as reported by Wesson & Eisenberg (1992, *Protein Sci.* 1:227-235)
for the Eisenberg & McLachlan (1986, *Nature* 319:199-203) transfer scale:
aliphatic C = 19, aromatic C = 7, S = -1, N = -21, O = -66 cal/(mol·Å²).
Reproduced here from that secondary citation, not transcribed from the 1986
table directly -- treat exact magnitudes as approximate pending a
primary-source check. The qualitative ordering (C hydrophobic, S near
neutral, N and especially O hydrophilic) is well established and repeats
across essentially every solvation-parameter scale derived since.

We only have bare element symbols here (an xyz file carries no bonding,
hybridization, or residue identity), so aliphatic and aromatic carbon can't
be told apart; `"c"` is their unweighted average. Elements with no entry
(anything beyond C/N/O/S) score `0.0`, i.e. neutral, in
[`cavity_hydrophilicity`](@ref).
"""
const ASP = Dict{String,Float64}(
    "c" => (19.0 + 7.0) / 2,
    "n" => -21.0,
    "o" => -66.0,
    "s" => -1.0,
)

"""
Sample standard deviation of `ASP`'s own values. Dividing a raw ASP by this
turns cal/(mol·Å²) into a dimensionless index with unit spread across the table.
"""
const _ASP_SCALE = let
    v = collect(values(ASP))
    μ = sum(v) / length(v)
    sqrt(sum((x - μ)^2 for x in v) / (length(v) - 1))
end

"""
    _base_element(s::AbstractString) -> String

Strip any ionic charge suffix from an `elms(mol)` entry (`"fe3+"` -> `"fe"`);
a bare element (`tryparse_ion` returns `nothing`) passes through unchanged.

# Arguments
- `s`: lowercase element/ion string, as returned by `Molecules.elms`.
"""
function _base_element(s::AbstractString)::String
    ion = tryparse_ion(s)
    return ion === nothing ? String(s) : ion.element
end

"""
    _sample_std(v::Vector{Float64}, μ::Float64) -> Float64

Sample standard deviation of `v` about a precomputed mean `μ`; `v` must have
at least 2 elements (the caller handles `length(v) == 1` separately, since a
lone sample carries no variance estimate of its own).
"""
function _sample_std(v::Vector{Float64}, μ::Float64)::Float64
    s = 0.0
    @inbounds for x in v
        s += (x - μ)^2
    end
    return sqrt(s / (length(v) - 1))
end

"""
    _aggregate(mol, pts, sel) -> (μ_χ, σ_χ)

Assign each selected bead the `ASP` value of its nearest real atom
(z-scored by [`_ASP_SCALE`](@ref)), then return the mean/std across `sel`.

Split out from [`cavity_hydrophilicity`](@ref) so it can be exercised
directly against synthetic `pts`/`sel` in tests, without needing
`SASA.shell_points` to actually produce a `CAVITY` bead.

`sel` empty (no cavity beads at all) returns `(0.0, 0.0)` .

`sel` a single bead returns `σ_χ = 0.0` too, collapsing to a point mass at
that one bead's local chemistry: one sample gives a definite `μ_χ` but no
variance estimate of its own, and falling back to `dro_prior`'s own default
spread (rather than inventing one) keeps this consistent with the no-cavity case above.

# Arguments
- `mol`: molecule the beads belong to; only its coordinates/elements are used.
- `pts::Matrix{Float64}`, `(3, M)`: bead positions, `mol`'s centered frame.
- `sel::Vector{Int}`: column indices into `pts` to aggregate over.
"""
function _aggregate(mol::Molecule, pts::Matrix{Float64}, sel::Vector{Int})::Tuple{Float64,Float64}
    isempty(sel) && return (0.0, 0.0)

    crds = Molecules.coords_cartesian(mol)
    els  = Molecules.elms(mol)
    tree = KDTree(crds)

    vals = Vector{Float64}(undef, length(sel))
    @inbounds for (k, i) in enumerate(sel)
        idxs, _ = knn(tree, view(pts, :, i), 1)
        el = _base_element(els[idxs[1]])
        vals[k] = get(ASP, el, 0.0) / _ASP_SCALE
    end

    μ = sum(vals) / length(vals)
    σ = length(vals) > 1 ? _sample_std(vals, μ) : 0.0
    return (μ, σ)
end

"""
    cavity_hydrophilicity(mol; probe, n_target) -> (μ_χ, σ_χ)

Rough per-molecule hydrophilicity signal for `DeltaRho.dro_prior`'s cavity-
water contrast, `Normal(μ_χ, σ_χ)`. Runs `SASA.shell_points`, then delegates
every `CAVITY`-class bead to [`_aggregate`](@ref).

# Arguments
- `mol`: molecule to score; only its cavity-facing surface is used.

# Keywords
- `probe::Float64 = 1.4`: solvent probe radius, forwarded to `SASA.shell_points`.
- `n_target::Union{Nothing,Int} = nothing`: shell point budget, forwarded to
`SASA.shell_points`.
"""
function cavity_hydrophilicity(
    mol::Molecule;
    probe::Float64                = 1.4,
    n_target::Union{Nothing,Int}  = nothing,
)::Tuple{Float64,Float64}
    pts, _, class = SASA.shell_points(mol; probe = probe, n_target = n_target)
    sel = findall(==(SASA.CAVITY), class)
    return _aggregate(mol, pts, sel)
end

end # module Hydrophobicity
