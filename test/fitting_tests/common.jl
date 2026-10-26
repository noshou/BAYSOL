# SPDX-License-Identifier: LGPL-3.0-or-later

# Shared constants and helpers for the SASBDB fitting scripts.
# Included by each script so copies cannot drift apart. A script
# that deliberately deviates from one of these keeps its own literal
# inline, with a comment saying why.

# ---------------------------------------------------------------------------
#                              Physical constants
# ---------------------------------------------------------------------------

# h·c (eV·Å, for photon energy from wavelength) and the nm⁻¹ → Å⁻¹
# conversion come from the package, so the scripts and BAYSOL share
# one definition.
using BAYSOL.PhysicalConstants: HC_EV_ANGSTROM, NM_INV_PER_ANGSTROM_INV

# ---------------------------------------------------------------------------
#                                   Sampler
# ---------------------------------------------------------------------------

"Total NUTS iterations per fit, including the `N_ADAPT`
warmup (default of every `run_<id>`)."
const N_SAMPLES = BAYSOL.Pipeline.DEFAULT_N_SAMPLES

"Warmup (step-size and mass-matrix adaptation) iterations, discarded from the posterior."
const N_ADAPT = BAYSOL.Pipeline.DEFAULT_N_ADAPT

"RNG seed passed to `Random.seed!` before each fit."
const SAMPLER_SEED = 0

# ---------------------------------------------------------------------------
#                     Solution-condition uncertainty defaults
# ---------------------------------------------------------------------------

"σ of the buffer pH when the source gives none: ±0.1 is a
typical benchtop pH-meter precision."
const PH_METER_SIGMA = 0.1

"""
Relative σ of a macromolecule's molarity from a stated
mg/mL concentration: 5 %, typical of A280/mg-ml determination.
"""
const MOLARITY_REL_SIGMA = 0.05

# ---------------------------------------------------------------------------
#                                 Data loading
# ---------------------------------------------------------------------------

"""
Plausible range (Å⁻¹) of a SAXS curve's maximum q.
A maximum outside it almost certainly means the
curve is still in nm⁻¹ (or was converted twice);
see `check_q_angstrom`.
"""
const Q_SANITY_RANGE = (0.05, 2.0)

"""
    check_q_angstrom(q)

Asserts that `maximum(q)` lies inside `Q_SANITY_RANGE`, i.e. that `q` is in Å⁻¹.
"""
function check_q_angstrom(q)
    lo, hi = Q_SANITY_RANGE
    @assert lo < maximum(q) < hi (
        "q range looks wrong (expected Å⁻¹ " *
        "after conversion): $(extrema(q))"
    )
end

"""
    _read_curve(path) -> (q, I, σ)

Reads the numeric rows (three or more columns) of a
SASBDB `.dat`, skipping the free-text header
and any trailing beam information. The first three
columns are q, I(q) and σ(q).
"""
function _read_curve(path)
    q = Float64[]
    I = Float64[]
    σ = Float64[]
    for line in eachline(path)
        t = split(replace(strip(line), ',' => ' '))
        length(t) ≥ 3 || continue
        v = tryparse.(Float64, t[1:3])
        any(isnothing, v) && continue
        push!(q, v[1])
        push!(I, v[2])
        push!(σ, v[3])
    end
    return q, I, σ
end

"""
    _read_fit(path, q_scale, col) -> (q, I_fit) or nothing

Reads a depositor fit file: the numeric rows with at least `col`
columns, taking q from column 1 (scaled to Å⁻¹ by `q_scale`) and
the fitted intensity from column `col` (the layout differs between
CRYSOL, FoXS, OLIGOMER and EOM files). Returns `nothing` if there
are no such rows.
"""
function _read_fit(path, q_scale, col)
    q = Float64[]
    I = Float64[]
    for line in eachline(path)
        t = split(replace(strip(line), ',' => ' '))
        length(t) ≥ max(col, 3) || continue
        v = tryparse.(Float64, t[1:col])
        any(isnothing, v) && continue
        push!(q, v[1] * q_scale)
        push!(I, v[col])
    end
    return isempty(q) ? nothing : (q, I)
end

"""
    _rescale_fit((q, I), q_data, I_data) -> (q, c·I)

Least-squares scale of a normalized fit curve onto the data
(linear interpolation of the fit at the data's q).
"""
function _rescale_fit(fit_curve, q_data, I_data)
    qf, If = fit_curve
    p = sortperm(qf)
    qf = qf[p]
    If = If[p]
    Ii = zeros(length(q_data))
    ok = falses(length(q_data))
    for (k, x) in enumerate(q_data)
        (qf[1] ≤ x ≤ qf[end]) || continue
        j = clamp(searchsortedlast(qf, x), 1, length(qf) - 1)
        w = qf[j+1] > qf[j] ? (x - qf[j]) / (qf[j+1] - qf[j]) : 0.0
        Ii[k] = If[j] * (1 - w) + If[j+1] * w
        ok[k] = true
    end
    any(ok) || return fit_curve
    c = sum(I_data[ok] .* Ii[ok]) / sum(Ii[ok] .^ 2)
    return qf, If .* c
end
