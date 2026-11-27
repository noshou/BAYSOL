# SPDX-License-Identifier: LGPL-3.0-or-later

# `bysl fits radius`: the excluded-volume radius r₀ of each fit, BAYSOL's against the
# reference tool's. BAYSOL's r₀ is `c1 · rM`: the MAP `c1` of the run's LOG times the mean
# atomic radius rM of the hydrogenated structure (`seed.fw.rM`, which needs BAYSOL, so a
# child Julia process in the fitting-test environment, `dev/scripts/radius.jl`, builds the
# seeds). CRYSOL's `Ra` and BAYSOL's r₀ are the same quantity (owner, 2026-11-25), so the
# table names both r₀. Everything else here is plain text handling, testable without
# BAYSOL.
module Radius

using ...Common
using ...Report
using Printf

const WHO = "bysl fits radius"

const USAGE = """
The excluded-volume radius r0 of each fit against the reference tool's, as a text table.

    bysl fits radius [ID[:tag] ...] --out FILE [--dry-run]

    ID[:tag]    fitting-test runs (default: every folder that has a LOG)
    --out FILE  the file the table is written to (required; replaced if it exists)
    --dry-run   print the command that would build the seeds, run nothing

One row per run: rM (hydrogenated, Å), BAYSOL's MAP c1, BAYSOL's r0 = c1·rM, the
reference tool (the first word of the LOG's refChi2 row) and the r0 it fitted (the Ra of a
CRYSOL .fit header). A run whose .fit header has no Ra is dropped without a row (one
summary line says how many). A run whose seed cannot be built or whose LOG has no c1 is
skipped; the skipped runs and the reasons follow the table, on stderr and in FILE.
Starts a Julia process in test/fitting_tests, in two phases: the .fit headers first, then
the hydrogenated structure of the surviving runs only (a cached one is reused; a stderr
line counts the cached and the hydrogenated ones). No fit.
"""

# The ends of CRYSOL's search range for Ra, inferred, not documented: 152 of 193 reference
# fits sit at exactly one of the two values.
const CRYSOL_R0_LOWER = 1.4
const CRYSOL_R0_UPPER = 1.8
const LIMIT_TOL = 1e-9

# The longest line of a cell of the last column.
const WRAP_WIDTH = 12

const DASH = "—"

# --- the pieces of a row

"The tag of a LOG section: `\"\"` (the script's one run) when the title is the id."
section_tag(id::AbstractString, title::AbstractString) =
    title == id ? "" : String(title)

"The spec `ID` or `ID:tag` that names a run for the child process."
spec_of(id::AbstractString, tag::AbstractString) =
    isempty(tag) ? String(id) : string(id, ":", tag)

"The label of a run: the id, plus the title when that is not the id."
run_label(id::AbstractString, title::AbstractString) =
    title == id ? String(id) : string(id, " ", title)

"""
    log_c1(run) -> Union{Float64,Nothing}

The MAP `c1` row of a parsed LOG section, `nothing` when it has none (a failed run) or it
is not a number.
"""
function log_c1(run::Run)
    v = get(run, :c1, "")
    v isa AbstractString || return v isa Real ? Float64(v) : nothing
    return tryparse(Float64, strip(v))
end

"""
    reference_name(run) -> String

The reference tool of a run: the first word of its `refChi2` row (`CRYSOL 1.14` gives
`CRYSOL`), `—` when there is none or it does not start with a letter.
"""
function reference_name(run::Run)
    words = split(string(get(run, :refChi2, "")))
    isempty(words) && return DASH
    return occursin(r"^[A-Za-z]", words[1]) ? String(words[1]) : DASH
end

"""
    fit_header_r0(header) -> Union{Float64,Nothing}

The `Ra` of the header of a CRYSOL `.fit` file (`Monomer_  Dro:0.075  Ra:1.800 ...`, the
first lines of the file), `nothing` for a header without one (other tools).
"""
function fit_header_r0(header::AbstractString)
    m = match(r"Ra:\s*([\d.]+)", header)
    m === nothing && return nothing
    return tryparse(Float64, m[1])
end

"""
    r0_limit_note(r0) -> String

` (at CRYSOL's lower limit)` when `r0` is 1.4 and ` (at CRYSOL's upper limit)` when it is
1.8 (within 1e-9), else the empty string. The two limits are inferred from a pile-up:
152 of 193 reference fits sit at exactly these values.
"""
function r0_limit_note(r0::Real)
    abs(r0 - CRYSOL_R0_LOWER) < LIMIT_TOL && return " (at CRYSOL's lower limit)"
    abs(r0 - CRYSOL_R0_UPPER) < LIMIT_TOL && return " (at CRYSOL's upper limit)"
    return ""
end

"The reference tool's r₀ as its cell shows it: 2 decimals and the limit note, or `—`."
r0_cell(r0::Union{Real,Nothing}) =
    r0 === nothing ? DASH : string(@sprintf("%.2f", r0), r0_limit_note(r0))

"BAYSOL's r₀: `c1 · rM`."
baysol_r0(c1::Real, rM::Real) = c1 * rM

# --- the child process

"""
    parse_child_output(text) -> Dict{String,NamedTuple}

The lines `spec<TAB>rM<TAB>ok<TAB>fitFile<TAB>software<TAB>header<TAB>status`,
`spec<TAB>-<TAB>noRa` and `spec<TAB>-<TAB>error text` of `dev/scripts/radius.jl`, by spec.
A value is `(; ok, noRa, rM, fitFile, software, header, status, error)`, `status` being
`cached` or `hydrogenated` (a run without `Ra:` has `noRa` true and no error); other lines
(the child's own chatter) are ignored.
"""
function parse_child_output(text::AbstractString)
    out = Dict{String,NamedTuple}()
    for line in split_lines(text)
        cells = split(line, '\t'; keepempty = true)
        length(cells) >= 3 || continue
        spec, rM, state = String(cells[1]), String(cells[2]), String(cells[3])
        cell(i) = length(cells) >= i ? String(cells[i]) : ""
        value = tryparse(Float64, rM)
        out[spec] =
            state == "ok" && value !== nothing ?
            (; ok = true, noRa = false, rM = value, fitFile = cell(4),
                software = cell(5) == "-" ? "" : cell(5),
                header = replace(cell(6), " | " => "\n"), status = cell(7),
                error = "") :
            state == "noRa" ?
            (; ok = false, noRa = true, rM = NaN, fitFile = "", software = "",
                header = "", status = "", error = "") :
            (; ok = false, noRa = false, rM = NaN, fitFile = "", software = "",
                header = "", status = "",
                error = isempty(strip(join(cells[3:end], " "))) ?
                        "child gave no reason" : strip(join(cells[3:end], " ")))
    end
    return out
end

# --- rows

"""
    build_rows(entries, child) -> (rows, skipped, dropped)

The table rows and the skipped runs for `entries`, the `(; id, title, run)` of the LOG
sections wanted, in order, and `child`, the parsed output of the child process (see
[`parse_child_output`](@ref)). A run is skipped, with the reason, when the child gave no
usable rM or its LOG has no `c1` (checked first: such a run never reaches the child). A
run whose `.fit` header has no `Ra` (reported by the child as `noRa`, or an `ok` line
whose header has none) is neither a row nor skipped: it is counted in `dropped`.

# Returns
- `rows`: `(; label, rM, c1, reference, refR0, status)` per run (`refR0` is a number);
    `skipped`: `(; label, reason)` per skipped run; `dropped`: the number of runs
    without a reference r₀.

# Exceptions
- None.
"""
function build_rows(entries, child)
    rows = NamedTuple[]
    skipped = NamedTuple[]
    dropped = 0
    for e in entries
        label = run_label(e.id, e.title)
        spec = spec_of(e.id, section_tag(e.id, e.title))
        c1 = log_c1(e.run)
        if c1 === nothing
            push!(skipped, (; label, reason = "no c1 in the LOG (a failed run?)"))
        elseif !haskey(child, spec)
            push!(skipped, (; label, reason = "the child process gave no line for $spec"))
        elseif child[spec].noRa
            dropped += 1
        elseif !child[spec].ok
            push!(skipped, (; label, reason = child[spec].error))
        else
            c = child[spec]
            r0 = fit_header_r0(c.header)
            if r0 === nothing
                dropped += 1
            else
                push!(
                    rows,
                    (; label, rM = c.rM, c1, reference = reference_name(e.run),
                        refR0 = r0, status = c.status),
                )
            end
        end
    end
    return rows, skipped, dropped
end

# --- the table

# The header lines of the columns, left to right (the trailing space of `rM ` counts).
const HEADERS = [
    String[],
    ["rM ", "(hydrogenated, ", "Å)"],
    ["BAYSOL", "c1"],
    ["BAYSOL", "r₀ = ", "c1·rM", "(Å)"],
    ["Reference"],
    ["r₀", "(Å)"],
]

"The lines of `text`, broken greedily between words so that none is longer than `width`."
function wrap_words(text::AbstractString, width::Int)
    lines = String[]
    cur = ""
    for w in split(text)
        if isempty(cur)
            cur = String(w)
        elseif length(cur) + 1 + length(w) <= width
            cur = string(cur, " ", w)
        else
            push!(lines, cur)
            cur = String(w)
        end
    end
    isempty(cur) || push!(lines, cur)
    return isempty(lines) ? [""] : lines
end

# The cells of a row, each as its lines: only the last column wraps.
function row_cells(r)
    return [
        [r.label],
        [@sprintf("%.3f", r.rM)],
        [@sprintf("%.3f", r.c1)],
        [@sprintf("%.2f", baysol_r0(r.c1, r.rM))],
        [r.reference],
        wrap_words(r0_cell(r.refR0), WRAP_WIDTH),
    ]
end

"""
    format_radius_table(rows) -> Vector{String}

The lines of the box-drawn table of `rows` (`(; label, rM, c1, reference, refR0)`, as
`build_rows` makes them; `refR0` is `nothing` without a reference r₀): the columns are the
label, rM, BAYSOL's c1 and r₀ = c1·rM, the reference tool and its r₀. Header lines are
centred (left padding `floor((w - length) / 2)`), cells are left-aligned with one space of
padding, a rule separates every row, the cells of the last column wrap at 12 characters
and the other cells of a taller row sit on its middle line. A column is as wide as its
longest header or cell line plus 2. Pure: no BAYSOL, no files.

# Returns
- The table, one string per line, without a trailing newline.

# Exceptions
- None.
"""
function format_radius_table(rows)::Vector{String}
    cells = [row_cells(r) for r in rows]
    ncol = length(HEADERS)
    widths = [
        2 + maximum(
            vcat(length.(HEADERS[j]), [length(l) for c in cells for l in c[j]], [0]),
        ) for j in 1:ncol
    ]
    rule(l, m, r) = l * join(("─"^w for w in widths), m) * r
    out = String[rule("┌", "┬", "┐")]
    # the header, top-aligned, each line centred
    for i in 1:maximum(length.(HEADERS))
        parts = map(1:ncol) do j
            text = i <= length(HEADERS[j]) ? HEADERS[j][i] : ""
            lead = fld(widths[j] - length(text), 2)
            rpad(" "^lead * text, widths[j])
        end
        push!(out, "│" * join(parts, "│") * "│")
    end
    for c in cells
        push!(out, rule("├", "┼", "┤"))
        height = maximum(length.(c))
        for i in 1:height
            parts = map(1:ncol) do j
                k = i - fld(height - length(c[j]), 2)
                text = 1 <= k <= length(c[j]) ? c[j][k] : ""
                rpad(" " * text, widths[j])
            end
            push!(out, "│" * join(parts, "│") * "│")
        end
    end
    push!(out, rule("└", "┴", "┘"))
    return out
end

"""
    output_text(rows, skipped, dropped = 0) -> String

The text of the output file: the table, then, if any run was skipped, a `skipped:` block
with one `label: reason` line each and, if any run was dropped, the line of
[`dropped_line`](@ref).
"""
function output_text(rows, skipped, dropped = 0)
    io = IOBuffer()
    foreach(l -> println(io, l), format_radius_table(rows))
    if !isempty(skipped) || dropped > 0
        println(io)
        if !isempty(skipped)
            println(io, "skipped:")
            foreach(s -> println(io, "    ", s.label, ": ", s.reason), skipped)
        end
        dropped > 0 && println(io, dropped_line(dropped))
    end
    return String(take!(io))
end

"The summary line of the runs left out for want of a reference r₀."
dropped_line(
    n::Integer,
) = "dropped $n run$(n == 1 ? "" : "s") without a reference r₀ (no Ra in the .fit header)"

"The line that counts the structures `rows` found in the cache and had to hydrogenate."
function cache_line(rows)
    cached = count(r -> r.status == "cached", rows)
    return "$cached cached, $(count(r -> r.status == "hydrogenated", rows)) hydrogenated"
end

# --- the tool

# The LOG sections wanted, as `(; id, title, run)`: those of every LOG, or of the specs
# (`ID` takes all its sections, `ID:tag` the one whose tag it is).
function log_entries(specs)
    entries = NamedTuple[]
    for id in ids()
        path = in_root(FIT_DIR, id, id * ".LOG")
        isfile(path) || continue
        for (title, run) in parse_log(slurp8(path))
            wanted =
                isempty(specs) || any(specs) do s
                    sid, stag = occursin(':', s) ? split(s, ':'; limit = 2) : (s, nothing)
                    sid == id && (stag === nothing || stag == section_tag(id, title))
                end
            wanted && push!(entries, (; id, title, run))
        end
    end
    return entries
end

# The command that builds the seeds of `specs` in the fitting-test environment.
child_command(specs) = [
    find_julia(), "--startup-file=no", "--project=" * in_root(FIT_DIR),
    in_root("dev", "scripts", "radius.jl"), specs...,
]

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    (; opts, flags, specs) = split_args(WHO, ["--out"], ["--dry-run"], argv)
    out = get(Dict(opts), "--out", nothing)
    out === nothing && fail(WHO, "--out FILE is required")
    check_folders(WHO, specs)
    entries = log_entries(specs)
    isempty(entries) && fail(WHO, "no LOG section to cover")
    # a run without a c1 is skipped here, before any structure work
    child_specs = unique(
        spec_of(e.id, section_tag(e.id, e.title)) for
        e in entries if log_c1(e.run) !== nothing
    )
    isempty(child_specs) && fail(WHO, "no run with a c1 in its LOG")
    cmd = child_command(child_specs)
    if "--dry-run" in flags
        println("\$ ", join(cmd, " "))
        return 0
    end
    text = try
        # the child's own stderr (progress, warnings) goes to ours
        read(pipeline(Common.to_cmd(cmd); stderr = stderr), String)
    catch err
        fail(WHO, "could not run the child process: " * sprint(showerror, err))
    end
    rows, skipped, dropped = build_rows(entries, parse_child_output(text))
    body = output_text(rows, skipped, dropped)
    spit8(out, body)
    print(body)
    println(stderr, "\n", WHO, ": structures: ", cache_line(rows))
    isempty(skipped) || begin
        println(stderr, WHO, ": skipped:")
        foreach(s -> println(stderr, "    ", s.label, ": ", s.reason), skipped)
    end
    dropped > 0 && println(stderr, WHO, ": ", dropped_line(dropped))
    println("\nwrote ", out)
    return 0
end

end
