# SPDX-License-Identifier: LGPL-2.1-or-later

# Per-species partial-wave terms: one builder per scatterer species in
# A_total(q) = A_vac(q) - dns*A_ex(q) + Σ_k dro_k*A_sh_k(q) (see the
# Scattering docstring). Each builds that species' (N, Q) amplitude and hands
# it to the shared compute_B_lm; species_multipoles assembles all five. The
# S_ab reduction is assembled downstream from the per-species B_lm, so nothing
# here calls self_scatter.
using ..FormFactor: FormFactor
using ..SASA: SASA
using ..MolecularStructure: Molecule, elms, coords_spherical, vols, to_spherical
using ..Timing: StageLog, timed!

# SHELL_THICKNESS is a Scattering module constant (Scattering.jl); PROBE_RADIUS and SHELL_N_TARGET are SASA's
# (imported in Scattering.jl); this file only reads them as call defaults.

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
- `Matrix{Float64}, (N, Q)`, in [`compute_B_lm`](@ref)'s `f_atoms` layout.
"""
function _gaussian_dummy(
    vols::AbstractVector{<:Real}, qvals::AbstractVector{<:Real}
)::Matrix{Float64}
    any(<(0), vols) && throw(ArgumentError("_gaussian_dummy: volumes must be ≥ 0"))
    # (N,) against (1, Q) broadcasts to the (N, Q) f_atoms layout.
    return vols .* exp.(.-(qvals' .^ 2) .* (vols .^ (2 / 3)) ./ (4π))
end

"""
Vacuum term's per-atom amplitude: the X-ray form factor of each ion at photon
energy `energy`, on qvals ((N, Q), complex near an absorption edge). Real atoms
with no solvent at all; near an absorption edge the amplitude is complex
(f0 + f' + i*f''), so `compute_B_lm` returns two channels for this species where
the dummy species return one. [`species_multipoles`](@ref) evaluates the
vacuum and excluded-volume multipoles in one pass from this and
[`_gaussian_dummy`](@ref).

# Keywords
- `log::Union{Nothing,Vector{String}} = nothing`: when not nothing,
    [`FormFactor.form_factor_log`](@ref)'s construction-time diagnostics for
    this call's `form_factor_table` build are append!ed to it in place.

# Returns
- `Matrix{ComplexF64}`, (N, Q), in [`compute_B_lm`](@ref)'s `f_atoms` layout.
"""
function _vacuo_amplitude(
    qvals::AbstractVector{<:Real},
    ions::Vector{String},
    energy::Float64;
    log::Union{Nothing,Vector{String}} = nothing,
)
    tbl = FormFactor.form_factor_table(energy, ions, qvals)
    log === nothing || append!(log, FormFactor.form_factor_log(tbl))
    return FormFactor.form_factors(tbl, ions, qvals)
end

"""
Hydration-shell term, split into CRYSOL 3's three border-layer populations.

[`SASA.sasa`](@ref) is run once; its beads are partitioned by
[`SASA.BeadClass`](@ref) and each class gets its own `B_lm` via
[`compute_B_lm`](@ref), every bead carrying the area * thickness slab of shell
it stands for, so the cloud tiles the layer rather than approximating it with an
envelope. The three arrays are the `sh_convex` / `sh_concave` / `sh_cavity`
species of the five-species expansion
    `A_total` = `A_vac` - dns·`A_ex` + `Σ_k` `dro_k`·`A_sh_k`; each takes its own fitted
contrast `dro_k` downstream (CRYSOL's δρ = (1, 1, 0) defaults).

# Arguments
- `mol`: the molecule; its accessible surface is used, not its atom positions.
- `qvals::AbstractVector{<:Real}, length Q`: momentum-transfer grid in Å⁻¹.
- `lMax::Integer`: maximum spherical harmonic degree.
- `_CHUNK::UInt64`: dummies processed per pass inside [`compute_B_lm`](@ref).

# Keywords
    - `thickness::Float64 = SHELL_THICKNESS`: shell thickness in Å; > 0.
    - `probe::Float64 = PROBE_RADIUS`: solvent probe radius, forwarded to sasa.
    - `n_target::Union{Nothing,Int} = SHELL_N_TARGET`: total shell dummies before the class
    split, the analogue of CRYSOL's --fb. nothing lets SASA.sasa
    size the cloud from the accessible area (≈ area / `SHELL_AREA_PER_POINT`,
    floored at `SHELL_MIN_POINTS`); pass an Int to pin it. Runtime is
    linear in it.

# Returns
- @NamedTuple{convex, concave, cavity} of (C, K, Q) Array{ComplexF64,3},
    C = 1 (dummy amplitudes are real).
"""
function hydration(
    mol::Molecule,
    qvals::AbstractVector{<:Real},
    lMax::Integer,
    _CHUNK::UInt64;
    thickness::Float64           = SHELL_THICKNESS,
    probe::Float64               = PROBE_RADIUS,
    n_target::Union{Nothing,Int} = SHELL_N_TARGET,
)::@NamedTuple{convex::Array{ComplexF64,3}, concave::Array{ComplexF64,3}, cavity::Array{ComplexF64,3}}
    thickness > 0.0 || throw(ArgumentError("hydration: thickness must be > 0"))

    pts, area, class = SASA.sasa(mol; probe = probe, n_target = n_target)

    _shell(want) = begin
        sel = findall(==(want), class)
        crd = to_spherical(pts[:, sel])
        amp = _gaussian_dummy(area[sel] .* thickness, qvals)
        compute_B_lm(crd, qvals, amp, lMax, _CHUNK)
    end

    return (convex  = _shell(SASA.CONVEX),
            concave = _shell(SASA.CONCAVE),
            cavity  = _shell(SASA.CAVITY))
end

"""
The five CRYSOL-3 species' multipoles `B_lm`, in the fixed order

    (vac, ex, sh_convex, sh_concave, sh_cavity)

that [`gram`](@ref) assumes. Each is (C, K, Q) in [`compute_B_lm`](@ref)'s packed
layout (C = 2 for vac near an absorption edge, 1 otherwise; C = 1 for the four
dummy species).

The vacuum and excluded-volume multipoles share one pass over the atoms
([`_compute_B_lm`](@ref)): one spherical-harmonic evaluation and one Bessel
sweep per atom, shared by the form-factor and dummy amplitudes.

# Arguments
- mol::Molecule.
- `qvals::AbstractVector{<:Real}, length Q`: momentum transfer in Å⁻¹.
- `lMax::Integer`: spherical-harmonic band limit.
- `energy::Real`: photon energy in eV (for the vac anomalous form factors).

# Keywords
- `chunk::Unsigned = B_LM_CHUNK`: `compute_B_lm` batch size (results invariant).
- thickness::Real = `SHELL_THICKNESS`, probe::Real = `PROBE_RADIUS`,
    `n_target` = `SHELL_N_TARGET`: forwarded to [`hydration`](@ref).
- `form_factor_log::Union{Nothing,Vector{String}} = nothing`: when not nothing,
    the form-factor table's construction diagnostics are appended to it.
- `stage_log::Union{Nothing,StageLog} = nothing`: if given, records the
    `"vacuum + excluded volume (vols + B_lm)"` and `"hydration (SASA + B_lm)"` stages.

# Returns
- `NTuple{5,Array{ComplexF64,3}}`: (vac, ex, `sh_convex`, `sh_concave`, `sh_cavity`).
"""
function species_multipoles(
    mol::Molecule, qvals::AbstractVector{<:Real}, lMax::Integer, energy::Real;
    chunk::Unsigned                      = B_LM_CHUNK,
    thickness::Real                      = SHELL_THICKNESS,
    probe::Real                          = PROBE_RADIUS,
    n_target::Union{Nothing,Integer}     = SHELL_N_TARGET,
    form_factor_log::Union{Nothing,Vector{String}} = nothing,
    stage_log::Union{Nothing,StageLog} = nothing,
)
    _CHUNK = UInt64(chunk)
    b_vac, b_ex = timed!(stage_log, :static, 2, "vacuum + excluded volume (vols + B_lm)") do
        amp_vac = _vacuo_amplitude(qvals, elms(mol), Float64(energy); log = form_factor_log)
        amp_ex  = _gaussian_dummy(vols(mol), qvals)
        _compute_B_lm(coords_spherical(mol), qvals, (amp_vac, amp_ex), lMax, _CHUNK)
    end
    sh = timed!(stage_log, :static, 2, "hydration (SASA + B_lm)") do
        hydration(
            mol, 
            qvals, 
            lMax, 
            _CHUNK;
            thickness = Float64(thickness), 
            probe = Float64(probe),
            n_target  = n_target
        )
    end
    return (b_vac, b_ex, sh.convex, sh.concave, sh.cavity)
end
