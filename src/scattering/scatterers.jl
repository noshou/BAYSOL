# SPDX-License-Identifier: LGPL-3.0-or-later

# Per-species partial-wave terms: one builder per scatterer species in
# A_total(q) = A_vac(q) - dns*A_ex(q) + Σ_k dro_k*A_sh_k(q) (see the
# Scattering docstring). Each builds that species' (N, Q) amplitude and hands
# it to the shared computeBLm; speciesMultipoles assembles all five. The
# S_ab reduction is assembled downstream from the per-species B_lm, so nothing
# here calls selfScatter.
using ..Geometry: sasa, CONVEX, CONCAVE, CAVITY
using ..MolecularStructure: Molecule, elms, coordsSpherical, vols, toSpherical
using ..Runtime: StageLog, timed!

# SHELL_THICKNESS is a Scattering module constant (scattering/params.jl);
# PROBE_RADIUS is Geometry's (geometry/params.jl, imported in scattering.jl);
# this file only reads it as a call default. `nTarget = nothing` sizes the shell from the
# accessible area.

"""
Per-dummy amplitude f[i,k] = `v_i` * exp(-`q_k²` * `v_i`^(2/3) / 4π), the
Fraser/MacRae/Suzuki (<https://doi.org/10.1107/S0021889878014296>) 
form used by both dummy species.

A uniform sphere of volume `v_i`, approximated by the Gaussian of equal volume:
at q -> 0 it scatters as `v_i`, decaying as a Gaussian whose width is set by `v_i`^(1/3).

# Arguments
- `vols::AbstractVector{<:Real}, length N`: per-dummy volume in Å³, ≥ 0.
- `qvals::AbstractVector{<:Real}, length Q`: momentum-transfer grid in Å⁻¹.

# Returns
- `Matrix{Float64}, (N, Q)`, in [`computeBLm`](@ref)'s `fAtoms` layout.
"""
function _gaussianDummy(
    vols::AbstractVector{<:Real}, qvals::AbstractVector{<:Real},
)::Matrix{Float64}
    any(<(0), vols) && throw(ArgumentError("_gaussianDummy: volumes must be ≥ 0"))

    # v^(2/3) once per dummy: if inside the loop it is a `pow` per (dummy, q) pair
    v23 = Float64.(vols .^ (2 / 3))
    v = Float64.(vols)
    q2 = Float64.(qvals) .^ 2
    N, Q = length(v), length(q2)
    # the (N, Q) fAtoms layout, filled in blocks of rows on the Julia threads (every entry
    # is independent, and the arithmetic is the broadcast's: v · exp(−q² · v^(2/3) / 4π))
    out = Matrix{Float64}(undef, N, Q)
    tmapBlocks(N, ATOM_BLOCK; threaded = N ≥ ATOM_PARALLEL_MIN) do blk
        @inbounds for k in 1:Q
            mq2 = -q2[k]
            for i in blk
                out[i, k] = v[i] * exp(mq2 * v23[i] / (4π))
            end
        end
    end
    return out
end

"""
The amplitude of `n` dummies that all have volume `v`,
as a [`SharedAmplitude`](@ref): the same values as
`_gaussianDummy(fill(v, n), qvals)` without the (n, Q)
matrix (every row is the same Q-vector). The hydration
beads of one class all carry the same area, hence the
same volume.
"""
_gaussianDummyShared(v::Real, n::Integer, qvals::AbstractVector{<:Real}) =
    SharedAmplitude(vec(_gaussianDummy([Float64(v)], qvals)), n)

"""
Vacuum term's per-atom amplitude: the X-ray form factor of each ion at photon
energy `energy`, on qvals ((N, Q), complex near an absorption edge). Real atoms
with no solvent at all; near an absorption edge the amplitude is complex
(f0 + f' + i*f''), so `computeBLm` returns two channels for this species where
the dummy species return one. [`speciesMultipoles`](@ref) evaluates the
vacuum and excluded-volume multipoles in one pass from this and
[`_gaussianDummy`](@ref).

# Keywords
-   `log::Union{Nothing,Vector{String}} = nothing`: when not nothing,
    [`formFactorLog`](@ref BAYSOL.Scattering.formFactorLog)'s
    construction-time diagnostics for this call's `formFactorTable`
    build are append!ed to it in place.

# Returns
- `Matrix{ComplexF64}`, (N, Q), in [`computeBLm`](@ref)'s `fAtoms` layout.
"""
function _vacuoAmplitude(
    qvals::AbstractVector{<:Real},
    ions::Vector{String},
    energy::Float64;
    log::Union{Nothing,Vector{String}} = nothing,
)
    tbl = formFactorTable(energy, ions, qvals)
    log === nothing || append!(log, formFactorLog(tbl))
    return formFactors(tbl, ions, qvals)
end

"""
Hydration-shell term, split into CRYSOL 3's three border-layer populations.

[`sasa`](@ref BAYSOL.Geometry.sasa) is run once; its beads are partitioned by
[`BeadClass`](@ref BAYSOL.Geometry.BeadClass) and each class gets its own `bLm` via
[`computeBLm`](@ref), every bead carrying the area * thickness slab of shell
it stands for, so the cloud tiles the layer rather than approximating it with an
envelope. The three arrays are the `sh_convex` / `sh_concave` / `sh_cavity`
species of the five-species expansion

    `A_total` = `A_vac` - dns·`A_ex` + `Σ_k` `dro_k`·`A_sh_k`; each takes its own fitted

contrast `dro_k` downstream (CRYSOL's δρ = (1, 1, 0) defaults).

# Arguments
- `mol`: the molecule; its accessible surface is used, not its atom positions.
- `qvals::AbstractVector{<:Real}, length Q`: momentum-transfer grid in Å⁻¹.
- `lMax::Integer`: maximum spherical harmonic degree.
- `_CHUNK::UInt64`: dummies processed per pass inside [`computeBLm`](@ref).

# Keywords
    - `thickness::Float64 = SHELL_THICKNESS`: shell thickness in Å; > 0.
    - `probe::Float64 = PROBE_RADIUS`: solvent probe radius, forwarded to sasa.
    - `nTarget::Union{Nothing,Int} = nothing`: total shell dummies before the class
    split, the analogue of CRYSOL's --fb. nothing lets sasa
    size the cloud from the accessible area (≈ area / `SHELL_AREA_PER_POINT`,
    floored at `SHELL_MIN_POINTS`); pass an Int to pin it. Runtime is
    linear in it.
    - `shell::Union{Nothing,Tuple} = nothing`: the accessible surface,
    `sasa(mol; probe, nTarget)`,
    when the caller has already computed it (e.g. to size the band
    limit from the shell's extent);
    `nothing` computes it here. `probe` and `nTarget` are then ignored.

# Returns
- @NamedTuple{convex, concave, cavity} of (C, K, Q) Array{ComplexF64,3},
    C = 1 (dummy amplitudes are real).
"""
function hydration(
    mol::Molecule,
    qvals::AbstractVector{<:Real},
    lMax::Integer,
    _chunk::UInt64;
    thickness::Float64 = SHELL_THICKNESS,
    probe::Float64 = PROBE_RADIUS,
    nTarget::Union{Nothing,Int} = nothing,
    shell::Union{Nothing,Tuple} = nothing,
)::@NamedTuple{
    convex::Array{ComplexF64,3},
    concave::Array{ComplexF64,3},
    cavity::Array{ComplexF64,3},
}
    thickness > 0.0 || throw(ArgumentError("hydration: thickness must be > 0"))

    pts, area, class =
        shell === nothing ?
        sasa(mol; probe = probe, nTarget = nTarget) : shell

    _shell(want) = begin
        sel = findall(==(want), class)
        crd = toSpherical(pts[:, sel])
        v = area[sel] .* thickness
        # beads of a class carry equal areas: one amplitude vector
        # for all of them, not an (N, Q) matrix of equal rows
        amp =
            !isempty(v) && allequal(v) ?
            _gaussianDummyShared(
                v[1], length(v), qvals,
            ) : _gaussianDummy(v, qvals)
        computeBLm(crd, qvals, amp, lMax, _chunk)
    end

    return (convex  = _shell(CONVEX),
        concave = _shell(CONCAVE),
        cavity  = _shell(CAVITY))
end

"""
The five CRYSOL-3 species' multipoles `bLm`, in the fixed order

    (vac, ex, sh_convex, sh_concave, sh_cavity)

that [`gram`](@ref) assumes. Each is (C, K, Q) in [`computeBLm`](@ref)'s packed
layout (C = 2 for vac near an absorption edge, 1 otherwise; C = 1 for the four
dummy species).

The vacuum and excluded-volume multipoles share one pass over the atoms
([`_computeBLm`](@ref)): one spherical-harmonic evaluation and one Bessel
sweep per atom, shared by the form-factor and dummy amplitudes.

# Arguments
- mol::Molecule.
- `qvals::AbstractVector{<:Real}, length Q`: momentum transfer in Å⁻¹.
- `lMax::Integer`: spherical-harmonic band limit.
- `energy::Real`: photon energy in eV (for the vac anomalous form factors).

# Keywords
- `chunk::Unsigned = B_LM_CHUNK`: `computeBLm` batch size (results invariant).
- thickness::Real = `SHELL_THICKNESS`, probe::Real = `PROBE_RADIUS`,
    `nTarget` = `nothing`, `shell` = nothing: forwarded to [`hydration`](@ref).
- `formFactorLog::Union{Nothing,Vector{String}} = nothing`: when not nothing,
    the form-factor table's construction diagnostics are appended to it.
- `stageLog::Union{Nothing,StageLog} = nothing`: if given, records the
    `"vacuum + excluded volume (vols + B_lm)"` and `"hydration (SASA + B_lm)"` stages.

# Returns
- `NTuple{5,Array{ComplexF64,3}}`: (vac, ex, `sh_convex`, `sh_concave`, `sh_cavity`).
"""
function speciesMultipoles(
    mol::Molecule, qvals::AbstractVector{<:Real}, lMax::Integer, energy::Real;
    chunk::Unsigned = B_LM_CHUNK,
    thickness::Real = SHELL_THICKNESS,
    probe::Real = PROBE_RADIUS,
    nTarget::Union{Nothing,Integer} = nothing,
    shell::Union{Nothing,Tuple} = nothing,
    formFactorLog::Union{Nothing,Vector{String}} = nothing,
    stageLog::Union{Nothing,StageLog} = nothing,
)
    _chunk = UInt64(chunk)
    bVac, bEx = timed!(stageLog, :static, 2, "vacuum + excluded volume (vols + B_lm)") do
        ampVac = _vacuoAmplitude(qvals, elms(mol), Float64(energy); log = formFactorLog)
        ampEx  = _gaussianDummy(vols(mol), qvals)
        _computeBLm(coordsSpherical(mol), qvals, (ampVac, ampEx), lMax, _chunk)
    end
    sh = timed!(
        stageLog,
        :static, 2, shell === nothing ? "hydration (SASA + B_lm)" : "hydration (B_lm)",
    ) do
        hydration(
            mol,
            qvals,
            lMax,
            _chunk;
            thickness = Float64(thickness),
            probe     = Float64(probe),
            nTarget   = nTarget,
            shell     = shell,
        )
    end
    return (bVac, bEx, sh.convex, sh.concave, sh.cavity)
end
