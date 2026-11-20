# SPDX-License-Identifier: LGPL-3.0-or-later

# `bysl fits units`: the guard against a curve read in the wrong angular unit (the
# SASDJL6 / SASDJX7 case: a nm⁻¹ curve fitted as Å⁻¹, or the reverse). For each fitting
# script that reads its q from the deposited `.dat`, the unit of the data is decided from
# the file itself and compared with what the script does (divide by
# `NM_INV_PER_ANGSTROM_INV` or not).
module Units

using ..Common
using ..Fixtures

const WHO = "bysl fits units"

const USAGE = """
Checks that every fitting script converts the deposited curve's q to Å⁻¹ exactly when
the data are in nm⁻¹: the unit comes from the `.dat` footer (`angular-unit`), and where
the footer has none, from the depositor's `.fit`: its data q equal to the `.dat`'s q mean
Å⁻¹, equal to the `.dat`'s divided by 10 mean nm⁻¹ (else the ratio of the largest q,
about 10 or 1). Fails (status 1) on a
script that disagrees, or whose footer and `.fit` disagree.

    bysl fits units [ID ...]

    ID          fitting-test folders (default: every one)
"""

# The ratio of the `.dat`'s largest q to the `.fit`'s that counts as nm⁻¹ (10) or Å⁻¹ (1).
const RATIO_NM = (7.0, 14.0)
const RATIO_ANGSTROM = (0.7, 1.4)

"""
    footer_unit(text) -> Union{Symbol,Nothing}

The unit named by the `angular-unit:` line of a `.dat` footer: `:nm` (nanometer, `1/nm`),
`:angstrom` (angstrom, `1/A`), or `nothing` when there is no such line or it is not one
of these.

# Returns
- `:nm`, `:angstrom` or `nothing`.

# Exceptions
- None.
"""
function footer_unit(text::AbstractString)
    m = match(r"^angular-unit:\s*(.*?)\s*$"mi, text)
    m === nothing && return nothing
    v = lowercase(m[1])
    occursin(r"nano|nm", v) && return :nm
    occursin(r"angstr|ångstr|å|^1/a$|^a$", v) && return :angstrom
    return nothing
end

"""
    max_q(text) -> Union{Float64,Nothing}

The largest first-column value among the numeric rows (three or more numbers) of a `.dat`
or `.fit` text; `nothing` when there is none.

# Returns
- The largest q, or `nothing`.

# Exceptions
- None.
"""
function max_q(text::AbstractString)
    best = nothing
    for line in split_lines(text)
        f = split(strip(line))
        length(f) >= 3 || continue
        q = tryparse(Float64, f[1])
        (q === nothing || any(x -> tryparse(Float64, x) === nothing, f[1:3])) && continue
        best === nothing || q > best ? (best = q) : nothing
    end
    return best
end

# The q of the data rows (second column not zero) of a `.fit`, and of every numeric row
# of a `.dat`, rounded to 5 significant digits so the two files' formats compare equal.
function _qset(text, rowsOnly)
    out = Float64[]
    for line in split_lines(text)
        f = split(strip(line))
        length(f) >= 3 || continue
        v = tryparse.(Float64, f[1:3])
        any(isnothing, v) && continue
        rowsOnly && v[2] == 0 && continue
        push!(out, round(v[1]; sigdigits = 5))
    end
    return out
end

# The unit by matching the `.fit`'s data q against the `.dat`'s q (equal: Å⁻¹; the `.dat`'s
# divided by 10 equal: nm⁻¹), which holds even when the depositor fitted only part of the
# range; `nothing` unless one of the two matches at least half of them.
function _matched_unit(dat, fit)
    fq = _qset(fit, true)
    isempty(fq) && return nothing
    dq = _qset(dat, false)
    plain = Set(dq)
    scaled = Set(round.(dq ./ 10; sigdigits = 5))
    a = count(in(plain), fq) / length(fq)
    n = count(in(scaled), fq) / length(fq)
    a >= 0.5 && a >= n && return :angstrom
    n >= 0.5 && return :nm
    return nothing
end

"""
    unit_of(dat, fit) -> (unit, how, conflict)

The angular unit of the data. `dat` is the `.dat` text and `fit` the `.fit` text (or
`nothing`). The footer wins; `how` is `:footer`, `:ratio` or `:unknown`. `conflict` is a
message when both exist and disagree (a footer saying one unit while the `.fit` ratio says
the other), else `nothing`.

# Returns
- A tuple `(unit::Union{Symbol,Nothing}, how::Symbol, conflict::Union{String,Nothing})`.

# Exceptions
- None.
"""
function unit_of(dat::AbstractString, fit)
    byFooter = footer_unit(dat)
    byRatio = nothing
    ratio = nothing
    if fit !== nothing
        byRatio = _matched_unit(dat, fit)
        a, b = max_q(dat), max_q(fit)
        if byRatio === nothing && a !== nothing && b !== nothing && b > 0
            ratio = a / b
            ratio >= RATIO_NM[1] && ratio <= RATIO_NM[2] && (byRatio = :nm)
            ratio >= RATIO_ANGSTROM[1] && ratio <= RATIO_ANGSTROM[2] &&
                (byRatio = :angstrom)
        end
    end
    conflict =
        byFooter !== nothing && byRatio !== nothing && byFooter != byRatio ?
        "the footer says $byFooter but the depositor's .fit says $byRatio" :
        nothing
    byFooter !== nothing && return (byFooter, :footer, conflict)
    byRatio !== nothing && return (byRatio, :ratio, conflict)
    return (nothing, :unknown, conflict)
end

"""
    script_converts(text) -> Union{Bool,Nothing}

Whether a fitting script divides the curve's q by `NM_INV_PER_ANGSTROM_INV` (a code line
`qvals... = qvals... ./ NM_INV_PER_ANGSTROM_INV`; comments do not count). `nothing` when
the script does not read its q from a `.dat` (`_readCurve(_DATA_PATH)` is absent: the
curve comes from the `.fit`), so there is nothing to check.

# Returns
- `true`, `false` or `nothing`.

# Exceptions
- None.
"""
function script_converts(text::AbstractString)
    code = join((replace(l, r"#.*$" => "") for l in split_lines(text)), "\n")
    occursin("_readCurve(", code) || return nothing
    return occursin(r"qvals\w*\s*=\s*qvals\w*\s*\./\s*NM_INV_PER_ANGSTROM_INV", code)
end

"""
    check_script(text, dat, fit) -> Union{String,Nothing}

The problem of one script, or `nothing` when it is right or cannot be judged (it reads q
from the `.fit`, or the unit of the data cannot be told).

# Returns
- A one-line message, or `nothing`.

# Exceptions
- None.
"""
function check_script(text::AbstractString, dat::AbstractString, fit)
    converts = script_converts(text)
    converts === nothing && return nothing
    unit, how, conflict = unit_of(dat, fit)
    conflict === nothing || return conflict
    unit === nothing && return nothing
    unit == :nm && !converts &&
        return "data are in nm⁻¹ ($how) but the script does not divide by " *
               "NM_INV_PER_ANGSTROM_INV"
    unit == :angstrom && converts &&
        return "data are in Å⁻¹ ($how) but the script divides by NM_INV_PER_ANGSTROM_INV"
    return nothing
end

# The fixture id (`fixtureDir("ID")`), the `.dat` and the first `.fit` a script names.
function _script_files(text)
    id = match(r"fixtureDir\(\"(SASD\w+)\"\)", text)
    dat = match(r"\"experimental_data\",\s*\"([^\"]+\.dat)\"", text)
    fit = match(r"\"([^\"/]+\.fit)\"", text)
    return (id === nothing ? nothing : id[1], dat === nothing ? nothing : dat[1],
        fit === nothing ? nothing : fit[1])
end

"""
    check_entry(id) -> Vector{Tuple{String,String}}

Checks every script `<id>*.jl` of the folder; returns `(script, problem)` for each one
that is wrong. Reads the `.dat` and the `.fit` out of the entry's fixtures (unpacked on
demand and removed again).

# Returns
- The list of problems (empty when all is right).

# Exceptions
- `ErrorException` when the fixtures of a script's entry do not exist.
"""
function check_entry(id::AbstractString)
    out = Tuple{String,String}[]
    dir = in_root(FIT_DIR, id)
    for f in sort(readdir(dir))
        endswith(f, ".jl") || continue
        text = read(joinpath(dir, f), String)
        script_converts(text) === nothing && continue
        fid, datName, fitName = _script_files(text)
        (fid === nothing || datName === nothing) && continue
        Fixtures.FixtureStore.with_fixture(fid) do fx
            dat = read(joinpath(fx, "experimental_data", datName), String)
            fitPath = fitName === nothing ? nothing : joinpath(fx, fitName)
            fit = fitPath !== nothing && isfile(fitPath) ? read(fitPath, String) : nothing
            msg = check_script(text, dat, fit)
            msg === nothing || push!(out, (f, msg))
        end
    end
    return out
end

"`bysl fits units`: the check over the named fitting tests (default all); exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    opts = filter(startswith("-"), argv)
    isempty(opts) || fail(WHO, "unknown option $(first(opts))")
    isempty(argv) || check_folders(WHO, argv, false)
    todo = isempty(argv) ? ids() : argv
    bad = 0
    for id in todo
        try
            for (f, msg) in check_entry(id)
                bad += 1
                println("  ", f, ": ", msg)
            end
        catch e
            e isa InterruptException && rethrow()
            bad += 1
            println("  ", id, ": cannot check: ", sprint(showerror, e))
        end
    end
    println(
        bad == 0 ? "q units: all $(length(todo)) fitting tests agree with their data" :
        "q units: $bad problem(s)",
    )
    return bad == 0 ? 0 : 1
end

end
