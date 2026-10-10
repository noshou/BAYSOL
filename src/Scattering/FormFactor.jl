# SPDX-License-Identifier: LGPL-2.1-or-later

# X-ray atomic scattering factors, f(q, E) = f0(s) + f1(E) + i·f2(E),
# from the bundled `form_factors.sqlite3` (Waasmaier-Kirfel f0,
# Chantler FFAST f1/f2). Included into Scattering; see the
# FormFactor.jl section of its README.

"Raised on any failure building or querying form factors."
struct FormFactorError <: Exception
    msg::String
end
Base.showerror(io::IO, e::FormFactorError) = print(io, "FormFactorError: ", e.msg)

"Per-batch form factors: tbl ion => row aligned
to qmp (qval => index), plus a build log."
struct FF
    tbl::Dict{String,Vector{ComplexF64}}
    qmp::Dict{Float64,Int}
    log::Vector{String}
end

# ---------------------------------------------------------------------------
# Bundled tables, read once on first use.
# ---------------------------------------------------------------------------

"One element's Chantler grid. e is strictly
increasing; all three are the same length."
struct _Chantler
    e  :: Vector{Float64}
    f1 :: Vector{Float64}
    f2 :: Vector{Float64}
end

"""
The bundled tables, immutable once built: `wk` the Waasmaier-Kirfel coefficients
(c, a1..a5, b1..b5) by ion key, `ch` the Chantler grids by element.
"""
struct _FFTables
    wk::Dict{String,NTuple{11,Float64}}
    ch::Dict{String,_Chantler}
end

"Path to the bundled database."
_dbpath() = joinpath(@__DIR__, "form_factors.sqlite3")
include_dependency(_dbpath())

"""
Read `form_factors.sqlite3` into an [`_FFTables`](@ref).
"""
function _read_tables()::_FFTables
    wk = Dict{String,NTuple{11,Float64}}()
    ch = Dict{String,_Chantler}()
    db = SQLite.DB(_dbpath())
    try
        for r in DBInterface.execute(
            db,
            "SELECT ion,c,a1,a2,a3,a4,a5,b1,b2,b3,b4,b5 FROM waasmaier",
        )
            wk[r.ion] = (
                r.c,
                r.a1,
                r.a2,
                r.a3,
                r.a4,
                r.a5,
                r.b1,
                r.b2,
                r.b3,
                r.b4,
                r.b5,
            )
        end
        for r in DBInterface.execute(
            db,
            "SELECT element,energy,f1,f2 FROM chantler",
        )
            ch[r.element] = _Chantler(
                collect(reinterpret(Float64, r.energy)),
                collect(reinterpret(Float64, r.f1)),
                collect(reinterpret(Float64, r.f2)),
            )
        end
    finally
        DBInterface.close!(db)
    end
    isempty(wk) && throw(
        FormFactorError("form_factors.sqlite3 has no waasmaier rows"),
    )
    isempty(ch) && throw(
        FormFactorError("form_factors.sqlite3 has no chantler rows"),
    )
    return _FFTables(wk, ch)
end


# ---------------------------------------------------------------------------
# f0: Waasmaier-Kirfel
# ---------------------------------------------------------------------------

"""
Non-resonant atomic form factor c + `Σ_{i=1..5}` `a_i`
exp(-`b_i` s²) for species (an ion key like "fe3+" or
a bare element like "fe"), at s = q/(4π) in Å⁻¹.
"""
function f0(species::AbstractString, s::Real)::Float64
    p = get(force(_TABLES).wk, species, nothing)
    p === nothing && throw(
        FormFactorError("no Waasmaier-Kirfel entry for \"$species\""),
    )
    sf = Float64(s)
    (0.0 ≤ sf ≤ WK_S_MAX) ||
        throw(
            FormFactorError(
                "s = $sf outside the Waasmaier-Kirfel range [0, $WK_S_MAX]",
            ),
        )
    r = p[1]
    # exp(((-b)*s)*s), not exp(-(b*s^2)): this is the association NumPy uses
    # for -e*q*q, and matching it makes the result bit-identical to the
    # reference implementation rather than 1-3 ulp away on some species.
    @inbounds for i in 1:5
        r += p[1+i] * exp(((-p[6+i]) * sf) * sf)
    end
    return r
end

# ---------------------------------------------------------------------------
# f1/f2: Chantler
# ---------------------------------------------------------------------------

"""
The 7-point interpolation window around grid index j (the last point at or
below the requested energy), clamped to 1:n.

Deliberately reproduces the reference implementation's asymmetric bounds
(max(1, j-3) … min(n, j+3)) rather than a symmetric window: the spline is
fitted to these points and nothing else, so widening it would shift every
interpolated value.
"""
_window(n::Int, j::Int)::UnitRange{Int} = max(1, j-3):min(n, j+3)

"""
Interpolating cubic spline through every (x, y) with not-a-knot end
conditions, evaluated at t.

Not-a-knot (rather than natural or clamped) is what the reference
implementation uses; the choice is visible in the result near an absorption
edge, where the grid is dense and the curvature large.
"""
function _notaknot(
    x::AbstractVector{Float64},
    y::AbstractVector{Float64},
    t::Float64,
)::Float64
    n = length(x)
    n ≥ 4 || throw(FormFactorError("_notaknot needs at least 4 points, got $n"))
    h = diff(x)
    A = zeros(Float64, n, n)
    b = zeros(Float64, n)
    @inbounds for i in 2:(n-1)
        A[i, i-1] = h[i-1]
        A[i, i]   = 2 * (h[i-1] + h[i])
        A[i, i+1] = h[i]
        b[i]      = 3 * ((y[i+1] - y[i]) / h[i] - (y[i] - y[i-1]) / h[i-1])
    end

    # not-a-knot: the third derivative is continuous across the second and
    # second-to-last knots, i.e. the first two (and last two) cubics are one cubic.
    A[1, 1]   = h[2]
    A[1, 2]   = -(h[1] + h[2])
    A[1, 3]   = h[1]
    A[n, n-2] = h[n-1]
    A[n, n-1] = -(h[n-2] + h[n-1])
    A[n, n]   = h[n-2]
    c         = A \ b
    i         = clamp(searchsortedlast(x, t), 1, n - 1)
    dx        = t - x[i]
    bi        = (y[i+1] - y[i]) / h[i] - h[i] * (2c[i] + c[i+1]) / 3
    di        = (c[i+1] - c[i]) / (3 * h[i])
    return y[i] + bi * dx + c[i] * dx^2 + di * dx^3
end

"""
Anomalous corrections (f1, f2) for a bare element at energy in eV.

f1 comes from a cubic spline over the local 7-point window; f2 from linear
interpolation in log-log space. The two differ because f2 spans orders of
magnitude across an absorption edge while f1 changes sign through one.

f1 is stored as `f1_FFAST` - Z + `f_rel`(3/5 CL) + `f_NT`, so it is the
correction alone (f = f0 + f1 + i f2, with no separate Z), and it tends to
a small non-zero constant rather than to 0 at high energy.
"""
function f1f2(element::AbstractString, energy::Real)::Tuple{Float64,Float64}
    ch = get(force(_TABLES).ch, element, nothing)
    ch === nothing && throw(
        FormFactorError("no Chantler data for element \"$element\""),
    )
    E       = Float64(energy)
    errmsg1 = "energy $E eV outside the Chantler range"
    errmsg2 = " [$(ch.e[1]), $(ch.e[end])] for \"$element\""
    errmsg  = errmsg1 * errmsg2
    (ch.e[1] ≤ E ≤ ch.e[end]) || throw(FormFactorError(errmsg))
    n = length(ch.e)
    w = _window(n, searchsortedlast(ch.e, E))
    x = view(ch.e, w)

    a = _notaknot(x, view(ch.f1, w), E)

    # f2 spans decades and is positive,
    # so it is interpolated in log-log space;
    # the clamp keeps the log finite where the
    # table stores an exact zero.
    y2 = view(ch.f2, w)
    j = clamp(searchsortedlast(x, E), 1, length(x) - 1)
    lo = abs(y2[j]) < F2_LOG_FLOOR ? F2_LOG_FLOOR : y2[j]
    hi = abs(y2[j+1]) < F2_LOG_FLOOR ? F2_LOG_FLOOR : y2[j+1]
    lx1, lx2 = log(x[j]), log(x[j+1])
    ly1, ly2 = log(lo), log(hi)
    slope = (ly2 - ly1) / (lx2 - lx1)
    b = exp(slope * (log(E) - lx1) + ly1)
    return (a, b)
end

# ---------------------------------------------------------------------------
# Tiering + the generic functions
# ---------------------------------------------------------------------------

"Strip a trailing charge: \"fe3+\" -> \"fe\".
Mirrors AtomicRadii's ion-key grammar."
_element(species::AbstractString)::String =
    String(replace(species, r"[0-9]*[+-]+$" => ""))

"""
Which formula applies: :dummy (no f0 data at all
ie not a real scatterer), :`f0_only` (has f0 but
no anomalous data for its element), or :full.

The energy check is separate, in [`compute_form_factors`](@ref),
because it is the only part that depends on the photon energy.
"""
function _tier(species::AbstractString)::Symbol
    t = force(_TABLES)
    haskey(t.wk, species) || haskey(t.wk, _element(species)) || return :dummy
    haskey(t.ch, _element(species)) || return :f0_only
    return :full
end

"""
Form factors for a batch of ions at one energy (eV) over a q grid (Å⁻¹); one
row per unique ion, aligned to the returned container's q index.

Ions are deduplicated, preserving first-seen order. An ion with no f0 data is
a dummy site: it is dropped from the table and logged, rather than erroring.

The build log carries one line per ion that did not resolve in full:

    -   `DUMMY   <ion>`   -- no f0 data; dropped from the table.
    -   `F0-ONLY <ion>`   -- no anomalous data for this element, or energy outside
        its tabulated range; the row is real-valued.
    -   `NEUTRAL <ion>`   -- no entry for this charge state, so the neutral atom's
        f0 was used. The predecessor implementation made this substitution
        silently; it is logged here because it is a real approximation (fe4+
        scattering as 26 electrons rather than 22), not a formatting detail.

# Arguments
- `ions`: vector of ion strings, e.g. ["fe3+", "o2-"].
- `energy`: photon energy in eV; must be > 0.
- `qvals`: vector of q values in Å⁻¹; all must be ≥ 0.
"""
function compute_form_factors(
    ions::AbstractVector{<:AbstractString},
    energy::Real,
    qvals::AbstractVector{<:Real},
)::FF
    isempty(ions) && throw(
        FormFactorError("compute_form_factors: ions must not be empty"),
    )
    energy > 0 || throw(
        FormFactorError("compute_form_factors: energy must be > 0"),
    )
    isempty(qvals) && throw(
        FormFactorError("compute_form_factors: qvals must not be empty"),
    )
    any(<(0), qvals) && throw(
        FormFactorError("compute_form_factors: qvals must be ≥ 0"),
    )
    t = force(_TABLES)

    E  = Float64(energy)
    qs = collect(Float64, qvals)
    ss = qs ./ (4π)

    tbl = Dict{String,Vector{ComplexF64}}()
    log = String[]

    # E is fixed for the whole call, so the anomalous pair depends only on the
    # element; memoize it so fe, fe3+, fe2+ share one spline evaluation.
    f1f2_cache = Dict{String,NTuple{2,Float64}}()
    for ion in unique(ions)
        species = String(ion)
        tier = _tier(species)
        if tier === :dummy
            push!(log, "DUMMY   " * species)
            continue
        end

        # An unknown charge state falls back to the neutral atom.
        key = haskey(t.wk, species) ? species : _element(species)
        key == species || push!(log, "NEUTRAL " * species)

        el = _element(species)
        anomalous = tier === :full
        if anomalous
            ch = t.ch[el]
            anomalous = ch.e[1] ≤ E ≤ ch.e[end]
        end

        if anomalous
            a, b = get!(@closure(() -> f1f2(el, E)), f1f2_cache, el)
            tbl[species] = ComplexF64[f0(key, s) + a + b * im for s in ss]
        else
            push!(log, "F0-ONLY " * species)
            tbl[species] = ComplexF64[f0(key, s) for s in ss]
        end
    end

    qmp = Dict{Float64,Int}()
    @inbounds for i in eachindex(qs)
        qmp[qs[i]] = i
    end
    return FF(tbl, qmp, log)
end

"""
Build an [`FF`](@ref) container for ions at one energy (eV) over the qvals
(Å⁻¹) grid. Thin wrapper over [`compute_form_factors`](@ref).

# Arguments
- `energy`: photon energy in eV.
- `ions`: vector of ion strings.
- `qvals`: vector of q values in Å⁻¹.
"""
form_factor_table(energy::Real, ions, qvals)::FF =
    compute_form_factors(collect(String, ions), energy, collect(Float64, qvals))

"""
Construction-time diagnostics for the container t built by
[`form_factor_table`](@ref): one line per ion that did not resolve in full,
in the order encountered. Empty when every ion resolved.

# Arguments
- `t`: form-factor container from [`form_factor_table`](@ref).
"""
form_factor_log(t::FF)::Vector{String} = t.log

"""
t's rows selected by ions, columns selected by qvals, as a
(length(ions), length(qvals)) matrix: row i is the row for ions[i], columns
aligned to qvals in input order. Pass the per-atom ion vector and the result
is exactly the `f_atoms` matrix [`BAYSOL.Scattering.compute_B_lm`](@ref) takes.

Every qval must be a grid point of t (matched exactly, not to a tolerance)
and every ion must be present in t; either violation throws
[`FormFactorError`](@ref) rather than returning a silently wrong row.

# Arguments
- `t`: container from [`form_factor_table`](@ref).
- `ions`: ion strings, one per output row.
- `qvals`: q values in Å⁻¹; each must match a grid point of t exactly.
"""
function form_factors(
    t::FF, ions::AbstractVector{<:AbstractString}, qvals::AbstractVector{<:Real},
)::Matrix{ComplexF64}
    cols = Vector{Int}(undef, length(qvals))
    @inbounds for k in eachindex(qvals)
        q = Float64(qvals[k])
        i = get(t.qmp, q, 0)
        i == 0 && throw(
            FormFactorError(
                "q = $q is not a grid point of this form-factor table",
            ),
        )
        cols[k] = i
    end
    out = Matrix{ComplexF64}(undef, length(ions), length(qvals))
    n = length(ions)
    # every row is independent: blocks of rows are filled on the Julia threads
    tmap_blocks(n, ATOM_BLOCK; threaded = n ≥ ATOM_PARALLEL_MIN) do blk
        @inbounds for r in blk
            row = get(t.tbl, String(ions[r]), nothing)
            row === nothing &&
                throw(
                    FormFactorError(
                        "ion \"$(ions[r])\" is not in this form-factor table",
                    ),
                )
            @fastmath @simd for k in eachindex(cols)
                out[r, k] = row[cols[k]]
            end
        end
    end
    return out
end
