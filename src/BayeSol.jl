# SPDX-License-Identifier: LGPL-2.1-or-later

module BayeSol

using Statistics: quantile, mean, var
using Printf: @printf

include("BayesolUtils/BayesolUtils.jl")
include("AtomicRadii/AtomicRadii.jl")
include("FormFactor/FormFactor.jl")
include("PartialMolarVolumes/PMV.jl")
include("MolecularStructure/MolecularStructure.jl")
include("Solvation/Solvation.jl")
include("Scattering/Scattering.jl")
include("Fitting/Fitting.jl")

using .BayesolUtils:             BayesolUtils
using .BayesolUtils.Constants:   Constants
using .BayesolUtils.Cache:       Cache
using .AtomicRadii:         AtomicRadii
using .FormFactor:          FormFactor
using .PartialMolarVolumes: PartialMolarVolumes
using .MolecularStructure:  MolecularStructure
using .Solvation:           Solvation
using .Scattering:          Scattering
using .Fitting:             Fitting

"""
    seed_model(
        mol_src, lMax, energy, qvals, I_exp, σ_exp, pH, σ_pH, solutes;
        add_hydrogens=true, blm_chunk=B_LM_CHUNK, thickness=SHELL_THICKNESS,
        t=DEFAULT_TEMPERATURE_C, n=C1_PRIOR_MASS_PERCENT, probe=PROBE_RADIUS,
        n_target=SHELL_N_TARGET, ionic_strength_M=IONIC_STRENGTH_M, eps_r=WATER_EPS_R, 
        T=DEBYE_TEMPERATURE_K, cutoff_debye_lengths=CUTOFF_DEBYE_LENGTHS
    ) -> Tuple{Fitting.Seed, Float64, Float64}

Computes a NUTS seed from given data input:
    
    1. resolve `mol_src` to a structure
    2. run PROPKA on the model 
    3. optionally add hydrogens (PDB2PQR, pH-driven)
    4. build the forward-model (gram matrix) 
    5. compute the structure's screened-electrostatic `(μ_χ, σ_χ)` signal
    6. produce a [`Fitting.Seed`](@ref).

# Arguments
- `mol_src::MolecularStructure.StructureSource`: where to obtain the
    structure from (`LocalPathSource`, `PDBIDSource`, or `URLSource`).
- `lMax::Int64`: spherical-harmonic band limit for the forward model.
- `energy::Real`: beam energy in eV.
- `qvals::AbstractVector`: momentum-transfer grid, Å⁻¹.
- `I_exp::AbstractVector`, `σ_exp::AbstractVector`: measured intensity curve
    and its per-point standard errors; must be the same length as `qvals`.
- `pH::Real`: solution pH — drives `Protein`/`DNA`/`RNA` solute titration,
    PDB2PQR's hydrogen placement (when `add_hydrogens=true`), and `Ionization`.
- `σ_pH::Real`: standard uncertainty on `pH`, propagated through solute
    titration and through `Ionization`'s `σ_charge`.
- `solutes::Vector{Fitting.Solute}`: the species in solution.

# Keywords
- `add_hydrogens::Bool=true`: whether to run PDB2PQR at all
    (`resolve_hydrogens(...; add=add_hydrogens)`); `false` is a genuine no-op
    — the forward model then runs on the heavy-atom-only structure.
- `blm_chunk::Unsigned = B_LM_CHUNK`: `compute_B_lm` batch size, forwarded to
    `forward_cache` (results invariant, cost/memory tradeoff only).
- `thickness::Real = SHELL_THICKNESS`, `probe::Float64 = PROBE_RADIUS`,
    `n_target::Union{Nothing,Int} = SHELL_N_TARGET`: hydration-shell geometry,
    forwarded to both `forward_cache` and `protein_cavity_electrostatics`
    (the same solvent-accessible-surface geometry underlies both).
- `t::Real = DEFAULT_TEMPERATURE_C`: solution temperature in °C, forwarded to
    `seed_fitting`/`_calc_ξ_priors`. **!!NOTE!!: should NOT be changed, since
    only water is temperature-dependent in this version.**
- `n::Real = C1_PRIOR_MASS_PERCENT`: percentage `(0, 100]` of `c1_prior`'s
    mass required within CRYSOL's `[0.96, 1.04]` bound; forwarded to
    `seed_fitting`.
- `ionic_strength_M::Float64 = IONIC_STRENGTH_M`, `eps_r::Float64 = WATER_EPS_R`,
    `T::Float64 = DEBYE_TEMPERATURE_K`, `cutoff_debye_lengths::Float64 =
    CUTOFF_DEBYE_LENGTHS`: Debye-Hückel screening parameters, forwarded to
    `protein_cavity_electrostatics`.

# Returns
- `(seed, μ_χ, σ_χ)`: `seed::Fitting.Seed` is ready to pass to
    [`run_model`](@ref)/`Fitting.run_fitting`; `μ_χ`/`σ_χ` are the same
    screened-electrostatic cavity signal computed at step 5 above (and
    already folded into `seed`'s priors) — returned separately so they can
    be threaded into [`write_report`](@ref)'s diagnostics.

# Exceptions
- `DomainError`: `qvals`, `I_exp`, and `σ_exp` have mismatched lengths.
- `ArgumentError`: `qvals`/`I_exp`/`σ_exp` are empty.
"""
function seed_model(
    mol_src::MolecularStructure.StructureSource,
    lMax::Int64,
    energy::Real,
    qvals::AbstractVector,
    I_exp::AbstractVector,
    σ_exp::AbstractVector,
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Fitting.Solute};
    add_hydrogens::Bool=true,
    blm_chunk::Unsigned = BayesolUtils.Constants.B_LM_CHUNK,
    thickness::Real = BayesolUtils.Constants.SHELL_THICKNESS,
    t::Real = BayesolUtils.Constants.DEFAULT_TEMPERATURE_C,
    n::Real = BayesolUtils.Constants.C1_PRIOR_MASS_PERCENT,
    probe::Float64 = BayesolUtils.Constants.PROBE_RADIUS,
    n_target::Union{Nothing,Int} = BayesolUtils.Constants.SHELL_N_TARGET,
    ionic_strength_M::Float64 = BayesolUtils.Constants.IONIC_STRENGTH_M,
    eps_r::Float64 = BayesolUtils.Constants.WATER_EPS_R,
    T::Float64 = BayesolUtils.Constants.DEBYE_TEMPERATURE_K,
    cutoff_debye_lengths::Float64 = BayesolUtils.Constants.CUTOFF_DEBYE_LENGTHS,
)::Tuple{Fitting.Seed, Float64, Float64}
    
    if !(length(qvals) == length(I_exp) == length(σ_exp)) 
        throw(
            DomainError(
                (
                    length(qvals), length(I_exp), length(σ_exp),
                    "qvals, I_exp, and σ_exp must have the same length"
                )
            )
        )
    elseif (length(qvals) == 0)
        throw(ArgumentError("qvals, I_exp, and σ_exp cannot be empty"))
    end
    
    # load pdb into cache and load residues w/o hydrogens, then resolve if needed
    path            = MolecularStructure.resolve_structure(mol_src)
    pKa_records     = MolecularStructure.propka_pKas(path)
    hpath           = MolecularStructure.resolve_hydrogens(path, pKa_records, pH; add=add_hydrogens)
    mol, residues   = MolecularStructure.load_molecule(hpath)

    # calculate forward model
    fw = Scattering.forward_cache(
        mol,
        qvals,
        lMax,
        energy;
        chunk=blm_chunk,
        thickness=thickness,
        probe=probe,
        n_target=n_target
    )

    # calculate ionization + electrostatics
    ionization = MolecularStructure.Ionization(residues, pKa_records, pH, σ_pH)
    μ_χ, σ_χ = Solvation.protein_cavity_electrostatics(
        mol,
        residues,
        ionization;
        probe=probe,
        n_target=n_target,
        ionic_strength_M=ionic_strength_M,
        eps_r=eps_r,
        T=T,
        cutoff_debye_lengths=cutoff_debye_lengths
    )

    seed = Fitting.seed_fitting(
        fw,
        I_exp,
        σ_exp,
        pH,
        σ_pH,
        solutes;
        t=t,
        μ_χ=μ_χ,
        σ_χ=σ_χ,
        n=n
    )
    return seed, μ_χ, σ_χ
end

"""
    MAPParams = Dict{String, Float64}

Parameter values at the single MAP (maximum a posteriori, i.e.
highest-log-density non-divergent) draw found by [`run_model`](@ref), keyed
by name:

- `"log_density"`: the MAP draw's log-posterior density.
- `"slvnt_e_dns"`, `"delta_rho_1"`, `"delta_rho_2"`, `"delta_rho_3"`,
    `"excl_vol_corr"`: the physical parameters `ξ = (dns, δρ1, δρ2, δρ3, c1)`
    at that draw (see [`Fitting.Seed`](@ref) for the `ξ` ordering this is
    read off of).
- `"scale"`, `"bkgrnd_corr"`: the WLS-fit detector scale/background at that
    draw.
- `"chisq_red"`: the WLS fit's reduced χ² at that draw.
"""
const MAPParams = Dict{String, Float64}

"""
    MAPResult = Tuple{MAPParams, Matrix{Float64}}

`(params, curve)` at the MAP draw.
"""
const MAPResult = Tuple{MAPParams, Matrix{Float64}}

"""
    QuantileBounds = Dict{String, Tuple{Float64, Float64}}

One parameter's `"quantiles"`/`"bounds"` pair (both `(lo, hi)` tuples):
`"quantiles"` is the raw empirical `(q_1, q_2)` quantile pair; `"bounds"` is the
`extrema` of exactly the draws that fall within `[lo, hi]`, so it can differ
slightly from `"quantiles"` itself (it's the tightest interval that actually
contains data on both ends).
"""
const QuantileBounds = Dict{String, Tuple{Float64, Float64}}

"""
    QuantileParams = Dict{String, QuantileBounds}

One [`QuantileBounds`](@ref) per parameter, over the same names as
[`MAPParams`](@ref) (plus `"log_density"`, minus none).
"""
const QuantileParams = Dict{String, QuantileBounds}

"""
    QuantileCurves = Dict{String, Matrix{Float64}}

`"quantiles"`/`"bounds"` predicted-curve envelopes, each a `(Q, 3)` matrix
whose columns are `(q, I_lo(q), I_hi(q))`.
"""
const QuantileCurves = Dict{String, Matrix{Float64}}

"""
    QuantileResult = Tuple{QuantileParams, QuantileCurves}

`(params, curve)`, the quantile-filtered counterpart of [`MAPResult`](@ref).
"""
const QuantileResult = Tuple{QuantileParams, QuantileCurves}

"""
    run_model(
        seed::Seed,
        n_samples::Int64,
        n_adapt::Int64;
        quantiles::AbstractString="16-84",
        l::LIKELIHOOD=PROFILE(),
        δ::Real=80
    ) -> Union{
            Tuple{Fitting.FitResult, Float64, MAPResult, QuantileResult},
            Tuple{Fitting.FitResult, Float64, Nothing, Nothing}
        }

Run NUTS on [`Fitting._logπ`](@ref) starting from `seed`, returning posterior
draws of the physical parameters `ξ = (dns, δρ1, δρ2, δρ3, c1)`, one
`(scale, bkgrnd_corr)` pair and predicted curve per draw, and
`AdvancedHMC.jl`'s diagnostics.

# The Hamiltonian

HMC adds an auxiliary momentum `r ~ N(0, M)` (`M` the mass matrix) and defines 
a Hamiltonian:

    H(θ, r) = -log π(θ) + ½ rᵀM⁻¹r

with potential energy as the negative log-posterior, and Gaussian kinetic energy. 
Leapfrog integration simulates the system's dynamics forward in time,
alternating half-steps in `r` with full steps in `θ`:

    r ← r - (ε/2)·∇[-log π(θ)]
    θ ← θ + ε·M⁻¹r
    r ← r - (ε/2)·∇[-log π(θ)]

which needs `∇[log π(θ)]` at every step.

Because energy is conserved, leapfrog proposes long, correlated jumps through
parameter space far more cheaply than random-walk Metropolis. NUTS removes the 
need to hand-pick a trajectory length: it grows the leapfrog trajectory by 
doubling a binary tree of steps, forward and backward in time, until the trajectory
starts to double back on itself (a "U-turn"), then samples from the valid part of that tree.

# Step-size adaptation

`δ` is the target Metropolis acceptance rate. During the first `n_adapt` iterations,
`StepSizeAdaptor` tunes the leapfrog step size `ε` via dual-averaging so the
empirical acceptance rate converges to `δ`; too-small `ε` wastes computation
taking tiny steps, too-large `ε` causes leapfrog's discretization error (and
therefore the rejection rate) to blow up. `MassMatrixAdaptor` learns `M` (here the 
full parameter covariance, since `dns`/`δρ`/`c1` are physically coupled through the 
forward model) from the trajectory's sample covariance.

# Arguments
- `seed::Seed`: priors, initial point, forward cache, and data.
- `n_samples::Int64`: total number of NUTS iterations (including the
    `n_adapt` warm-up steps, which are kept -- no filtering is done here).
- `n_adapt::Int64`: number of warm-up iterations spent adapting the step
    size and mass matrix before sampling proper.

# Keywords
- `quantiles::AbstractString="16-84"`: the `"<lo>-<hi>"` empirical quantile
    range (integer percentages, `0 <= lo < hi <= 100`) used to build
    [`QuantileResult`](@ref)'s `"quantiles"`/`"bounds"` entries, e.g. the
    default `"16-84"` is a ±1σ-equivalent interval for a Normal. The special
    case `"0-0"` means *no* filtering -- internally treated as the full
    `0`-`100` range, so `"bounds"` spans the entire (non-divergent) sample.
- `l::LIKELIHOOD=PROFILE()`: `PROFILE()` or `MARGINAL()`, forwarded to
    [`Fitting._logπ`](@ref)/[`Fitting._ll`](@ref).
- `δ::Real=80`: target acceptance rate as a percentage, `(0, 100)` exclusive
    (validated below); Stan's usual default of 80% is used here too absent a
    specific reason to retarget it.

# Returns
A 4-tuple `(fit, divergence_rate, map, curve)`:

- `fit::Fitting.FitResult`: the warm-up free posterior.
- `divergence_rate::Float64`: fraction of `fit`'s draws AdvancedHMC.jl
    flagged as numerically divergent, `[0, 1]`.
- `map`/`curve`: **either** both `nothing` (every draw diverged -- `map`/
    `curve` cannot be computed, and `divergence_rate == 1.0`), **or** a
    [`MAPResult`](@ref)/[`QuantileResult`](@ref) pair computed over the
    non-divergent draws only. `map === nothing` iff `curve === nothing`.
"""
function run_model(
    seed::Fitting.Seed,
    n_samples::Int64,
    n_adapt::Int64;
    quantiles::AbstractString="16-84",
    l::Fitting.LIKELIHOOD=Fitting.PROFILE(),
    δ::Real=80
)::Union{
    Tuple{Fitting.FitResult, Float64, MAPResult, QuantileResult},
    Tuple{Fitting.FitResult, Float64, Nothing, Nothing}
}

    # parse quantiles
    q_regex = r"^(\d+)-(\d+)$"
    if !occursin(q_regex, quantiles)
        throw(DomainError(quantiles, "quantiles must be '<#>-<#>'"))
    else
        q_match = match(q_regex, quantiles)
        q_1 = parse(Int64, q_match.captures[1])
        q_2 = parse(Int64, q_match.captures[2])
        if ((q_1 >= q_2) || q_1 < 0 || q_1 > 100 || q_2 < 0 || q_2 > 100)
            # special case: "0-0" means no quantile filtering
            if !(q_1 == 0 && q_2 == 0)
                throw(DomainError((q_1, q_2), "invalid quantile range"))
            end
        end
    end
    q_1, q_2 = q_1 / 100, q_2 / 100

    # "0-0" means no quantile filtering: reuse the same quantile/map_bounds
    # machinery below with the full 0th-100th percentile range, which by
    # construction spans (and therefore filters out nothing from) the data.
    if q_1 == 0 && q_2 == 0
        q_1, q_2 = 0.0, 1.0
    end

    # calculate unfiltered fit
    fit_unfiltered = Fitting.run_fitting(seed, n_samples, n_adapt; l=l, δ=δ)

    # filter-out warmup draws
    fit = Fitting.FitResult(
        fit_unfiltered.samples[n_adapt+1:end],
        fit_unfiltered.stats[n_adapt+1:end],
        fit_unfiltered.scale[n_adapt+1:end],
        fit_unfiltered.bkgrnd_corr[n_adapt+1:end],
        fit_unfiltered.chisq_red[n_adapt+1:end],
        fit_unfiltered.curves[:, n_adapt+1:end],
        fit_unfiltered.likelihood
    )

    # Numerical instabilities can occur when the posterior has very 
    # different curvature/scales across dimensions. Such samples are 
    # flagged as divergent and excluded from MAP selection.
    filter  = trues(length(fit.stats))
    max_llh = -Inf
    max_idx = 0
    diverged = 0
    @inbounds for i in 1:length(fit.stats)
        if fit.stats[i].numerical_error
            diverged += 1
            filter[i] = false
        elseif fit.stats[i].log_density > max_llh
            max_llh = fit.stats[i].log_density
            max_idx = i
        end
    end
    if diverged == length(fit.stats)
        println("WARNING: all runs diverged; MAP and quantiles not run!")
        res = (fit, 1., nothing, nothing)
    else
        divergence_rate = diverged / length(fit.stats)
        
        # calculate MAP params + curves
        # ξ = (dns, δρ1, δρ2, δρ3, c1)
        MAP_params = Dict{String, Float64}(
            "log_density"   => max_llh,
            "slvnt_e_dns"   => getindex.(fit.samples, 1)[max_idx],
            "delta_rho_1"   => getindex.(fit.samples, 2)[max_idx],
            "delta_rho_2"   => getindex.(fit.samples, 3)[max_idx],
            "delta_rho_3"   => getindex.(fit.samples, 4)[max_idx],
            "excl_vol_corr" => getindex.(fit.samples, 5)[max_idx],
            "scale"         => fit.scale[max_idx],
            "bkgrnd_corr"   => fit.bkgrnd_corr[max_idx],
            "chisq_red"     => fit.chisq_red[max_idx]
        )
        MAP_curve = hcat(seed.fw.qvals, fit.curves[:, max_idx])
        map =(MAP_params, MAP_curve)

        # filter out all divergent curves
        ll_filt      = getproperty.(fit.stats, :log_density)[filter]
        samples_filt = fit.samples[filter]
        scale_filt   = fit.scale[filter]
        bkgrnd_filt  = fit.bkgrnd_corr[filter]
        chisq_filt   = fit.chisq_red[filter]
        curves       = fit.curves[:, filter]
        
        # extract parameters from ξ = (dns, δρ1, δρ2, δρ3, c1)
        ρₑ_filt  = getindex.(samples_filt, 1)
        δρ1_filt = getindex.(samples_filt, 2)
        δρ2_filt = getindex.(samples_filt, 3)
        δρ3_filt = getindex.(samples_filt, 4)
        c_1_filt = getindex.(samples_filt, 5)

        # calculate param quantiles
        ll_lo,  ll_hi        = quantile(ll_filt,     [q_1, q_2])
        δρ1_lo, δρ1_hi       = quantile(δρ1_filt,    [q_1, q_2])
        δρ2_lo, δρ2_hi       = quantile(δρ2_filt,    [q_1, q_2])
        δρ3_lo, δρ3_hi       = quantile(δρ3_filt,    [q_1, q_2])
        ρₑ_lo,  ρₑ_hi        = quantile(ρₑ_filt,     [q_1, q_2])
        c_1_lo, c_1_hi       = quantile(c_1_filt,    [q_1, q_2])
        scale_lo, scale_hi   = quantile(scale_filt,  [q_1, q_2])
        bkgrnd_lo, bkgrnd_hi = quantile(bkgrnd_filt, [q_1, q_2])
        chisq_lo, chisq_hi   = quantile(chisq_filt,  [q_1, q_2])

        # returns a tuple of (low, high) bounds; fails loudly
        function map_bounds(lo, hi, x)
            filtered = (item for item in x if lo <= item <= hi)
            if (isempty(filtered))
                error("Illegal state: filtered cannot be empty!")
            end
            return extrema(filtered)
        end

        # dict of parameters
        params  = Dict{String, Dict{String, Tuple{Float64, Float64}}}(
                "log_density"     => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (ll_lo, ll_hi),
                    "bounds"      => map_bounds(ll_lo, ll_hi, ll_filt)
                ),
                "delta_rho_1"     => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (δρ1_lo, δρ1_hi),
                    "bounds"      => map_bounds(δρ1_lo, δρ1_hi, δρ1_filt)
                ),
                "delta_rho_2"     => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (δρ2_lo, δρ2_hi),
                    "bounds"      => map_bounds(δρ2_lo, δρ2_hi, δρ2_filt)
                ),
                "delta_rho_3"     => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (δρ3_lo, δρ3_hi),
                    "bounds"      => map_bounds(δρ3_lo, δρ3_hi, δρ3_filt)
                ),
                "slvnt_e_dns"     => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (ρₑ_lo, ρₑ_hi),
                    "bounds"      => map_bounds(ρₑ_lo, ρₑ_hi, ρₑ_filt)
                ),
                "excl_vol_corr"   => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (c_1_lo, c_1_hi),
                    "bounds"      => map_bounds(c_1_lo, c_1_hi, c_1_filt)
                ),
                "scale"           => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (scale_lo, scale_hi),
                    "bounds"      => map_bounds(scale_lo, scale_hi, scale_filt)
                ),
                "bkgrnd_corr"     => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (bkgrnd_lo, bkgrnd_hi),
                    "bounds"      => map_bounds(bkgrnd_lo, bkgrnd_hi, bkgrnd_filt)
                ),
                "chisq_red"       => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (chisq_lo, chisq_hi),
                    "bounds"      => map_bounds(chisq_lo, chisq_hi, chisq_filt)
                )
            )

        # curve is Q x I_low(Q) x I_hi(Q)
        qvals = seed.fw.qvals
        Q = size(curves, 1)
        curve_quantiles = Matrix{Float64}(undef, Q, 3)
        curve_bounds    = Matrix{Float64}(undef, Q, 3)
        for q in 1:Q
            I = curves[q, :]

            I_lo, I_hi = quantile(I, [q_1, q_2])

            curve_quantiles[q, :] .= (qvals[q], I_lo, I_hi)
            curve_bounds[q, :]    .= (qvals[q], map_bounds(I_lo, I_hi, I)...)
        end

        curve = Dict{String, Matrix{Float64}}(
            "quantiles" => curve_quantiles,
            "bounds"    => curve_bounds
        )

        res = (fit, divergence_rate, map, (params, curve))
    end

    return res

end

"Order the physical/derived parameters are reported in, by `write_report`."
const _REPORT_KEYS = [
    "log_density", "slvnt_e_dns", "delta_rho_1", "delta_rho_2",
    "delta_rho_3", "excl_vol_corr", "scale", "bkgrnd_corr", "chisq_red",
]

"Display labels for `write_report`'s text output only -- the underlying
`MAPParams`/`QuantileParams` Dict keys (`_REPORT_KEYS` above) are unchanged
and still what callers index with."
const _REPORT_LABELS = Dict{String, String}(
    "log_density"   => "log_density",
    "slvnt_e_dns"   => "ρₑ",
    "delta_rho_1"   => "δρ1",
    "delta_rho_2"   => "δρ2",
    "delta_rho_3"   => "δρ3",
    "excl_vol_corr" => "excl_vol_corr",
    "scale"         => "scale",
    "bkgrnd_corr"   => "bkgrnd_corr",
    "chisq_red"     => "χ²",
)

"""
    write_report(
        io::IO, result;
        quantile_label::AbstractString="16-84",
        μ_χ::Union{Nothing,Real}=nothing, σ_χ::Union{Nothing,Real}=nothing,
        form_factor_log::Union{Nothing,AbstractVector{<:AbstractString}}=nothing
    )
    write_report(
        result;
        quantile_label::AbstractString="16-84",
        μ_χ::Union{Nothing,Real}=nothing, σ_χ::Union{Nothing,Real}=nothing,
        form_factor_log::Union{Nothing,AbstractVector{<:AbstractString}}=nothing
    )

Writes a human-readable summary of a [`run_model`](@ref) `result` to `io`
(`stdout` if omitted): the divergence rate, the MAP draw's parameters (incl.
`chisq_red`), each parameter's quantile/bound interval, a `"===
Diagnostics ==="` footer -- `AdvancedHMC.jl` per-chain sampler health
computed from `fit.stats` (already the warm-up-free portion): iteration
count, mean acceptance rate, tree depth (mean and max), mean leapfrog steps
per iteration, E-BFMI (Stan's energy-based Bayesian Fraction of Missing
Information -- values below ~0.2-0.3 suggest momentum resampling isn't
exploring the Hamiltonian's energy level sets well and the model may need
reparameterizing), and, only when supplied, the seed's screened-electrostatic
cavity signal `μ_χ`/`σ_χ` (see [`seed_model`](@ref)) -- and, as the final
section, a `"=== Form-Factor Parsing Log ==="` listing any
`ForwardCache.form_factor_log` entries (see
[`Scattering.forward_cache`](@ref)) when `form_factor_log` is supplied and
non-empty. The diagnostics footer is written even when every draw diverged,
since it's most useful exactly in that failure case.

# Arguments
- `io::IO`: where to write; omit for `stdout`.
- `result`: a `run_model` return value, `(fit, divergence_rate, map, curve)`.

# Keywords
- `quantile_label::AbstractString="16-84"`
- `μ_χ::Union{Nothing,Real}=nothing`, `σ_χ::Union{Nothing,Real}=nothing`:
    the `(μ_χ, σ_χ)` returned alongside the seed by [`seed_model`](@ref).
    Default `nothing` prints nothing for either field; passing either one
    adds it to the `"=== Diagnostics ==="` footer.
- `form_factor_log::Union{Nothing,AbstractVector{<:AbstractString}}=nothing`:
    the seed's `seed.fw.form_factor_log` (form-factor-table construction
    diagnostics -- one line per ion the backend could not resolve in full).
    Default `nothing`, or an empty vector, prints nothing; a non-empty vector
    is printed verbatim, one entry per line, as the report's final section.
"""
function write_report(
    io::IO, result;
    quantile_label::AbstractString = "16-84",
    μ_χ::Union{Nothing,Real} = nothing,
    σ_χ::Union{Nothing,Real} = nothing,
    form_factor_log::Union{Nothing,AbstractVector{<:AbstractString}} = nothing,
)
    fit, divergence_rate, map_result, quantile_result = result
    @printf(io, "divergence_rate = %.4f\n\n", divergence_rate)

    if map_result === nothing
        println(io, "All draws diverged; no MAP/quantiles available.")
    else
        map_params, _ = map_result
        quantile_params, _ = quantile_result

        println(io, "=== MAP ===")
        for k in _REPORT_KEYS
            @printf(io, "%-14s = %+.6g\n", _REPORT_LABELS[k], map_params[k])
        end

        println(io)
        println(io, "=== Quantiles ($quantile_label) ===")
        @printf(
            io, "%-14s %16s %16s %16s %16s\n",
            "param", "quantile_lo", "quantile_hi", "bound_lo", "bound_hi"
        )
        for k in _REPORT_KEYS
            q_lo, q_hi = quantile_params[k]["quantiles"]
            b_lo, b_hi = quantile_params[k]["bounds"]
            @printf(io, "%-14s %+16.6g %+16.6g %+16.6g %+16.6g\n", _REPORT_LABELS[k], q_lo, q_hi, b_lo, b_hi)
        end
    end

    println(io)
    println(io, "=== Diagnostics ===")
    stats  = fit.stats
    accept = getproperty.(stats, :acceptance_rate)
    depth  = getproperty.(stats, :tree_depth)
    nsteps = getproperty.(stats, :n_steps)
    H      = getproperty.(stats, :hamiltonian_energy)
    # E-BFMI: Stan's energy-based Bayesian Fraction of Missing Information,
    # diagnosing whether momentum resampling explores the Hamiltonian's
    # energy level sets adequately. Values below ~0.2-0.3 are the usual
    # "may be problematic, consider reparameterizing" threshold.
    ebfmi = mean(diff(H) .^ 2) / var(H)
    @printf(io, "%-14s = %d\n", "iterations", length(stats))
    @printf(io, "%-14s = %.4f\n", "mean_accept", mean(accept))
    @printf(io, "%-14s = %.2f (max %d)\n", "tree_depth", mean(depth), maximum(depth))
    @printf(io, "%-14s = %.2f\n", "mean_n_steps", mean(nsteps))
    @printf(io, "%-14s = %.4f\n", "EBFMI", ebfmi)
    if μ_χ !== nothing
        @printf(io, "%-14s = %+.6g\n", "μ_χ", μ_χ)
    end
    if σ_χ !== nothing
        @printf(io, "%-14s = %+.6g\n", "σ_χ", σ_χ)
    end

    if form_factor_log !== nothing && !isempty(form_factor_log)
        println(io)
        println(io, "=== Form-Factor Parsing Log ===")
        for line in form_factor_log
            println(io, line)
        end
    end

    return nothing
end

write_report(result; kwargs...) = write_report(stdout, result; kwargs...)

end # module
