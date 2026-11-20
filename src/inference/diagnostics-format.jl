# SPDX-License-Identifier: LGPL-3.0-or-later

using Printf: Printf
using Statistics: mean

"""
A number as `fmt` (a `printf` format of one
conversion) says, or `unavailable` if not finite.
"""
_pf(fmt::AbstractString, x::Real) =
    isfinite(x) ? Printf.format(Printf.Format(fmt), x) : "unavailable"
_pf(fmt::AbstractString, ::Missing) = "unavailable"

"A vector as `[a, b, c]`, each entry to 4 significant figures."
fmtVec(v) = "[" * join((_pf("%.4g", x) for x in v), ", ") * "]"

"The rule that opens a diagnosis."
const DIAG_RULE = "="^100

"""
The opening lines of a diagnosis: the rule and the line with the label, the size of the
problem and the c1 tolerance.

# Returns
- `Vector{String}`.

# Exceptions
- None.
"""
fmtDiagHeader(label, nQ, nAtoms, lMax, c1Tol) =
    [DIAG_RULE, "$label   nQ=$nQ  nAtoms=$nAtoms " * " lMax=$lMax  c1 tol=$c1Tol"]

"""
The line with the supports of the contrasts (`lo3`, `hi3` of δρ₃, `lo12`, `hi12` of δρ₁,₂).

# Returns
- `String`.

# Exceptions
- None.
"""
fmtDiagSupport(lo3, hi3, lo12, hi12) =
    "δρ₃ support = [" * _pf("%.4g", lo3) * ", " * _pf("%.4g", hi3) *
    "]   δρ₁,₂ support = [$lo12, $hi12]"

"The line of the MAP search (seconds, starts that reached an optimum, starts, modes)."
fmtDiagMap(seconds, nOk, nStarts, nModes, whitened) =
    _pf("MAP search: %.1f", seconds) * "s  nOk=$nOk/$nStarts  nModes=$nModes  " *
    "whitened=$whitened"

"""
The NUTS line: seconds, the step size the adaptation began from and ended at, the mean
leapfrog steps and tree depth of the draws after the warm-up, the share of them at depth 10
or more and the divergent transitions among them.

# Returns
- `String`.

# Exceptions
- None.
"""
fmtDiagNuts(seconds, ε0, ε, steps, depth, fracDeep, nDiv) =
    _pf("NUTS: %.1f", seconds) * "s  init ε=" * _pf("%.4g", ε0) * "  final ε=" *
    _pf("%.4g", ε) * "  mean nSteps=" * _pf("%.1f", steps) * " mean depth=" *
    _pf("%.2f", depth) * "  frac(depth≥10)=" * _pf("%.3f", fracDeep) * "  diverged=$nDiv"

"""
Stan's warm-up windows (initial buffer, the doubling windows, the final buffer) and the
sampling, clipped to the run (a window that does not fit a short warm-up is left out): the
`(first, last)` iteration pairs.

# Returns
- `Vector{Tuple{Int,Int}}`.

# Exceptions
- None.
"""
diagWindows(nSamples::Integer, nAdapt::Integer) = [
    (a, min(b, nSamples)) for (a, b) in (
        (1, 75), (76, 450), (451, nAdapt - 50), (nAdapt - 49, nAdapt),
        (nAdapt + 1, nSamples),
    ) if 1 ≤ a ≤ min(b, nSamples) && b ≤ nSamples + 450
]

"""
The line of the mean leapfrog steps by warm-up window; `ns` holds the
mean number of steps of every iteration (its length is `nSamples`).

# Returns
- `String`.

# Exceptions
- None.
"""
fmtDiagWindows(ns, nSamples, nAdapt) =
    "mean nSteps by window: " * join(
        (
            "[$a:$b]=" * _pf("%.0f", mean(@view ns[a:b])) for
            (a, b) in diagWindows(nSamples, nAdapt)
        ), "  ")

"The line of the mean acceptance rate and the mean |ΔH| of the draws after the warm-up."
fmtDiagAccept(accept, absdH) =
    "mean accept = " * _pf("%.3f", accept) * "   mean |ΔH| = " * _pf("%.3f", absdH)

"""
The line of one L-BFGS start of the MAP search: its number, the objective at its optimum,
the iterations and which stopping rules fired, the objective evaluations and the final
gradient (an infeasible start says so). The last two columns are the run's own records and
replace the `|∇f(tol) − ∇f(ref)|∞` and `c1` columns of `bysl fits diagnose`, which need a
second evaluation.

# Returns
- `String`.

# Exceptions
- None.
"""
fmtDiagStart(k, feasible, f, iters, gConverged, iterLimit, evals, gNorm) =
    feasible ?
    "  start $k: f=" * _pf("%.4f", f) * " iters=" * lpad(iters, 3) *
    " g_conv=$gConverged iter_limit=$iterLimit evals=$evals |∇f|∞=" * _pf("%.2e", gNorm) :
    "  start $k: infeasible (no finite optimum)"

"The line of the MAP Hessian's eigenvalues (first pass, floored at `floor`)."
fmtDiagHessian(floor, λ) =
    "MAP Hessian eigenvalues (floor $floor): pass 1 = " * fmtVec(λ)

"The line of the standard deviations of the pooled draws in w."
fmtDiagPostW(sd) =
    "post-warmup w: sd = " * fmtVec(sd) * "   (1 = the Laplace whitening is right)"

"The line of the covariance eigenvalues, skewness and ESS of the draws in w."
fmtDiagCov(eig, skew, ess) =
    "  cov(w) eigenvalues = " * fmtVec(eig) * "   skew = " * fmtVec(skew) * "   ESS = " *
    fmtVec(ess)

"The line of log π at the MAP, at the best draw and at the median draw (`d` the dimension)."
fmtDiagEll(ℓ0, best, med, d, shift) =
    "ℓπ at L-BFGS mode = " * _pf("%.4f", ℓ0) * "   best draw = " * _pf("%.4f", best) *
    "   median draw = " * _pf("%.4f", med) *
    "   ($d-D Gaussian: median ≈ mode − " * _pf("%.1f", shift) * ")"

"The line of the sampled sd in z over the Laplace σ_z."
fmtDiagSdZ(r) = "sampled sd in z / Laplace σ_z = " * fmtVec(r)

"The scales `s` of the axis ratios of `bysl fits diagnose`."
const DIAG_AXIS_S = (-10, -5, -3, -2, -1, -0.5, 0.5, 1, 2, 3, 5, 10)

"The heading of the axis ratios."
fmtDiagAxesHeading() =
    "Δf/(s²/2) along whitened axes (1 = Gaussian), s = " *
    join(("$s" for s in DIAG_AXIS_S), ",")

"The line of the ratios of one axis."
fmtDiagAxis(a, ratio) =
    "  w$a: " * join((lpad(_pf("%.3g", x), 8) for x in ratio), " ")

"The scan line of one axis (`noise` is not measured by the log: `unavailable`)."
fmtDiagScan(a, noise, f2med, f2max, f2at, c1lo, c1hi, jumps) =
    "  w$a scan: c1-tol noise=" * _pf("%.2e", noise) * "  f''(median)=" *
    _pf("%.3g", f2med) * " f''(max)=" * _pf("%.3g", f2max) * " at s=" *
    _pf("%.2f", f2at) * "  c1 range=[" * _pf("%.4f", c1lo) * "," * _pf("%.4f", c1hi) *
    "] jumps=" * (jumps < 0 ? "unavailable" : string(jumps))

"The line of the curvature bound: λ values are lower bounds of λ_max (see the log's note)."
fmtDiagCurvature(λ, εstable, ε) =
    "local λ_max(−∇²ℓπ) min/median/max = " * fmtVec(λ) * "  → stable ε < " *
    fmtVec(εstable) * " (worst, median);  adapted ε = " * _pf("%.4g", ε)

"""
The optima: the count, then a line each. `modes` holds `(f, ξ, λ, logMass)` best first
(`λ` the eigenvalues of the Hessian of −log π there).

# Returns
- `Vector{String}`.

# Exceptions
- None.
"""
function fmtDiagModes(modes)
    out = ["distinct optima: $(length(modes))"]
    isempty(modes) && return out
    for (k, m) in enumerate(modes)
        push!(out,
            "  mode $k: f=" * _pf("%.3f", m.f) * " ξ=" * fmtVec(m.ξ) * "  H-eig=" *
            fmtVec(m.λ) * "  log Laplace mass=" * _pf("%.3f", m.logMass) *
            " (Δ vs best = " * _pf("%.3g", m.logMass - first(modes).logMass) * " nats)")
    end
    return out
end

"""
The columns of the table of the chains: those of `chain_report` of `bysl fits diagnose`
(start, mode, kept draws, divergent draws and their share, step size, leapfrog steps,
acceptance, mean log π) with the warm-up's divergent draws, the spread of the energy
error, the share of trees at depth 10, BFMI, the share of draws with c1 at a bound, and the
gradient evaluations and the non-finite ones of the chain.
"""
const CHAIN_COLUMNS = [
    "chain", "start σ", "mode", "pooled", "kept", "div", "div%", "warm-up div",
    "warm-up div%", "ε", "steps", "accept", "mean log π", "energy error sd", "depth≥10",
    "BFMI", "c1 at bound", "gradient evals", "non-finite", "note",
]

_ci(x::Integer) = string(x)
_ci(::Missing) = "unavailable"

"""
The cells of one chain; `r` is `(; k, start, mode, pooled, nPost, div, warmDiv, warmN, ε,
steps, accept, logπ, eSd, deep, bfmi, pin, grads, bad, note)`. A quantity the chain did not
produce (it stopped, kept no draws, was not pooled) is `missing` or `NaN` and is written as
`unavailable`, never as a zero; the percentages are of `nPost` and `warmN` draws.

# Returns
- `Vector{String}`, one per column of [`CHAIN_COLUMNS`](@ref).

# Exceptions
- None.
"""
fmtChainRow(r) = [
    string(r.k), _pf("%+.2f", r.start), string(r.mode), r.pooled ? "yes" : "no",
    string(r.nPost), _ci(r.div), _pf("%.1f", 100r.div / r.nPost), _ci(r.warmDiv),
    _pf("%.1f", 100r.warmDiv / r.warmN), _pf("%.4f", r.ε), _pf("%.1f", r.steps),
    _pf("%.3f", r.accept), _pf("%.2f", r.logπ), _pf("%.3g", r.eSd), _pf("%.3f", r.deep),
    _pf("%.3f", r.bfmi), _pf("%.3f", r.pin), _ci(r.grads), _ci(r.bad), r.note,
]
