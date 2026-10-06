# SPDX-License-Identifier: LGPL-2.1-or-later

"""
The pipeline entry points and the run report: [`seed_model`](@ref) builds a
[`Fitting.Seed`](@ref) from a structure, a measured curve and a buffer,
[`run_model`](@ref) samples it and summarizes the posterior, and
[`write_report`](@ref) writes the text report. `BAYSOL.seed_model`,
`BAYSOL.run_model` and `BAYSOL.write_report` are these functions, re-exported by the
package root.
"""
module Report

using Statistics: quantile, mean, var
using Printf: @printf, @sprintf
using StaticArrays: SVector
using ..PhysicalConstants: NS_PER_S
using ..Timing: Timing
using ..MolecularStructure: MolecularStructure
using ..SASA: PROBE_RADIUS, SHELL_N_TARGET
using ..Scattering: Scattering, B_LM_CHUNK, SHELL_THICKNESS
using ..Fitting: Fitting, DEFAULT_TEMPERATURE_C, DRO12_CONCENTRATION, DRO3_CONCENTRATION,
        DEFAULT_TARGET_ACCEPT

        """
"lo-hi" empirical quantile range (integer percentages, 0 ≤ lo < hi ≤ 100) 
used to build "quantiles"/"bounds" entries. The default "16-84" is a ±1σ-equivalent interval for a Normal. The special
case "0-0" means *no* filtering.
"""
const DEFAULT_QUANTILES = "16-84"

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

include("SeedModel.jl")
include("RunModel.jl")
include("ReportSections.jl")
include("WriteReport.jl")

export seed_model, run_model, write_report
public MAPParams, MAPResult, QuantileBounds, QuantileParams, QuantileCurves, QuantileResult

end # module
