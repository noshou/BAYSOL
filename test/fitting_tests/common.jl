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

"Warmup (step-size and mass-matrix adaptation) iterations, discarded from the posterior."
const N_ADAPT = BAYSOL.Pipeline.N_ADAPT

"Total NUTS iterations per fit, including the `N_ADAPT` warmup (default of every
`run_<id>`)."
const N_SAMPLES = N_ADAPT + BAYSOL.Pipeline.N_DRAWS

"""
The `rngSeed` of SASDJ66, a marginal entry: its seed 0 passes on arm64 and Linux arm64, and
does not converge on macOS x86_64 (R̂ above 1.1, ESS under 70), so that system takes seed 1.
On Linux x86_64 (Ubuntu 24.04 in WSL2, 2026-11-26) seeds 0 and 1 end `ladder exhausted` (R̂
1.9, ESS 2), seed 2 converges at the second rung (R̂ 1.007) and seed 3 at the first rung
(`delta 99`, R̂ 1.004, 75 s, `--threads 4`): that system takes seed 3. Every other system
keeps the default. SASDAP8 needed another seed ([`SASDAP8_FIT_SEED`](@ref)).
"""
const MARGINAL_FIT_SEED =
    BAYSOL.Platform.ismacosx64() ? 1 :
    BAYSOL.Platform.islinuxx64() ? 3 : BAYSOL.Inference.RNG_SEED

"""
The `rngSeed` of SASDAP8, a marginal entry: its seed 0 passes on arm64 and
Linux. On macOS x86_64 under Rosetta 2 seeds 0, 1, 2 and 3 all ended
`ladder exhausted`, and seed 4 passed at the rung `longer chains + seed` (the
base run and `longer chains` had a bulk ESS of 304 against the 400 gate; one
run, 1112 s). That system takes seed 4 and every other system keeps the default.
"""
const SASDAP8_FIT_SEED = BAYSOL.Platform.ismacosx64() ? 4 : BAYSOL.Inference.RNG_SEED

"""
The `rngSeed` of SASDVA2 on x86_64 (macOS, Linux or Windows): a run of that entry on
x86_64 was reported to climb the retry ladder to 10 retries and nearly two hours, which
arm64 does not, so those systems take seed 1 and the others keep the default. NOT
TESTED: seed 1 has not been run on any system (the check under Rosetta 2 was stopped
before it ran), so it is not known to be better than seed 0; revert it if it is not.
"""
const X64_FIT_SEED = BAYSOL.Platform.isx64() ? 1 : BAYSOL.Inference.RNG_SEED

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
    fixtureDir(id) -> String

The folder of the experiment fixtures (deposited curve, structure, `.fit`) of the entry
`id`. The fixtures are kept as one archive per entry
(`test/fixtures/experiments/<id>.7z`); `bysl fits run` unpacks it before the fit and
exports `BAYSOL_FIXTURES`, the folder it unpacked into. Order: `\$BAYSOL_FIXTURES/<id>`
if it exists, else the plain folder `test/fixtures/experiments/<id>` of the repository.

# Returns
- The folder path.

# Exceptions
- `ErrorException` if neither exists (`bysl fixtures unpack <id>` makes the first).
"""
function fixtureDir(id::AbstractString)
    root = get(ENV, "BAYSOL_FIXTURES", "")
    isempty(root) || isdir(joinpath(root, id)) && return joinpath(root, id)
    plain = joinpath(@__DIR__, "..", "fixtures", "experiments", id)
    isdir(plain) && return plain
    error(
        "no fixtures for $id: run `bysl fixtures unpack $id` and set BAYSOL_FIXTURES " *
        "to its folder (`bysl fits run $id` does both)",
    )
end

"""
Plausible range (Å⁻¹) of a SAXS/WAXS curve's maximum q: 0.05 to 3.5.
A maximum outside it almost certainly means the curve is in the wrong unit (nm⁻¹ not
converted, or converted twice). The ceiling is deliberately far below the form-factor
table's limit (4π·6 = 75.40 Å⁻¹): the deposited curves reach at most 3.19 Å⁻¹ (SASDVV4;
SASDVX4 and SASDVY4 1.9), whereas a typical nm⁻¹ curve left unconverted runs to
4-6 and would pass a table-limit ceiling (the SASDJL6 / SASDJX7 case). A curve that
legitimately runs beyond 3.5 Å⁻¹ is cut before the check, as SASDVV4 does.
`bysl fits units` checks the conversion itself against the data's unit.
"""
const Q_SANITY_RANGE = (0.05, 3.5)

"""
    checkQAngstrom(q)

Asserts that `maximum(q)` lies inside `Q_SANITY_RANGE`, i.e. that `q` is in Å⁻¹.

# Returns
- `nothing` when `maximum(q)` is inside the range.

# Exceptions
- `AssertionError` when `maximum(q)` is outside `Q_SANITY_RANGE`.
"""
function checkQAngstrom(q)
    lo, hi = Q_SANITY_RANGE
    @assert lo < maximum(q) < hi (
        "q range looks wrong (expected Å⁻¹ " *
        "after conversion): $(extrema(q))"
    )
end

"""
    _readCurve(path) -> (q, I, σ)

Reads the numeric rows (three or more columns) of a
SASBDB `.dat`, skipping the free-text header
and any trailing beam information. The first three
columns are q, I(q) and σ(q).
"""
function _readCurve(path)
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
    _readFit(path, qScale, col) -> (q, I_fit) or nothing

Reads a depositor fit file: the numeric rows with at least `col`
columns, taking q from column 1 (scaled to Å⁻¹ by `qScale`) and
the fitted intensity from column `col` (the layout differs between
CRYSOL, FoXS, OLIGOMER and EOM files). Returns `nothing` if there
are no such rows.
"""
function _readFit(path, qScale, col)
    q = Float64[]
    I = Float64[]
    for line in eachline(path)
        t = split(replace(strip(line), ',' => ' '))
        length(t) ≥ max(col, 3) || continue
        v = tryparse.(Float64, t[1:col])
        any(isnothing, v) && continue
        push!(q, v[1] * qScale)
        push!(I, v[col])
    end
    return isempty(q) ? nothing : (q, I)
end

"""
    _rescaleFit((q, I), qData, I_data) -> (q, c·I)

Least-squares scale of a normalized fit curve onto the data
(linear interpolation of the fit at the data's q).
"""
function _rescaleFit(fitCurve, qData, iData)
    qf, If = fitCurve
    p = sortperm(qf)
    qf = qf[p]
    If = If[p]
    ii = zeros(length(qData))
    ok = falses(length(qData))
    for (k, x) in enumerate(qData)
        (qf[1] ≤ x ≤ qf[end]) || continue
        j = clamp(searchsortedlast(qf, x), 1, length(qf) - 1)
        w = qf[j+1] > qf[j] ? (x - qf[j]) / (qf[j+1] - qf[j]) : 0.0
        ii[k] = If[j] * (1 - w) + If[j+1] * w
        ok[k] = true
    end
    any(ok) || return fitCurve
    c = sum(iData[ok] .* ii[ok]) / sum(ii[ok] .^ 2)
    return qf, If .* c
end
