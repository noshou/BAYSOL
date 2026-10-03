# SPDX-License-Identifier: LGPL-2.1-or-later

module BAYSOL

using Statistics: quantile, mean, var
using Printf: @printf, @sprintf
using StaticArrays: SVector
using DocStringExtensions

include("BAYSOL_Utils/BAYSOL_Utils.jl")
include("Geometry/Geometry.jl")
include("AtomicRadii/AtomicRadii.jl")
include("FormFactor/FormFactor.jl")
include("PartialMolarVolumes/PMV.jl")
include("MolecularStructure/MolecularStructure.jl")
include("SASA/SASA.jl")
include("Scattering/Scattering.jl")
include("Fitting/Fitting.jl")

using .BAYSOL_Utils:           BAYSOL_Utils
using .BAYSOL_Utils.Constants: Constants
using .BAYSOL_Utils.Cache:     Cache
using .BAYSOL_Utils.Timing:    Timing
using .Geometry:                Geometry
using .AtomicRadii:             AtomicRadii
using .FormFactor:              FormFactor
using .PartialMolarVolumes:     PartialMolarVolumes
using .MolecularStructure:      MolecularStructure
using .SASA:                    SASA
using .Scattering:              Scattering
using .Fitting:                 Fitting

"""
$(TYPEDSIGNATURES)

Computes a NUTS seed from given data input:

    1.  resolve mol_src to a structure
    2.  if add_hydrogens, run PROPKA on the model (its pKas drive Pdb2pqr's
        terminus protonation) and add hydrogens (Pdb2pqr, pH-driven)
    3.  build the forward-model (gram matrix)
    4.  produce a [`Fitting.Seed`](@ref).

# Arguments
- `mol_src::MolecularStructure.StructureSource`: where to obtain the
    structure from ([`MolecularStructure.LocalPathSource`](@ref),
    [`MolecularStructure.PDBIDSource`](@ref), or
    [`MolecularStructure.URLSource`](@ref)).
- `lMax::Int64`: spherical-harmonic band limit for the forward model.
- `energy::Real`: beam energy in eV.
- `qvals::AbstractVector`: momentum-transfer grid, Å⁻¹.
- `I_exp::AbstractVector, σ_exp::AbstractVector`: measured intensity curve
    and its per-point standard errors; must be the same length as qvals.
- `pH::Real`: solution pH — drives [`Fitting.Protein`](@ref)/[`Fitting.DNA`](@ref)/[`Fitting.RNA`](@ref)
    solute titration and Pdb2pqr's hydrogen placement (when add_hydrogens=true).
- `σ_pH::Real`: standard uncertainty on pH, propagated through solute titration.
- `solutes::Vector{Fitting.Solute}`: the buffer's components, **excluding the
    measured macromolecule** (see [`Fitting.Solute`](@ref)).

# Keywords
-   `add_hydrogens::Bool=true`: whether to run PROPKA + Pdb2pqr at all.
    false skips both and the forward model runs on the structure exactly as
    given (heavy-atom-only, unless the file already carries hydrogens).
-   `blm_chunk::Unsigned = B_LM_CHUNK`: [`Scattering.compute_B_lm`](@ref) batch size, forwarded to
    [`Scattering.forward_cache`](@ref) (results invariant, cost/memory tradeoff only).
-   `thickness::Real = SHELL_THICKNESS`, `probe::Float64 = PROBE_RADIUS`,
    `n_target::Union{Nothing,Int} = SHELL_N_TARGET`: hydration-shell geometry,
    forwarded to [`Scattering.forward_cache`](@ref).
-   `t::Real = DEFAULT_TEMPERATURE_C`: sample temperature in °C, forwarded to
    [`Fitting.seed_fitting`](@ref).
-   `κ_δρ₁₂::Real = DRO12_CONCENTRATION`, `κ_δρ₃::Real = DRO3_CONCENTRATION`:
    concentrations of the δρ₁/δρ₂ and δρ₃ priors, forwarded to
    [`Fitting.seed_fitting`](@ref).

# Returns
-   `seed::Fitting.Seed`, ready to pass to [`run_model`](@ref)/[`Fitting.run_fitting`](@ref).

# Exceptions
- `DomainError`: qvals, I_exp, and σ_exp have mismatched lengths.
- `ArgumentError`: qvals/I_exp/σ_exp are empty.
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
    blm_chunk::Unsigned = BAYSOL_Utils.Constants.B_LM_CHUNK,
    thickness::Real = BAYSOL_Utils.Constants.SHELL_THICKNESS,
    t::Real = BAYSOL_Utils.Constants.DEFAULT_TEMPERATURE_C,
    probe::Float64 = BAYSOL_Utils.Constants.PROBE_RADIUS,
    n_target::Union{Nothing,Int} = BAYSOL_Utils.Constants.SHELL_N_TARGET,
    κ_δρ₁₂::Real = BAYSOL_Utils.Constants.DRO12_CONCENTRATION,
    κ_δρ₃::Real = BAYSOL_Utils.Constants.DRO3_CONCENTRATION,
)::Fitting.Seed
    # the run's clock starts here; write_report reads the wall clock off it
    log = Timing.StageLog()

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

    # load pdb into cache, then add hydrogens if requested. PROPKA's pKas are
    # only consumed by resolve_hydrogens, so it is skipped entirely when
    # add_hydrogens is false.
    path = Timing.timed!(log, :static, 1, "resolve_structure") do
        MolecularStructure.resolve_structure(mol_src)
    end
    hpath = path
    if add_hydrogens
        hit(f) = isfile(f) ? "[cache hit]" : "[cache miss]"
        pKas = Timing.timed!(log, :static, 1, "propka"; note = hit(MolecularStructure._pka_path(path))) do
            MolecularStructure.propka_pKas(path)
        end
        hpath = Timing.timed!(log, :static, 1, "pdb2pqr"; note = hit(MolecularStructure._hydrogens_path(path, pH))) do
            MolecularStructure.resolve_hydrogens(path, pKas, pH)
        end
    end
    mol, _ = Timing.timed!(log, :static, 1, "load_molecule") do
        MolecularStructure.load_molecule(hpath)
    end

    # calculate forward model
    fw = Timing.timed!(log, :static, 1, "forward_cache") do
        Scattering.forward_cache(
            mol,
            qvals,
            lMax,
            energy;
            chunk=blm_chunk,
            thickness=thickness,
            probe=probe,
            n_target=n_target,
            stage_log=log,
        )
    end

    return Timing.timed!(log, :static, 1, "seed_fitting (priors, WLS)") do
        Fitting.seed_fitting(
            fw, I_exp, σ_exp, pH, σ_pH, solutes;
            t=t, κ_δρ₁₂=κ_δρ₁₂, κ_δρ₃=κ_δρ₃, timing=log,
        )
    end
end

"""
    MAPParams = Dict{String, Float64}

Parameter values at the single MAP (maximum a posteriori, i.e.
highest-log-density non-divergent) draw found by [`run_model`](@ref), keyed
by name:

-   `log_density`: the MAP draw's log-posterior density.
-   `slvnt_e_dns`, `delta_rho_1`, `delta_rho_2`, `delta_rho_3`: the shell
    parameters at that draw (see [`Fitting.Seed`](@ref) for the ξ ordering this
    is read off of).
-   `cavity_shell_frac`: fraction of the hydration-shell volume carried by
    cavity beads (from the Gram matrix at the lowest q). When it is ~0, δρ₃ has
    essentially no likelihood and its posterior is just its prior.
-   `scale`, `bkgrndcorr`: the WLS-fit detector scale/background at that draw.
-   `chisqred`: the WLS fit's reduced χ² at that draw.
-   `z_slvnt_e_dns`, `z_delta_rho_1`, `z_delta_rho_2`,
    `z_delta_rho_3`: how many prior standard deviations (θ-space) the
    corresponding physical parameter's MAP value sits from its prior mean.
"""
const MAPParams = Dict{String, Float64}

"""
    MAPResult = Tuple{MAPParams, Matrix{Float64}}

(params, curve) at the MAP draw.
"""
const MAPResult = Tuple{MAPParams, Matrix{Float64}}

"""
    QuantileBounds = Dict{String, Tuple{Float64, Float64}}

One parameter's quantiles/bounds/z triple (all (lo, hi) tuples):
quantiles is the raw empirical (q1, q2) quantile pair; bounds is the
extrema of exactly the draws that fall within [lo, hi], so it can differ
slightly from quantiles itself (it's the tightest interval that actually
contains data on both ends).
"""
const QuantileBounds = Dict{String, Tuple{Float64, Float64}}

"""
    QuantileParams = Dict{String, QuantileBounds}

One [`QuantileBounds`](@ref) per parameter, over the same names as
[`MAPParams`](@ref) (plus "logdensity", minus none).
"""
const QuantileParams = Dict{String, QuantileBounds}

"""
    QuantileCurves = Dict{String, Matrix{Float64}}

"quantiles"/"bounds" predicted-curve envelopes, each a (Q, 3) matrix
whose columns are (q, Ilo(q), Ihi(q)).
"""
const QuantileCurves = Dict{String, Matrix{Float64}}

"""
    QuantileResult = Tuple{QuantileParams, QuantileCurves}

(params, curve), the quantile-filtered counterpart of [`MAPResult`](@ref).
"""
const QuantileResult = Tuple{QuantileParams, QuantileCurves}

"""
$(TYPEDSIGNATURES)

Run NUTS on [`Fitting._logπ`](@ref) starting from seed, returning posterior
draws of the physical parameters ξ = (ρₑ, δρ₁, δρ₂, δρ₃), one
(scale, bkgrndcorr) pair and predicted curve per draw, and
AdvancedHMC.jl's diagnostics.

# The Hamiltonian

HMC adds an auxiliary momentum r ~ N(0, M) (M the mass matrix) and defines
a Hamiltonian:

    H(θ, r) = -log π(θ) + ½ rᵀM⁻¹r

with potential energy as the negative log-posterior, and Gaussian kinetic energy.
Leapfrog integration simulates the system's dynamics forward in time,
alternating half-steps in r with full steps in θ:

    r ← r - (ε/2)·∇[-log π(θ)]
    θ ← θ + ε·M⁻¹r
    r ← r - (ε/2)·∇[-log π(θ)]

which needs ∇[log π(θ)] at every step.

Because energy is conserved, leapfrog proposes long, correlated jumps through
parameter space far more cheaply than random-walk Metropolis. NUTS removes the 
need to hand-pick a trajectory length: it grows the leapfrog trajectory by 
doubling a binary tree of steps, forward and backward in time, until the trajectory
starts to double back on itself (a U-turn), then samples from the valid part of that tree.

# Step-size adaptation

δ is the target Metropolis acceptance rate. During the first nadapt iterations,
StepSizeAdaptor tunes the leapfrog step size ε via dual-averaging so the
empirical acceptance rate converges to δ; too-small ε wastes computation
taking tiny steps, too-large ε causes leapfrog's discretization error (and
therefore the rejection rate) to blow up. MassMatrixAdaptor learns M (here the
full parameter covariance, since dns/δρ are physically coupled through the
forward model) from the trajectory's sample covariance.

# Arguments
- `seed::Seed`: priors, initial point, forward cache, and data.
- `n_samples::Int64`: total number of NUTS iterations (including the
    n_adapt warm-up steps,.
- `n_adapt::Int64`: number of warm-up iterations spent adapting the step
    size and mass matrix before sampling proper.

# Keywords
- `quantiles::AbstractString=DEFAULT_QUANTILES`: the "<lo>-<hi>" empirical quantile
    range (integer percentages, 0 ≤ lo < hi ≤ 100) used to build
    [`QuantileResult`](@ref)'s "quantiles"/"bounds" entries, e.g. the
    default ("16-84") is a ±1σ-equivalent interval for a Normal. The special
    case "0-0" means *no* filtering.
- `l::LIKELIHOOD=PROFILE()`: PROFILE() or MARGINAL(), forwarded to
    [`Fitting._logπ`](@ref)/[`Fitting._ll`](@ref).
- `δ::Real=DEFAULT_TARGET_ACCEPT`: target acceptance rate as a percentage,
    (0, 100) exclusive (validated below); the default, `DEFAULT_TARGET_ACCEPT`,
    is Stan's usual 80%, used here too absent a specific reason to retarget it.

# Returns
A 4-tuple (fit, divergencerate, map, curve):

-   `fit::Fitting.FitResult`: the warm-up free posterior.
-   `divergence_rate::Float64`: fraction of fit's draws AdvancedHMC.jl
    flagged as numerically divergent, [0, 1].
-   `map/curve`: either both nothing or a [`MAPResult`](@ref)/[`QuantileResult`](@ref) pair.
"""
function run_model(
    seed::Fitting.Seed,
    n_samples::Int64,
    n_adapt::Int64;
    quantiles::AbstractString=BAYSOL_Utils.Constants.DEFAULT_QUANTILES,
    l::Fitting.LIKELIHOOD=Fitting.PROFILE(),
    δ::Real=BAYSOL_Utils.Constants.DEFAULT_TARGET_ACCEPT
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
        if ((q_1 ≥ q_2) || q_1 < 0 || q_1 > 100 || q_2 < 0 || q_2 > 100)
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

    if seed.timing !== nothing
        seed.timing.info["n_atoms"]   = seed.fw.n_atoms
        seed.timing.info["lMax"]      = seed.fw.lMax
        seed.timing.info["n_q"]       = length(seed.fw.qvals)
        seed.timing.info["n_samples"] = n_samples
        seed.timing.info["n_adapt"]   = n_adapt
    end

    # calculate unfiltered fit
    fit_unfiltered = Fitting.run_fitting(seed, n_samples, n_adapt; l=l, δ=δ)
    t_post = Timing.tick()

    # filter-out warmup draws
    fit = Fitting.FitResult(
        fit_unfiltered.samples[n_adapt+1:end],
        fit_unfiltered.stats[n_adapt+1:end],
        fit_unfiltered.scale[n_adapt+1:end],
        fit_unfiltered.bkgrnd_corr[n_adapt+1:end],
        fit_unfiltered.c1[n_adapt+1:end],
        fit_unfiltered.chisq_red[n_adapt+1:end],
        fit_unfiltered.curves[:, n_adapt+1:end],
        fit_unfiltered.likelihood,
        fit_unfiltered.timing
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
        # ξ = (ρₑ, δρ₁, δρ₂, δρ₃)
        # z_map: how many prior standard deviations (θ-space) the MAP draw
        # sits from its own prior, one entry per physical parameter.
        ξ_map = fit.samples[max_idx]
        z_map = Fitting.prior_z_scores(ξ_map, seed.pr)
        MAP_params = Dict{String, Float64}(
            "log_density"      => max_llh,
            "slvnt_e_dns"      => ξ_map[1],
            "delta_rho_1"      => ξ_map[2],
            "delta_rho_2"      => ξ_map[3],
            "delta_rho_3"      => ξ_map[4],
            "cavity_shell_frac" => _cavity_shell_frac(seed.fw),
            "scale"         => fit.scale[max_idx],
            "bkgrnd_corr"   => fit.bkgrnd_corr[max_idx],
            "excl_vol_corr" => fit.c1[max_idx],
            "chisq_red"     => fit.chisq_red[max_idx],
            "z_slvnt_e_dns"   => z_map[1],
            "z_delta_rho_1"   => z_map[2],
            "z_delta_rho_2"   => z_map[3],
            "z_delta_rho_3"   => z_map[4],
        )
        # c1 is profiled (no prior), so saturation against its physical
        # bounds is checked once, here, on the single MAP value -- not per
        # posterior draw, since transient saturation during warmup is
        # expected (see BAYSOL_Utils.Constants.EXCL_VOL_CORR_BOUNDS) and
        # not itself diagnostic.
        excl_vol_sat = Fitting.excl_vol_saturation(fit.c1[max_idx])
        MAP_params["excl_vol_sat"] = Float64(excl_vol_sat)
        if excl_vol_sat != 0
            @warn "excluded-volume correction c1 saturated at the $(excl_vol_sat > 0 ? "upper" : "lower") profiling bound" c1=fit.c1[max_idx]
        end
        MAP_curve = hcat(seed.fw.qvals, fit.curves[:, max_idx])
        map =(MAP_params, MAP_curve)

        # filter out all divergent curves
        ll_filt      = getproperty.(fit.stats, :log_density)[filter]
        samples_filt = fit.samples[filter]
        scale_filt   = fit.scale[filter]
        bkgrnd_filt  = fit.bkgrnd_corr[filter]
        c1_filt      = fit.c1[filter]
        chisq_filt   = fit.chisq_red[filter]
        curves       = fit.curves[:, filter]

        # extract parameters from ξ = (ρₑ, δρ₁, δρ₂, δρ₃)
        ρₑ_filt  = getindex.(samples_filt, 1)
        δρ₁_filt = getindex.(samples_filt, 2)
        δρ₂_filt = getindex.(samples_filt, 3)
        δρ₃_filt = getindex.(samples_filt, 4)

        # calculate param quantiles
        ll_lo,  ll_hi        = quantile(ll_filt,     [q_1, q_2])
        δρ₁_lo, δρ₁_hi       = quantile(δρ₁_filt,    [q_1, q_2])
        δρ₂_lo, δρ₂_hi       = quantile(δρ₂_filt,    [q_1, q_2])
        δρ₃_lo, δρ₃_hi       = quantile(δρ₃_filt,    [q_1, q_2])
        ρₑ_lo,  ρₑ_hi        = quantile(ρₑ_filt,     [q_1, q_2])
        scale_lo, scale_hi   = quantile(scale_filt,  [q_1, q_2])
        bkgrnd_lo, bkgrnd_hi = quantile(bkgrnd_filt, [q_1, q_2])
        c1_lo, c1_hi         = quantile(c1_filt,     [q_1, q_2])
        chisq_lo, chisq_hi   = quantile(chisq_filt,  [q_1, q_2])
        z_lo = Fitting.prior_z_scores(SVector(ρₑ_lo, δρ₁_lo, δρ₂_lo, δρ₃_lo), seed.pr)
        z_hi = Fitting.prior_z_scores(SVector(ρₑ_hi, δρ₁_hi, δρ₂_hi, δρ₃_hi), seed.pr)

        # returns a tuple of (low, high) bounds; fails loudly
        function map_bounds(lo, hi, x)
            filtered = (item for item in x if lo ≤ item ≤ hi)
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
                    "quantiles"   => (δρ₁_lo, δρ₁_hi),
                    "bounds"      => map_bounds(δρ₁_lo, δρ₁_hi, δρ₁_filt),
                    "z"           => (z_lo[2], z_hi[2]),
                ),
                "delta_rho_2"     => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (δρ₂_lo, δρ₂_hi),
                    "bounds"      => map_bounds(δρ₂_lo, δρ₂_hi, δρ₂_filt),
                    "z"           => (z_lo[3], z_hi[3]),
                ),
                "delta_rho_3"     => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (δρ₃_lo, δρ₃_hi),
                    "bounds"      => map_bounds(δρ₃_lo, δρ₃_hi, δρ₃_filt),
                    "z"           => (z_lo[4], z_hi[4]),
                ),
                "slvnt_e_dns"     => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (ρₑ_lo, ρₑ_hi),
                    "bounds"      => map_bounds(ρₑ_lo, ρₑ_hi, ρₑ_filt),
                    "z"           => (z_lo[1], z_hi[1]),
                ),
                "scale"           => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (scale_lo, scale_hi),
                    "bounds"      => map_bounds(scale_lo, scale_hi, scale_filt)
                ),
                "bkgrnd_corr"     => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (bkgrnd_lo, bkgrnd_hi),
                    "bounds"      => map_bounds(bkgrnd_lo, bkgrnd_hi, bkgrnd_filt)
                ),
                "excl_vol_corr"   => Dict{String, Tuple{Float64, Float64}}(
                    "quantiles"   => (c1_lo, c1_hi),
                    "bounds"      => map_bounds(c1_lo, c1_hi, c1_filt)
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

    Timing.tock!(seed.timing, :sampling, 1, "MAP + quantiles", t_post)
    return res

end

"Order the physical/derived parameters are reported in, by [`write_report`](@ref)."
const _REPORT_KEYS = [
    "log_density", "slvnt_e_dns", "delta_rho_1", "delta_rho_2",
    "delta_rho_3", "scale", "bkgrnd_corr", "excl_vol_corr", "chisq_red",
]

"The 4 physical parameters that carry a prior."
const _PRIOR_KEYS = [
    "slvnt_e_dns", "delta_rho_1", "delta_rho_2", "delta_rho_3",
]

"""
$(TYPEDSIGNATURES)

Fraction of the hydration-shell volume carried by cavity beads, read off the
Gram matrix at the lowest q (where S_kk → (Σ bead volumes)², so √S_kk is the
species' total volume). 0 when the structure has no cavity beads.
"""
function _cavity_shell_frac(fw::Scattering.ForwardCache)::Float64
    v = [sqrt(max(fw.G[k, k, 1], 0.0)) for k in 3:5]
    tot = sum(v)
    return tot > 0 ? v[3] / tot : 0.0
end

"Display labels for [`write_report`](@ref)'s text output."
const _REPORT_LABELS = Dict{String, String}(
    "log_density"   => "log_density",
    "slvnt_e_dns"   => "ρₑ",
    "delta_rho_1"   => "δρ₁",
    "delta_rho_2"   => "δρ₂",
    "delta_rho_3"   => "δρ₃",
    "scale"         => "scale",
    "bkgrnd_corr"   => "bkgrnd_corr",
    "excl_vol_corr" => "excl_vol_corr",
    "chisq_red"     => "χ²",
)

"""
$(TYPEDSIGNATURES)

The report's `=== Run ===` section: n_atoms, lMax, n_q and the NUTS sizes, as recorded in
the run's [`Timing.StageLog`](@ref). `n_atoms`, if given, overrides the logged count.
Writes nothing when there is neither a log nor an `n_atoms`.
"""
function _write_run_info(io::IO, log::Union{Nothing,Timing.StageLog}; n_atoms::Union{Nothing,Integer} = nothing)
    info = log === nothing ? Dict{String,Any}() : copy(log.info)
    n_atoms === nothing || (info["n_atoms"] = n_atoms)
    isempty(info) && return nothing
    println(io, "=== Run ===")
    for k in ("n_atoms", "lMax", "n_q", "n_samples", "n_adapt")
        haskey(info, k) && @printf(io, "%-10s = %d\n", k, info[k])
    end
    println(io)
    return nothing
end

"""
$(TYPEDSIGNATURES)

The report's `=== Timing ===` section, written last. The wall clock runs from the
creation of `log` (the start of [`seed_model`](@ref)) to now, i.e. to the end of the report.
`t_report` is the [`Timing.tick`](@ref) taken when [`write_report`](@ref) began, so the
`report write` line is the time spent writing every section before this one.
Nothing is written when `log` is `nothing`.

Stages print in the order they were recorded, indented two spaces per depth, with
the group lines (static build, sampling) summing their depth-1 stages. The label
column is as wide as the longest label so the seconds column always lines up.
"""
function _write_timing(io::IO, log::Union{Nothing,Timing.StageLog}, t_report)
    log === nothing && return nothing
    report_s = (time_ns() - t_report[1]) / BAYSOL_Utils.Constants.NS_PER_S
    report_c = (Base.cumulative_compile_time_ns()[1] - t_report[2]) / BAYSOL_Utils.Constants.NS_PER_S
    total_c  = (Base.cumulative_compile_time_ns()[1] - log.compile0) / BAYSOL_Utils.Constants.NS_PER_S
    wall = (time_ns() - log.t0) / BAYSOL_Utils.Constants.NS_PER_S
    st, st_c, st_g = Timing.stage_seconds(log, :static)
    sp, sp_c, sp_g = Timing.stage_seconds(log, :sampling)
    unacc = wall - st - sp - report_s
    # compile time not inside any stage: the first call of run_model, run_fitting and
    # write_report compiles before their bodies (and so their stages) begin
    unacc_c = total_c - st_c - sp_c - report_c

    # (label, seconds, % of wall, JIT seconds); the last two are nothing on plain stage lines
    rows = Tuple{String,Float64,Union{Nothing,Float64},Union{Nothing,Float64}}[]
    push!(rows, ("wall clock  (seed_model → end of report)", wall, 100.0, total_c))
    for (group, label, tot, comp) in ((:static, "static build", st, st_c), (:sampling, "sampling", sp, sp_c))
        push!(rows, ("  " * label, tot, 100 * tot / wall, comp))
        for stage in log.stages
            stage.group === group || continue
            name = stage.note == "" ? stage.name : rpad(stage.name, 22) * stage.note
            push!(rows, ("  "^(stage.depth + 1) * name, stage.seconds, nothing, nothing))
        end
    end
    push!(rows, ("  report write", report_s, nothing, nothing))
    push!(rows, ("  unaccounted", unacc, nothing, max(unacc_c, 0.0)))

    w = maximum(length(r[1]) for r in rows)
    println(io)
    @printf(io, "%-*s %10s %9s %8s\n", w, "=== Timing ===", "seconds", "% wall", "(JIT)")
    for (label, secs, pct, jit) in rows
        @printf(io, "%-*s %10.2f", w, label, secs)
        pct === nothing || @printf(io, " %9.1f", pct)
        jit === nothing || @printf(io, " %8s", @sprintf("(%.1f)", jit))
        println(io)
    end
    @printf(io, "GC: %.1f s\n", st_g + sp_g)
    return nothing
end

"""
$(TYPEDSIGNATURES)

Writes a summary of a [`run_model`](@ref) result to io.

There is also a convenience overload `write_report(result; kwargs...)` that
defaults `io` to `stdout`; see its own one-line definition below.

# Arguments
- `io::IO`: where to write; omit for stdout.
- `result`: a [`run_model`](@ref) return value, (fit, divergencerate, map, curve).

# Keywords
-   `quantile_label::AbstractString=DEFAULT_QUANTILES`: the quantile range the report's
    `=== Quantiles ===` header names; pass the `quantiles` given to [`run_model`](@ref).
- `formfactorlog::Union{Nothing,AbstractVector{<:AbstractString}}=nothing`:
    the seed's seed.fw.form_factor_log.
- `n_atoms::Union{Nothing,Integer}=nothing`: the seed's seed.fw.n_atoms, printed
    as the `n_atoms` line of the `=== Run ===` section. Default nothing uses the
    count recorded in the run's timing log (none is printed if neither exists).

# Logged EBFMI vs. AdvancedHMC's logged EBFMIest

The "EBFMI" line in this report's "=== Diagnostics ===" footer and the
EBFMIest AdvancedHMC.jl logs to the console during sampling use
the same formula (mean(diff(H).^2) / var(H), H = per-draw
Hamiltonian energy), but AdvancedHMC.jl's logs warmup draws which skews 
its result.
"""
function write_report(
    io::IO, result;
    quantile_label::AbstractString = BAYSOL_Utils.Constants.DEFAULT_QUANTILES,
    form_factor_log::Union{Nothing,AbstractVector{<:AbstractString}} = nothing,
    n_atoms::Union{Nothing,Integer} = nothing,
)
    t_report = Timing.tick()
    fit, divergence_rate, map_result, quantile_result = result
    @printf(io, "divergence_rate = %.4f\n\n", divergence_rate)
    _write_run_info(io, fit.timing; n_atoms = n_atoms)

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

        println(io)
        println(io, "=== Standard deviations from prior (θ-space z-score) ===")
        @printf(io, "%-14s %16s %16s %16s\n", "param", "z_MAP", "z_quantile_lo", "z_quantile_hi")
        for k in _PRIOR_KEYS
            haskey(map_params, "z_" * k) || continue
            z_map           = map_params["z_" * k]
            z_lo, z_hi      = quantile_params[k]["z"]
            @printf(io, "%-14s %+16.6g %+16.6g %+16.6g\n", _REPORT_LABELS[k], z_map, z_lo, z_hi)
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
    if map_result !== nothing && haskey(map_params, "cavity_shell_frac")
        f_cav = map_params["cavity_shell_frac"]
        @printf(io, "%-14s = %.4f\n", "cavity_frac", f_cav)
    end

    # c1 is profiled, not sampled with a prior, so this reports whether the
    # MAP draw's profiled c1 hit the physical bound in BAYSOL_Utils.Constants
    # .EXCL_VOL_CORR_BOUNDS -- see Fitting.excl_vol_saturation.
    excl_vol_sat = map_result === nothing ? 0.0 : get(map_params, "excl_vol_sat", 0.0)
    if excl_vol_sat == 0.0
        @printf(io, "%-14s = false\n", "excl_vol_sat")
    elseif excl_vol_sat > 0
        @printf(io, "%-14s = true, c1 -> +∞\n", "excl_vol_sat")
    else
        @printf(io, "%-14s = true, c1 -> -∞\n", "excl_vol_sat")
    end

    if form_factor_log !== nothing && !isempty(form_factor_log)
        println(io)
        println(io, "=== Form-Factor Parsing Log ===")
        for line in form_factor_log
            println(io, line)
        end
    end

    _write_timing(io, fit.timing, t_report)
    return nothing
end

write_report(result; kwargs...) = write_report(stdout, result; kwargs...)

end # module
