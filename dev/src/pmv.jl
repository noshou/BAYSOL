# SPDX-License-Identifier: LGPL-3.0-or-later

"""
3D-RISM partial molar volumes (PMV) with a Bayesian group correction.
One module per part (paths, tables, the model, the
polymers rows, the 3D-RISM driver, the diagnostics, the self-test), one command line on
top (`bysl extract pmv SUBCOMMAND`). RDKit comes from RDKitMinimalLib.jl (group counts and
ETKDG embedding); AmberTools (antechamber, parmchk2, tleap, rism3d.snglpnt) stays an
external install used by `run` and `batch` only. Details in dev/README.md ("pmv").
"""
module Pmv

using ..Common
using Base.ScopedValues: ScopedValue, with

# --- text helpers shared by every part

module Layout

using Printf: Printf

export ff, ffs, pyfloat, dumps, loads

using OrderedCollections: OrderedDict

# `x` with `digits` decimals as Python's
# `f"{x:.{digits}f}"` prints it (nan, inf lower case).
function ff(digits::Integer, x::Real)::String
    s = Printf.format(Printf.Format("%.$(digits)f"), Float64(x))
    return replace(s, "NaN" => "nan", "Inf" => "inf")
end

# The same with a sign (`f"{x:+.{digits}f}"`).
function ffs(digits::Integer, x::Real)::String
    s = Printf.format(Printf.Format("%+.$(digits)f"), Float64(x))
    return replace(s, "NaN" => "nan", "Inf" => "inf")
end

"""
    pyfloat(x) -> String

The shortest round-trip text of `x` laid out as Python's `repr(float)` does (`1e-06`,
`1e+16`, `2.0`): the files the tools write keep the layout the Python tools gave them.
"""
function pyfloat(x::Real)::String
    v = Float64(x)
    isnan(v) && return "NaN"
    isinf(v) && return v > 0 ? "Infinity" : "-Infinity"
    v == 0 && return signbit(v) ? "-0.0" : "0.0"
    sign = v < 0 ? "-" : ""
    mant, ex =
        occursin('e', string(abs(v))) ? split(string(abs(v)), 'e') :
        (string(abs(v)), "0")
    ip, fp = occursin('.', mant) ? split(mant, '.') : (mant, "")
    digits = ip * fp
    decpt = length(ip) + parse(Int, ex)
    lead = length(digits) - length(lstrip(==('0'), digits))
    digits = digits[(lead+1):end]
    decpt -= lead
    digits = rstrip(==('0'), digits)
    isempty(digits) && (digits = "0")
    if -4 <= decpt - 1 < 16
        if decpt <= 0
            body = "0." * "0"^(-decpt) * digits
        elseif decpt >= length(digits)
            body = digits * "0"^(decpt - length(digits)) * ".0"
        else
            body = digits[1:decpt] * "." * digits[(decpt+1):end]
        end
        return sign * body
    end
    rest = digits[2:end]
    head = isempty(rest) ? digits[1:1] : digits[1:1] * "." * rest
    return sign * head * Printf.format(Printf.Format("e%+03d"), decpt - 1)
end

# A JSON string as Python's `json.dumps(..., ensure_ascii=False)` writes it.
function _jstring(s::AbstractString)::String
    io = IOBuffer()
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif c == '\b'
            print(io, "\\b")
        elseif c == '\f'
            print(io, "\\f")
        elseif c < ' '
            print(io, Printf.format(Printf.Format("\\u%04x"), Int(c)))
        else
            print(io, c)
        end
    end
    print(io, '"')
    return String(take!(io))
end

"""
    dumps(x; indent) -> String

`x` (dictionaries with string keys, vectors, strings, numbers, booleans, `nothing`) as
JSON text laid out as Python's `json.dumps(x, indent=indent, ensure_ascii=False)`.
"""
function dumps(x; indent::Int = 1, level::Int = 0)::String
    pad = " "^(indent * (level + 1))
    close = " "^(indent * level)
    if x isa AbstractDict
        isempty(x) && return "{}"
        items = [
            pad * _jstring(string(k)) * ": " * dumps(v; indent, level = level + 1)
            for (k, v) in x
        ]
        return "{\n" * join(items, ",\n") * "\n" * close * "}"
    elseif x isa AbstractVector || x isa Tuple
        isempty(x) && return "[]"
        items = [pad * dumps(v; indent, level = level + 1) for v in x]
        return "[\n" * join(items, ",\n") * "\n" * close * "]"
    elseif x isa AbstractString
        return _jstring(x)
    elseif x isa Bool
        return x ? "true" : "false"
    elseif x === nothing
        return "null"
    elseif x isa Integer
        return string(x)
    else
        return pyfloat(x)
    end
end

"""
    loads(text) -> Any

Parses JSON text into `OrderedDict{String,Any}` objects (file order), `Vector{Any}` arrays,
strings, `Int` (no fraction or exponent) or `Float64` numbers, booleans and `nothing`, so
that writing the value back with [`dumps`](@ref) reproduces a file `dumps` wrote. (JSON3
into a dictionary type loses both the key order and the `.0` of a whole float.)
"""
function loads(text::AbstractString)
    s = String(text)
    i = Ref(firstindex(s))
    ws() =
        while i[] <= lastindex(s) && s[i[]] in " \t\r\n"
            i[] = nextind(s, i[])
        end
    function str()
        i[] = nextind(s, i[])   # the opening quote
        io = IOBuffer()
        while s[i[]] != '"'
            c = s[i[]]
            if c == '\\'
                i[] = nextind(s, i[])
                e = s[i[]]
                if e == 'u'
                    cp = parse(UInt32, s[(i[]+1):(i[]+4)]; base = 16)
                    i[] += 4
                    if 0xd800 <= cp < 0xdc00 && s[(i[]+1):(i[]+2)] == "\\u"
                        lo = parse(UInt32, s[(i[]+3):(i[]+6)]; base = 16)
                        i[] += 6
                        cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00)
                    end
                    print(io, Char(cp))
                else
                    print(
                        io,
                        get(
                            Dict('n' => '\n', 'r' => '\r', 't' => '\t', 'b' => '\b',
                                'f' => '\f'), e, e),
                    )
                end
            else
                print(io, c)
            end
            i[] = nextind(s, i[])
        end
        i[] = nextind(s, i[])
        return String(take!(io))
    end
    function value()
        ws()
        c = s[i[]]
        if c == '{'
            d = OrderedDict{String,Any}()
            i[] = nextind(s, i[])
            ws()
            s[i[]] == '}' && (i[] = nextind(s, i[]); return d)
            while true
                ws()
                k = str()
                ws()
                i[] = nextind(s, i[])   # the colon
                d[k] = value()
                ws()
                c = s[i[]]
                i[] = nextind(s, i[])
                c == '}' && return d
            end
        elseif c == '['
            v = Any[]
            i[] = nextind(s, i[])
            ws()
            s[i[]] == ']' && (i[] = nextind(s, i[]); return v)
            while true
                push!(v, value())
                ws()
                c = s[i[]]
                i[] = nextind(s, i[])
                c == ']' && return v
            end
        elseif c == '"'
            return str()
        end
        for (word, val) in ("true" => true, "false" => false, "null" => nothing,
            "NaN" => NaN, "Infinity" => Inf, "-Infinity" => -Inf)
            if startswith(SubString(s, i[]), word)
                i[] += ncodeunits(word)
                return val
            end
        end
        m = match(r"-?\d+(\.\d+)?([eE][-+]?\d+)?", s, i[])
        i[] += ncodeunits(m.match)
        return m[1] === nothing && m[2] === nothing ? parse(Int, m.match) :
               parse(Float64, m.match)
    end
    return value()
end

end

using .Layout

# --- paths and the AmberTools environment

module Config

using ...Common

export POLYMERS, NONBIOLOGICAL, TABLES, NONBIO_LOOKUP, out_dir, ensure_out,
    results_path, work_dir, amber_home, amber_env, OUT, AMBER, NICE
using Base.ScopedValues: ScopedValue

# The setting the global option `--out` sets for one call, and
# the AmberTools prefix a test can point elsewhere; `nothing` is "the environment, then
# the default".
const OUT = ScopedValue{Union{Nothing,String}}(nothing)
const AMBER = ScopedValue{Union{Nothing,String}}(nothing)
# The niceness (0 to 19) the AmberTools programs of a `batch` run get; 0 leaves them alone.
const NICE = ScopedValue{Int}(0)

# Everything is read at call time, so the root of a test or an option applies at once.
POLYMERS() = in_root("src", "bulk-electron-density", "polymers")
NONBIOLOGICAL() = in_root("src", "bulk-electron-density", "non-biological")
TABLES() = [
    "polymers" => joinpath(POLYMERS(), "polymers.tsv"),
    "nonbiological" => joinpath(NONBIOLOGICAL(), "nonbiological.tsv"),
]
NONBIO_LOOKUP() = joinpath(NONBIOLOGICAL(), "nonbio_lookup.json")

"""
    out_dir() -> String

The output folder, `--out DIR`. There is no default inside the repository, so a command
that writes (fit, diagnostics, run, batch) without it is a usage error. Not created here.

# Returns
The folder as given (made absolute by the command line).

# Exceptions
`ToolError` (status 2) when `--out` was not given.
"""
function out_dir()
    d = OUT[]
    d === nothing && throw(
        ToolError("bysl extract pmv: --out DIR is required (before the subcommand)", 2),
    )
    return d
end

"`out_dir()`, created if it does not exist."
function ensure_out()
    d = out_dir()
    mkpath(d)
    return d
end

"""
    results_path() -> String

Where `run` and `batch` append their finished runs: `results.tsv` in the output folder.
The runs of the bundled `RESULTS` are the base every report reads; this file only adds to
them (the last line of a name wins), and `batch` resumes from it.

# Returns
The file path (not created here).

# Exceptions
`ToolError` (status 2) when `--out` was not given.
"""
results_path() = joinpath(out_dir(), "results.tsv")

"Scratch folder of the runs: `work` under the output folder (`--out`)."
work_dir() = joinpath(out_dir(), "work")

"AmberTools prefix: env AMBERHOME, default ~/.conda/envs/amber26."
amber_home() =
    something(AMBER[], get(ENV, "AMBERHOME", nothing),
        joinpath(homedir(), ".conda", "envs", "amber26"))

"Process environment with the AmberTools `bin` first on PATH, as pairs for `addenv`."
function amber_env()
    a = amber_home()
    return ["PATH" => string(a, "/bin:", get(ENV, "PATH", "")), "AMBERHOME" => string(a)]
end

end

using .Config

# --- TSV readers, results.tsv and the electron count

module Tables

using ...Common
using ..Config
using CSV: CSV
using OrderedCollections: OrderedDict

export read_tsv, read_results, calibration_table, RESULTS, CALIBRATION, electrons, ELEMENT_Z

const ELEMENT_Z = Dict("H" => 1, "C" => 6, "N" => 7, "O" => 8, "P" => 15, "S" => 16,
    "Na" => 11)

"The rows of a TSV with a header line, as dictionaries (a short row has fewer keys)."
function read_tsv(path)::Vector{Dict{String,String}}
    lines = [split(ln, '\t') for ln in eachline(string(path)) if !isempty(strip(ln))]
    isempty(lines) && return Dict{String,String}[]
    head = lines[1]
    return [Dict{String,String}(zip(head, r)) for r in lines[2:end]]
end

"name => (n, mean, sd), in file order.
Reference finished 3D-RISM runs: name, number of conformers n, mean and SD
of the raw volumes (cm3/mol; `nan` for a single conformer.
The runs used a 25 A box buffer, a 0.5 A grid and tolerance 1e-6. It is the former
results.tsv of the old tool folder without the runs nothing reads any more."
const RESULTS = OrderedDict{String,Tuple{Int,Float64,Float64}}(
    String(r.name) => (r.n, r.mean, r.sd) for r in
    CSV.File(
        IOBuffer(
            """
            name   |  n |   mean |   sd
            DM     | 10 | 368.91 | 3.41
            K001   |  1 |  50.71 |  nan
            K002   |  3 |  65.44 | 0.06
            K003   |  3 |  79.91 | 0.18
            K004   |  5 | 108.85 | 0.40
            K005   |  5 | 123.66 | 0.39
            K006   |  1 |  66.10 |  nan
            K007   |  1 |  80.90 |  nan
            K008   |  1 |  95.70 |  nan
            K009   |  1 |  82.56 |  nan
            K010   |  3 |  54.05 | 0.14
            K011   |  3 |  68.42 | 0.19
            K012   |  5 |  82.91 | 0.24
            K013   |  5 | 112.48 | 0.43
            K014   |  5 | 141.52 | 0.52
            K015   |  3 |  72.57 | 0.06
            K016   |  5 |  90.95 | 0.42
            K017   |  5 | 109.24 | 0.40
            K018   |  5 | 127.55 | 0.64
            K019   |  1 |  99.92 |  nan
            K020   |  3 |  82.20 | 0.30
            K021   |  5 |  86.77 | 0.23
            K022   |  5 | 121.52 | 0.36
            K023   |  1 |  73.65 |  nan
            K024   |  1 | 213.99 |  nan
            K025   |  1 | 175.67 |  nan
            K026   |  1 | 140.67 |  nan
            K027   |  3 |  70.37 | 0.23
            K028   |  5 |  85.71 | 0.28
            K029   |  5 | 115.05 | 0.45
            K030   |  5 | 102.27 | 0.18
            K031   |  5 |  88.55 | 0.37
            K032   |  5 | 123.92 | 0.27
            K033   |  5 | 159.00 | 1.07
            K034   |  3 | 117.97 | 0.04
            K035   |  3 | 117.77 | 0.38
            K036   |  3 | 100.28 | 0.39
            K037   |  1 |  98.43 |  nan
            K038   |  3 | 113.23 | 0.37
            K039   |  5 | 217.40 | 2.37
            K040   |  5 | 220.30 | 0.99
            K041   |  3 | 134.34 | 0.80
            K042   |  3 | 133.62 | 0.41
            K043   |  5 | 150.50 | 0.60
            K044   |  5 | 178.63 | 2.03
            K045   |  5 | 237.60 | 0.75
            K046   |  1 |  51.67 |  nan
            K047   |  3 |  81.23 | 0.02
            K048   |  5 | 110.73 | 0.23
            K049   |  3 |  67.22 | 0.09
            K050   |  1 |  82.21 |  nan
            K051   |  1 |  86.18 |  nan
            K052   |  1 |  96.87 |  nan
            K053   |  3 | 103.24 | 0.08
            K054   |  5 | 101.87 | 0.13
            K055   |  3 |  80.64 | 0.11
            K056   |  5 | 109.41 | 0.17
            K057   |  3 |  82.26 | 0.22
            K058   |  5 | 141.05 | 0.46
            K059   |  1 |  96.61 |  nan
            K060   |  1 |  98.41 |  nan
            K061   |  1 |  89.94 |  nan
            K062   |  1 |  94.71 |  nan
            K063   |  1 |  46.34 |  nan
            K064   |  5 | 105.26 | 0.23
            K065   |  1 |  62.44 |  nan
            K066   |  3 |  91.87 | 0.07
            K067   |  1 |  92.52 |  nan
            K068   |  3 |  83.20 | 0.10
            K069   |  3 | 104.06 | 0.19
            K070   |  1 |  70.20 |  nan
            K071   |  1 |  63.92 |  nan
            K072   |  3 |  89.45 | 0.60
            K073   |  1 |  74.14 |  nan
            K074   |  3 |  92.83 | 0.09
            K075   |  5 | 112.48 | 0.31
            K076   |  1 |  78.08 |  nan
            K077   |  3 |  54.57 | 0.31
            K078   |  5 | 112.97 | 0.17
            K079   |  5 |  89.39 | 0.49
            K080   |  5 | 116.90 | 1.30
            K081   |  3 |  47.63 | 0.12
            K082   |  3 |  64.26 | 0.11
            K083   |  5 | 107.71 | 0.58
            K084   |  5 |  75.32 | 2.96
            K085   |  5 | 102.79 | 2.43
            K086   |  5 | 130.85 | 1.53
            K087   |  3 |  81.59 | 0.05
            K088   |  5 |  84.34 | 0.10
            K089   |  5 | 116.09 | 1.13
            K090   |  5 | 255.27 | 0.98
            Cymal6 | 10 | 383.01 | 2.73
            tPCCaM | 10 | 412.77 | 1.91
            OTG    |  6 | 244.70 | 0.57
            SML    | 10 | 399.10 | 1.95
            R001   |  8 | 143.39 | 1.57
            R002   |  8 | 135.45 | 0.47
            R003   |  8 | 166.89 | 0.71
            M8     |  6 | 340.07 | 1.29
            R004   |  8 | 160.47 | 0.48
            R005   |  8 | 156.30 | 1.20
            R006   |  8 | 148.10 | 0.77
            R007   |  6 | 119.14 | 0.39
            R008   |  6 | 133.55 | 0.60
            R009   |  6 | 138.14 | 0.34
            M9     |  6 | 353.91 | 4.04
            R010   |  8 | 154.66 | 0.57
            R011   |  8 | 141.57 | 0.49
            R012   |  8 | 156.21 | 0.38
            R013   |  8 | 165.60 | 0.27
            R014   |  4 | 102.19 | 0.18
            R015   |  3 |  84.82 | 0.28
            R016   |  3 |  91.30 | 0.63
            R017   |  6 | 113.13 | 0.40
            R018   |  6 | 111.83 | 0.40
            R019   |  8 | 144.27 | 1.12
            R020   |  4 |  90.03 | 1.45
            R021   |  6 | 112.67 | 0.41
            R022   |  6 |  96.99 | 0.56
            R023   |  3 |  88.26 | 0.34
            R024   |  3 |  87.08 | 0.03
            R025   |  4 | 106.84 | 0.11
            R026   |  3 |  88.20 | 0.09
            R027   |  3 |  94.52 | 0.36
            R028   | 10 | 128.21 | 0.65
            R029   | 10 | 113.52 | 0.84
            R030   |  6 | 153.22 | 0.36
            R031   |  6 | 136.83 | 0.60
            M11    |  6 | 383.65 | 1.79
            R032   |  6 | 169.41 | 0.67
            R033   |  6 | 153.04 | 0.76
            R034   |  8 | 179.11 | 1.40
            R035   |  8 | 132.69 | 0.29
            R036   |  8 | 141.97 | 0.35
            R037   |  8 | 179.90 | 1.09
            R038   |  8 | 135.36 | 0.32
            M12    |  6 | 393.92 | 2.72
            R042   | 10 | 205.81 | 0.83
            M13    |  6 | 411.40 | 2.85
            R043   | 10 | 211.33 | 0.88
            G6     |  6 | 208.84 | 1.64
            G9     |  6 | 252.44 | 0.69
            G10    |  6 | 267.89 | 1.62
            R044   | 10 | 218.34 | 0.92
            Cymal3 |  6 | 340.41 | 2.03
            Cymal4 |  6 | 352.41 | 0.93
            Cymal5 |  6 | 367.92 | 1.09
            Cymal7 |  6 | 396.38 | 1.25
            FC8    |  6 | 231.76 | 1.78
            FC10   |  6 | 260.96 | 1.45
            FC12   |  6 | 291.07 | 2.08
            FC14   |  6 | 319.40 | 1.41
            FC16   |  6 | 348.07 | 1.39
            DIG    |  4 | 836.47 | 4.23
            S001   |  6 | 213.76 | 2.78
            S002   |  6 | 211.85 | 2.26
            S003   |  6 | 211.26 | 2.76
            S004   |  6 | 203.56 | 1.76
            S005   |  6 | 201.74 | 3.15
            S006   |  6 | 182.20 | 1.01
            S007   |  6 | 169.08 | 0.58
            S008   |  6 | 171.03 | 0.72
            S009   |  6 | 156.24 | 0.35
            S010   |  6 | 153.29 | 0.38
            S011   |  6 | 462.43 | 5.12
            S012   |  6 | 432.17 | 3.28
            S013   |  6 | 459.00 | 5.94
            S014   |  6 | 429.44 | 3.76
            S015   |  6 | 150.47 | 0.57
            S016   |  6 | 119.58 | 0.22
            S017   |  6 | 247.06 | 2.44
            S018   |  6 | 250.55 | 0.95
            S019   |  6 | 280.00 | 0.95
            S020   |  6 | 487.20 | 1.53
            S021   |  6 | 429.30 | 2.73
            S022   |  6 | 451.92 | 1.62
            S023   |  6 | 397.01 | 2.39
            S024   |  6 | 248.85 | 2.53
            S025   |  6 | 218.36 | 2.13
            S026   |  6 | 825.89 | 6.41
            S027   |  6 | 487.91 | 5.63
            S028   |  6 | 395.80 | 1.62
            S029   |  6 | 554.21 | 3.13
            S030   |  6 | 280.46 | 0.07
            S031   |  6 | 293.26 | 0.29
            S032   |  6 | 263.75 | 0.41
            S033   |  6 | 235.70 | 0.13
            S034   |  6 | 292.18 | 0.13
            S035   |  6 | 194.25 | 0.11
            S036   |  6 | 231.80 | 0.78
            S037   |  6 | 348.19 | 1.55
            BTP0   | 10 | 199.89 | 1.82
            BTP1   | 10 | 204.66 | 1.88
            BTP2   | 10 | 206.07 | 1.16
            TRIS0  |  3 |  87.74 | 0.48
            TRIS1  |  3 |  92.58 | 0.90
            """,
        );
        delim = '|',
        stripwhitespace = true,
        types = [String, Int, Float64, Float64],
    )
)

"""
    read_results(path = nothing) -> OrderedDict

name => (n, mean, sd) of the finished runs: the bundled `RESULTS`, then the lines of a
results file added on top (the last line of a name wins). The file is `path`, else
`results.tsv` under `--out` when that is given; a missing file adds nothing. File columns:
name, n, mean, sd, buffer, grid, tolerance (tab separated).

# Returns
An ordered dictionary, the bundled runs first.

# Exceptions
A malformed number in the file is a `ArgumentError`.
"""
function read_results(path = nothing)
    r = copy(RESULTS)
    p =
        path !== nothing ? string(path) :
        OUT[] !== nothing ? joinpath(OUT[], "results.tsv") : nothing
    if p !== nothing && isfile(p)
        for line in eachline(p)
            q = split(line, '\t')
            length(q) >= 4 &&
                (r[q[1]] = (parse(Int, q[2]), parse(Float64, q[3]), parse(Float64, q[4])))
        end
    end
    return r
end

"""Provenance."""
function _calibrationProvenance(source::AbstractString)::String
    source == "unverified" &&
        return "literature volume used when the set was built; " *
               "source not recorded, re-verify"
    startswith(source, "derived:") && return "derived " * source[9:end]
    startswith(source, "monomer:") &&
        return "measured " * source[9:end] *
               " (monomer; the earlier mixed 249.35 was wrong)"
    return "measured " * source
end

_readTable(text, types) =
    CSV.File(IOBuffer(text); delim = '|', stripwhitespace = true, types = types)

"""
The calibration set: 90 solutes group corrections are fitted on.
"""
const CALIBRATION = let
    names = Dict(
        String(r.id) => String(r.name) for r in _readTable(
            """
            id   | name
            K001 | ethanol
            K002 | 1-propanol
            K003 | 1-butanol
            K004 | 1-hexanol
            K005 | 1-heptanol
            K006 | 2-propanol
            K007 | 2-methyl-2-propanol
            K008 | cyclohexanol
            K009 | cyclopentanol
            K010 | ethylene glycol
            K011 | 1,3-propanediol
            K012 | 1,4-butanediol
            K013 | 1,6-hexanediol
            K014 | 1,8-octanediol
            K015 | glycerol
            K016 | erythritol
            K017 | xylitol
            K018 | d-mannitol
            K019 | 1,4-cyclohexanediol
            K020 | diethyl ether
            K021 | 1,2-dimethoxyethane
            K022 | diglyme
            K023 | 1,4-dioxane
            K024 | 18-crown-6
            K025 | 15-crown-5
            K026 | 12-crown-4
            K027 | 2-methoxyethanol
            K028 | 2-ethoxyethanol
            K029 | 2-butoxyethanol
            K030 | diethoxymethane
            K031 | diethylene glycol
            K032 | triethylene glycol
            K033 | tetraethylene glycol
            K034 | glucose
            K035 | d-galactose
            K036 | d-ribose
            K037 | d-xylose
            K038 | 2-deoxy-d-glucose
            K039 | cellobiose
            K040 | sucrose
            K041 | methyl beta-d-glucopyranoside
            K042 | methyl alpha-d-glucopyranoside
            K043 | ethyl alpha-d-glucopyranoside
            K044 | phenyl beta-d-glucopyranoside
            K045 | octyl glucopyranoside
            K046 | acetamide
            K047 | butanamide
            K048 | hexanamide
            K049 | dmf
            K050 | dmac
            K051 | 1-methyl-2-pyrrolidinone
            K052 | epsilon-caprolactam
            K053 | 1,1-diethylurea
            K054 | butylurea
            K055 | 1-butanamine
            K056 | 1-hexanamine
            K057 | diethylamine
            K058 | dibutylamine
            K059 | cyclohexanamine
            K060 | 1-methylpiperidine
            K061 | 4-methylmorpholine
            K062 | dabco
            K063 | acetonitrile
            K064 | hexanenitrile
            K065 | acetone
            K066 | 2-pentanone
            K067 | cyclohexanone
            K068 | ethyl acetate
            K069 | diethyl carbonate
            K070 | gamma-butyrolactone
            K071 | dimethyl sulfoxide
            K072 | diethyl sulfide
            K073 | benzene
            K074 | benzyl alcohol
            K075 | 2-phenoxyethanol
            K076 | aniline
            K077 | 2-aminoethanol
            K078 | 6-amino-1-hexanol
            K079 | diethanolamine
            K080 | 2-(diethylamino)ethanol
            K081 | glycine
            K082 | dl-alanine
            K083 | dl-norleucine
            K084 | 4-aminobutanoic acid
            K085 | 6-aminohexanoic acid
            K086 | 8-aminooctanoic acid
            K087 | betaine
            K088 | glycylglycine
            K089 | triglycine
            K090 | methyl 6-o-octanoyl-beta-d-glucopyranoside
            """,
            String,
        )
    )

    smiles = Dict(
        String(r.id) => String(r.smiles) for r in _readTable(
            """
            id   | smiles
            K001 | CCO
            K002 | CCCO
            K003 | CCCCO
            K004 | CCCCCCO
            K005 | CCCCCCCO
            K006 | CC(C)O
            K007 | CC(C)(C)O
            K008 | OC1CCCCC1
            K009 | OC1CCCC1
            K010 | OCCO
            K011 | OCCCO
            K012 | OCCCCO
            K013 | OCCCCCCO
            K014 | OCCCCCCCCO
            K015 | OCC(O)CO
            K016 | OCC(O)C(O)CO
            K017 | OCC(O)C(O)C(O)CO
            K018 | OC[C@@H](O)[C@@H](O)[C@H](O)[C@H](O)CO
            K019 | OC1CCC(O)CC1
            K020 | CCOCC
            K021 | COCCOC
            K022 | COCCOCCOC
            K023 | C1COCCO1
            K024 | C1COCCOCCOCCOCCOCCO1
            K025 | C1COCCOCCOCCOCCO1
            K026 | C1COCCOCCOCCO1
            K027 | COCCO
            K028 | CCOCCO
            K029 | CCCCOCCO
            K030 | CCOCOCC
            K031 | OCCOCCO
            K032 | OCCOCCOCCO
            K033 | OCCOCCOCCOCCO
            K034 | OC[C@H]1O[C@@H](O)[C@H](O)[C@@H](O)[C@@H]1O
            K035 | OC[C@H]1O[C@@H](O)[C@H](O)[C@@H](O)[C@H]1O
            K036 | OC[C@H]1O[C@@H](O)[C@H](O)[C@@H]1O
            K037 | O[C@@H]1CO[C@@H](O)[C@H](O)[C@H]1O
            K038 | OC[C@H]1O[C@@H](O)CC(O)[C@@H]1O
            K039 | OC[C@H]1O[C@@H](O[C@H]2[C@H](O)[C@@H](O)[C@H](O)O[C@@H]2CO)\
                [C@H](O)[C@@H](O)[C@@H]1O
            K040 | C([C@@H]1[C@H]([C@@H]([C@H]([C@H](O1)O[C@]2([C@H]([C@@H]([C@H]\
                (O2)CO)O)O)CO)O)O)O)O
            K041 | CO[C@@H]1O[C@H](CO)[C@@H](O)[C@H](O)[C@H]1O
            K042 | CO[C@H]1O[C@H](CO)[C@@H](O)[C@H](O)[C@H]1O
            K043 | CCO[C@H]1O[C@H](CO)[C@@H](O)[C@H](O)[C@H]1O
            K044 | OC[C@H]1O[C@@H](Oc2ccccc2)[C@H](O)[C@@H](O)[C@@H]1O
            K045 | CCCCCCCCO[C@@H]1O[C@H](CO)[C@@H](O)[C@H](O)[C@H]1O
            K046 | CC(N)=O
            K047 | CCCC(N)=O
            K048 | CCCCCC(N)=O
            K049 | CN(C)C=O
            K050 | CC(=O)N(C)C
            K051 | CN1CCCC1=O
            K052 | O=C1CCCCCN1
            K053 | CCN(CC)C(N)=O
            K054 | CCCCNC(N)=O
            K055 | CCCCN
            K056 | CCCCCCN
            K057 | CCNCC
            K058 | CCCCNCCCC
            K059 | NC1CCCCC1
            K060 | CN1CCCCC1
            K061 | CN1CCOCC1
            K062 | C1CN2CCN1CC2
            K063 | CC#N
            K064 | CCCCCC#N
            K065 | CC(C)=O
            K066 | CCCC(C)=O
            K067 | O=C1CCCCC1
            K068 | CCOC(C)=O
            K069 | CCOC(=O)OCC
            K070 | O=C1CCCO1
            K071 | CS(C)=O
            K072 | CCSCC
            K073 | c1ccccc1
            K074 | OCc1ccccc1
            K075 | OCCOc1ccccc1
            K076 | Nc1ccccc1
            K077 | NCCO
            K078 | NCCCCCCO
            K079 | OCCNCCO
            K080 | CCN(CC)CCO
            K081 | [NH3+]CC([O-])=O
            K082 | C[C@H]([NH3+])C([O-])=O
            K083 | CCCC[C@H]([NH3+])C([O-])=O
            K084 | [NH3+]CCCC([O-])=O
            K085 | [NH3+]CCCCCC([O-])=O
            K086 | [NH3+]CCCCCCCC([O-])=O
            K087 | C[N+](C)(C)CC([O-])=O
            K088 | [NH3+]CC(=O)NCC([O-])=O
            K089 | [NH3+]CC(=O)NCC(=O)NCC([O-])=O
            K090 | CCCCCCCC(=O)OC[C@H]1O[C@@H](OC)[C@H](O)[C@@H](O)[C@@H]1O
            """,
            String)
    )
    [
        Dict{String,String}(
            "id" => String(r.id),
            "name" => names[String(r.id)],
            "smiles" => smiles[String(r.id)],
            "charge" => String(r.charge),
            "nconf" => String(r.nconf),
            "v_meas" => String(r.v_meas),
            "provenance" => _calibrationProvenance(r.source),
            "fit" => String(r.fit),
        ) for r in _readTable(
            """
            id   | charge | nconf | v_meas | fit | source
            K001 |      0 |     1 |  55.10 |   1 | 10.1007/978-3-642-71114-5_2
            K002 |      0 |     3 |  70.66 |   1 | 10.1007/BF00646936
            K003 |      0 |     3 |  86.60 |   1 | 10.1007/978-3-642-71114-5_2
            K004 |      0 |     5 | 118.65 |   1 | 10.1007/978-3-642-71114-5_2
            K005 |      0 |     5 | 133.43 |   1 | 10.1007/BF00646936
            K006 |      0 |     1 |  71.92 |   1 | 10.1007/BF00646936
            K007 |      0 |     1 |  87.74 |   1 | 10.1007/BF00646936
            K008 |      0 |     1 | 103.50 |   1 | 10.1007/978-3-642-71114-5_2
            K009 |      0 |     1 |  89.00 |   1 | 10.1007/978-3-642-71114-5_2
            K010 |      0 |     3 |  54.63 |   1 | 10.1016/j.jct.2008.04.007
            K011 |      0 |     3 |  71.90 |   1 | 10.1007/978-3-642-71114-5_2
            K012 |      0 |     5 |  88.33 |   1 | 10.1007/978-3-642-71114-5_2
            K013 |      0 |     5 | 120.47 |   1 | 10.1016/j.jct.2007.01.009
            K014 |      0 |     5 | 152.60 |   1 | 10.1007/978-3-642-71114-5_2
            K015 |      0 |     3 |  70.78 |   1 | 10.1007/978-3-642-71114-5_2
            K016 |      0 |     5 |  87.10 |   1 | 10.1007/978-3-642-71114-5_2
            K017 |      0 |     5 | 102.40 |   1 | unverified
            K018 |      0 |     5 | 119.37 |   1 | 10.1007/BF00646936
            K019 |      0 |     1 | 105.30 |   1 | 10.1007/978-3-642-71114-5_2
            K020 |      0 |     3 |  90.40 |   1 | 10.1007/978-3-642-71114-5_2
            K021 |      0 |     5 |  95.88 |   1 | 10.1007/978-3-642-71114-5_2
            K022 |      0 |     5 | 132.70 |   1 | 10.1007/978-3-642-71114-5_2
            K023 |      0 |     1 |  80.94 |   1 | 10.1007/978-3-642-71114-5_2
            K024 |      0 |     1 | 223.40 |   1 | 10.1007/978-3-642-71114-5_2
            K025 |      0 |     1 | 186.08 |   1 | 10.1007/978-3-642-71114-5_2
            K026 |      0 |     1 | 149.90 |   1 | 10.1007/978-3-642-71114-5_2
            K027 |      0 |     3 |  75.15 |   1 | 10.1007/978-3-642-71114-5_2
            K028 |      0 |     5 |  91.15 |   1 | 10.1007/978-3-642-71114-5_2
            K029 |      0 |     5 | 122.95 |   1 | 10.1007/978-3-642-71114-5_2
            K030 |      0 |     5 | 113.88 |   1 | 10.1007/978-3-642-71114-5_2
            K031 |      0 |     5 |  92.19 |   1 | unverified
            K032 |      0 |     5 | 129.27 |   1 | unverified
            K033 |      0 |     5 | 166.30 |   1 | unverified
            K034 |      0 |     3 | 111.59 |   1 | 10.1007/978-3-642-71114-5_2
            K035 |      0 |     3 | 110.20 |   1 | 10.1007/BF00646936
            K036 |      0 |     3 |  95.20 |   1 | 10.1016/0301-4622(89)80060-2
            K037 |      0 |     1 |  95.40 |   1 | 10.1007/BF00646936
            K038 |      0 |     3 | 110.40 |   1 | 10.1007/978-3-642-71114-5_2
            K039 |      0 |     5 | 212.00 |   1 | 10.1007/978-3-642-71114-5_2
            K040 |      0 |     5 | 211.44 |   0 | 10.1007/978-3-642-71114-5_2
            K041 |      0 |     3 | 133.60 |   1 | 10.1007/BF00646936
            K042 |      0 |     3 | 132.90 |   1 | 10.1007/BF00646936
            K043 |      0 |     5 | 149.45 |   1 | 10.1007/BF00646936
            K044 |      0 |     5 | 177.50 |   1 | 10.1007/BF00646936
            K045 |      0 |     5 | 244.00 |   0 | monomer:10.1007/s003960050558
            K046 |      0 |     1 |  55.70 |   1 | 10.1007/978-3-642-71114-5_2
            K047 |      0 |     3 |  87.10 |   1 | 10.1007/978-3-642-71114-5_2
            K048 |      0 |     5 | 119.20 |   1 | 10.1007/978-3-642-71114-5_2
            K049 |      0 |     3 |  74.50 |   1 | 10.1007/978-3-642-71114-5_2
            K050 |      0 |     1 |  89.70 |   1 | 10.1007/978-3-642-71114-5_2
            K051 |      0 |     1 |  90.40 |   1 | 10.1007/BF00646936
            K052 |      0 |     1 | 105.00 |   1 | 10.1007/BF00646936
            K053 |      0 |     3 | 114.90 |   1 | 10.1007/978-3-642-71114-5_2
            K054 |      0 |     5 | 116.10 |   1 | 10.1007/978-3-642-71114-5_2
            K055 |      0 |     3 |  89.80 |   1 | 10.1007/978-3-642-71114-5_2
            K056 |      0 |     5 | 121.60 |   1 | 10.1007/978-3-642-71114-5_2
            K057 |      0 |     3 |  91.68 |   1 | 10.1007/978-3-642-71114-5_2
            K058 |      0 |     5 | 155.40 |   1 | 10.1007/978-3-642-71114-5_2
            K059 |      0 |     1 | 105.35 |   1 | 10.1007/978-3-642-71114-5_2
            K060 |      0 |     1 | 110.54 |   1 | 10.1007/978-3-642-71114-5_2
            K061 |      0 |     1 | 101.29 |   1 | 10.1007/978-3-642-71114-5_2
            K062 |      0 |     1 | 105.92 |   1 | 10.1007/BF00646936
            K063 |      0 |     1 |  47.40 |   1 | 10.1007/978-3-642-71114-5_2
            K064 |      0 |     5 | 111.91 |   1 | 10.1007/978-3-642-71114-5_2
            K065 |      0 |     1 |  66.90 |   1 | 10.1007/978-3-642-71114-5_2
            K066 |      0 |     3 |  98.00 |   1 | 10.1007/978-3-642-71114-5_2
            K067 |      0 |     1 |  99.70 |   1 | 10.1007/978-3-642-71114-5_2
            K068 |      0 |     3 |  88.90 |   1 | 10.1007/978-3-642-71114-5_2
            K069 |      0 |     3 | 113.10 |   1 | 10.1007/BF00646936
            K070 |      0 |     1 |  73.30 |   1 | 10.1007/BF00646936
            K071 |      0 |     1 |  68.92 |   1 | 10.1007/BF00646936
            K072 |      0 |     3 |  99.50 |   1 | 10.1007/BF00646936
            K073 |      0 |     1 |  83.10 |   1 | 10.1007/BF00646936
            K074 |      0 |     3 | 100.82 |   1 | 10.1007/BF00646936
            K075 |      0 |     5 | 133.60 |   1 | 10.1016/j.molliq.2023.123403
            K076 |      0 |     1 |  89.30 |   1 | 10.1007/978-3-642-71114-5_2
            K077 |      0 |     3 |  59.25 |   1 | 10.1007/BF00646936
            K078 |      0 |     5 | 123.38 |   1 | 10.1007/BF00646936
            K079 |      0 |     5 |  94.38 |   1 | 10.1007/BF00646936
            K080 |      0 |     5 | 123.04 |   1 | 10.1007/978-3-642-71114-5_2
            K081 |      0 |     3 |  43.28 |   1 | derived:10.1016/j.jct.2013.11.022
            K082 |      0 |     3 |  60.54 |   1 | 10.1007/978-3-642-71114-5_2
            K083 |      0 |     5 | 107.73 |   1 | 10.1007/978-3-642-71114-5_2
            K084 |      0 |     5 |  73.20 |   1 | 10.1007/978-3-642-71114-5_2
            K085 |      0 |     5 | 104.20 |   1 | 10.1007/978-3-642-71114-5_2
            K086 |      0 |     5 | 136.10 |   1 | 10.1007/978-3-642-71114-5_2
            K087 |      0 |     3 |  98.55 |   1 | unverified
            K088 |      0 |     5 |  76.30 |   1 | unverified
            K089 |      0 |     5 | 112.20 |   1 | unverified
            K090 |      0 |     5 | 266.30 |   1 | 10.1007/s003960050558
            """,
            String,
        )
    ]
end

"""
    calibration_table() -> Vector{Dict{String,String}}

Every row of the bundled `CALIBRATION` as strings, keyed `id`, `name`, `smiles`, `charge`,
`nconf`, `v_meas`, `provenance`, `fit`.
"""
function calibration_table()
    return copy(CALIBRATION)
end

"Electron count of a molecular formula such as C22H42O11, charge-corrected."
function electrons(formula::AbstractString, charge::Integer = 0)::Int
    z = 0
    for m in eachmatch(r"([A-Z][a-z]?)(\d*)", formula)
        z += ELEMENT_Z[m[1]] * (isempty(m[2]) ? 1 : parse(Int, m[2]))
    end
    return z - charge
end

end

using .Tables

"the group-correction model"
module Model

using ...Common
using ..Config
using ..Tables
using ..Layout
using LinearAlgebra
using OrderedCollections: OrderedDict
using Random: AbstractRNG, randperm
using RDKitMinimalLib
using Statistics: std

export BUFFER, GRID, TOL, CH2, ANCHOR, ANCHOR_SMILES, EXTRA_SD, MIN_SD, PATTERNS, NAMES,
    RIDGE_LAMBDA, SD_GROUP, SD_CH2, A0, S0, ALKANOLS, features, calibration, prior, ridge,
    posterior, rms, predictive_sd, coefficient_sd, loo_bayes, kfold_bayes, fit_arrays,
    fit, load_model, correction, combine, conformer_error, total_sd, estimate, anchored,
    holdout

"""3D-RISM box buffer (A), grid spacing and tolerance."""
const BUFFER, GRID, TOL = "25", "0.5", "1e-6"

"""CH2 increment, cm3/mol (measured sulfonates, PEG)."""
const CH2 = 15.93

"""Decyl beta-maltoside is the validation anchor."""
const ANCHOR, ANCHOR_SMILES = ("DM", 373.3, 3.9),
"CCCCCCCCCCO[C@H]1[C@@H]([C@H]" *
"([C@@H]([C@H](O1)CO)O[C@@H]2[C@@H]([C@H]([C@@H]([C@H](O2)CO)O)O)O)O)O"

""""Extra variance terms in quadrature (cm3/mol)"."""
const EXTRA_SD, MIN_SD = 2.0, 4.0

"""
Group features of the correction: the value is the SMARTS, or `nothing` for the ring
count.
"""
const PATTERNS = [
    "CH3_CH2" => "[CX4;H2,H3]",
    "CH_C" => "[CX4;H1,H0]",
    "OH" => "[OX2H]",
    "ether_O" => "[OX2;H0]",
    "carbonyl_O" => "[OX1]=[#6,#16]",
    "N_neutral" => "[NX3;+0]",
    "arom_C" => "[c]",
    "charged" => "[+,-]",
    "S" => "[#16]",
    "nitrile" => "[CX2]#[NX1]",
    "rings" => nothing,
]

const NAMES = first.(PATTERNS)
const RIDGE_LAMBDA = 1e-3

"""
Bayesian priors: the CH2 correction is centred on CH2 minus the RISM slope per CH2
(fitted on the n-alkanols of the set); every other group on 0, sd 5;
s ~ InvGamma(2, 2*3^2).
"""
const SD_GROUP, SD_CH2, A0, S0, ALKANOLS = 5.0,
1.5,
2.0,
3.0,
Dict(
    "ethanol"    => 2,
    "1-propanol" => 3,
    "1-butanol"  => 4,
    "1-pentanol" => 5,
    "1-hexanol"  => 6,
)

"""
    features(smiles) -> Vector{Float64}

Group counts (`NAMES` order) of a molecule: SMARTS matches (RDKit, unique) and the ring
count.
"""
function features(smiles::AbstractString)::Vector{Float64}
    m = get_mol(smiles)
    m === nothing && throw(ToolError("pmv: RDKit cannot read the SMILES $smiles", 1))
    return [
        p === nothing ? Float64(get_descriptors(m)["NumRings"]) :
        Float64(length(get_substruct_matches(m, get_qmol(p)))) for (_, p) in PATTERNS
    ]
end

"""
    calibration(; fit_only = true, res = nothing) -> (rows, X, y, R)

The rows of the calibration set with a finished RISM run (RISM name = the id column);
rows with fit = 0 are held out unless `fit_only` is false. `y = V - R`.
"""
function calibration(; fit_only::Bool = true, res = nothing)
    res = res === nothing ? read_results() : res
    rows = Dict{String,String}[]
    X = Vector{Float64}[]
    y = Float64[]
    R = Float64[]
    for r in calibration_table()
        (!haskey(res, r["id"]) || (fit_only && r["fit"] != "1")) && continue
        push!(rows, r)
        push!(X, features(r["smiles"]))
        push!(R, res[r["id"]][2])
        push!(y, parse(Float64, r["v_meas"]) - R[end])
    end
    return rows, _matrix(X), y, R
end

# The rows `X` as a matrix (zero rows allowed).
_matrix(X) = isempty(X) ? zeros(0, length(NAMES)) : Matrix(reduce(hcat, X)')

"""
    prior(names, R) -> (m0, sd, slope)

Prior centre and sd of the group corrections, and the RISM slope per CH2. `names` are the
solute names (alkanols give the slope), `R` their raw values.
"""
function prior(names, R)
    pts = [(ALKANOLS[n], R[i]) for (i, n) in enumerate(names) if haskey(ALKANOLS, n)]
    slope = CH2
    if length(pts) >= 3
        x = Float64[p[1] for p in pts]
        yy = Float64[p[2] for p in pts]
        slope = ([x ones(length(x))]\yy)[1]
    end
    m0 = zeros(length(NAMES))
    sd = fill(SD_GROUP, length(NAMES))
    k = findfirst(==("CH3_CH2"), NAMES)
    m0[k], sd[k] = CH2 - slope, SD_CH2
    return m0, sd, Float64(slope)
end

"Ridge coefficients and the leave-one-out residuals (hat-matrix shortcut)."
function ridge(X, y, lam = RIDGE_LAMBDA)
    A = X' * X + lam * I
    b = A \ (X' * y)
    W = A \ X'
    h = vec(sum(X' .* W; dims = 1))
    return b, (y - X * b) ./ (1 .- h)
end

"Normal-inverse-gamma posterior (mean, covariance factor, shape, scale)."
function posterior(X, y, m0, sd)
    P0 = Diagonal(1 ./ (sd ./ S0) .^ 2)
    Pn = P0 + X' * X
    Vn = inv(Pn)
    mn = Vn * (P0 * m0 + X' * y)
    an = A0 + length(y) / 2
    bn = A0 * S0^2 + 0.5 * (y' * y + m0' * P0 * m0 - mn' * Pn * mn)
    return mn, Vn, an, bn
end

"Root mean square of a sequence."
rms(e) = sqrt(sum(abs2, e) / length(e))

"Predictive sd of the correction of a molecule with group counts `x`."
predictive_sd(x, Vn, an, bn) = sqrt(bn / an * (1 + x' * Vn * x))

"Posterior sd of each coefficient (Student-t marginal)."
coefficient_sd(Vn, an, bn) = sqrt.(bn / an .* diag(Vn) .* an / (an - 1))

"Leave-one-out residual and standardised residual (z) of the Bayesian fit."
function loo_bayes(X, y, m0, sd)
    res = Float64[]
    z = Float64[]
    for i in eachindex(y)
        k = [1:(i-1); (i+1):length(y)]
        m, V, a, b = posterior(X[k, :], y[k], m0, sd)
        push!(res, y[i] - X[i, :]' * m)
        push!(z, res[end] / predictive_sd(X[i, :], V, a, b))
    end
    return res, z
end

"numpy's `array_split` of `idx` into `k` parts: the first `length % k` parts one longer."
function _array_split(idx, k)
    n, r = divrem(length(idx), k)
    parts = Vector{Vector{Int}}()
    start = 1
    for i in 1:k
        len = n + (i <= r ? 1 : 0)
        push!(parts, idx[start:(start+len-1)])
        start += len
    end
    return parts
end

"Out-of-fold residuals of the Bayesian fit for one random k-fold split."
function kfold_bayes(X, y, m0, sd, k, rng::AbstractRNG)
    out = zeros(length(y))
    for f in _array_split(randperm(rng, length(y)), k)
        keep = setdiff(1:length(y), f)
        m = posterior(X[keep, :], y[keep], m0, sd)[1]
        out[f] = y[f] - X[f, :] * m
    end
    return out
end

"Bayesian and ridge fits with every quantity the reports need."
function fit_arrays(X, y, m0, sd)
    mn, Vn, an, bn = posterior(X, y, m0, sd)
    rb, loo_r = ridge(X, y)
    loo_b, z = loo_bayes(X, y, m0, sd)
    return (; mn, Vn, an, bn, rb, fitted = X * mn, loo_bayes = loo_b, loo_ridge = loo_r, z)
end

# A Python-style dictionary line of `pairs` (`{'n': 88, 'x': 2.5}`), as the fit prints it.
function _pydict(pairs)
    shown = [
        "'$k': " * (v isa Integer ? string(v) : pyfloat(v)) for (k, v) in pairs
    ]
    return "{" * join(shown, ", ") * "}"
end

"""
    fit() -> OrderedDict

Ridge (sanity check) and conjugate Bayesian fit; writes `<out>/coefficients.json`, prints
the RMS numbers and returns the dictionary written.
"""
function fit()
    rows, X, y, R = calibration()
    names = [r["name"] for r in rows]
    m0, sd, slope = prior(names, R)
    f = fit_arrays(X, y, m0, sd)
    byname(v) = OrderedDict(zip(NAMES, Float64.(v)))
    out = OrderedDict{String,Any}(
        "n" => length(y),
        "features" => NAMES,
        "smarts" => OrderedDict(PATTERNS),
        "ridge_lambda" => RIDGE_LAMBDA,
        "rism_ch2_slope" => slope,
        "prior_centre" => byname(m0),
        "prior_sd" => byname(sd),
        "A0" => A0,
        "S0" => S0,
        "bayes_mean" => byname(f.mn),
        "bayes_an" => f.an,
        "bayes_bn" => f.bn,
        "bayes_Vn" => [Float64.(f.Vn[i, :]) for i in axes(f.Vn, 1)],
        "ridge_coef" => byname(f.rb),
        "raw_bias_rms_R_minus_V" => rms(y),
        "in_rms_bayes" => rms(y - f.fitted),
        "in_rms_ridge" => rms(y - X * f.rb),
        "loo_rms_bayes" => rms(f.loo_bayes),
        "loo_rms_ridge" => rms(f.loo_ridge),
        "loo_z_sd_bayes" => std(f.z; corrected = false),
        "loo" => OrderedDict(
            n => [a, b] for (n, a, b) in zip(names, f.loo_bayes, f.loo_ridge)
        ),
    )
    write(joinpath(ensure_out(), "coefficients.json"), dumps(out; indent = 1))
    keys = ("n", "in_rms_bayes", "in_rms_ridge", "loo_rms_bayes", "loo_rms_ridge",
        "loo_z_sd_bayes")
    println(_pydict([k => out[k] for k in keys]))
    return out
end

"<out>/coefficients.json (written by `fit`) as nested dictionaries."
function load_model()
    p = joinpath(out_dir(), "coefficients.json")
    isfile(p) && return loads(read(p, String))
    throw(ToolError("pmv: $p does not exist: run `bysl extract pmv fit` first", 1))
end

"Posterior mean and predictive sd (cm3/mol) of V - R_mean for one molecule."
function correction(smiles, model)
    x = features(smiles)
    mn = Float64[model["bayes_mean"][k] for k in NAMES]
    Vn = _matrix([Float64.(r) for r in model["bayes_Vn"]])
    return x' * mn, predictive_sd(x, Vn, model["bayes_an"], model["bayes_bn"])
end

"Quadrature sum."
combine(sds...) = sqrt(sum(s * s for s in sds))

"Standard error of a conformer mean (0 for one conformer)."
conformer_error(n, csd) = isnan(csd) ? 0.0 : csd / sqrt(n)

"sd of a direct estimate: predictive, conformer error, unmodelled chemistry."
total_sd(psd, n, csd) = max(MIN_SD, combine(psd, conformer_error(n, csd), EXTRA_SD))

"V = R_mean + correction (direct); sd from the predictive sd, conformer SD, extra."
function estimate(name, smiles, model, res)
    n, mu, csd = res[name]
    corr, psd = correction(smiles, model)
    return mu + corr, total_sd(psd, n, csd)
end

"""
    anchored(name, anchor, res; class_sd = 2.0) -> (V, sd)

V = V_a + (R_t - R_a): the difference against an anchored analogue, same pipeline.
`anchor` is (rism_name, V, sd). sd = anchor sd, both conformer errors of the mean, the
class term and the unmodelled-chemistry term in quadrature (at least `MIN_SD`). The
group-correction difference is not added: it is zero within one family.
"""
function anchored(name, anchor, res; class_sd = 2.0)
    an, av, asd = anchor
    n, mu, csd = res[name]
    n2, mu2, csd2 = res[an]
    sd = combine(asd, conformer_error(n, csd), conformer_error(n2, csd2), class_sd,
        EXTRA_SD)
    return av + (mu - mu2), max(MIN_SD, sd)
end

"Direct vs anchored estimates of the held-out solutes (fit = 0) and the anchor."
function holdout(model, res)
    out = OrderedDict{String,Any}()
    for r in calibration_table()
        (r["fit"] != "0" || !haskey(res, r["id"]) || !haskey(res, ANCHOR[1])) && continue
        vd, _ = estimate(r["id"], r["smiles"], model, res)
        va, _ = anchored(r["id"], ANCHOR, res)
        meas = parse(Float64, r["v_meas"])
        out[r["name"]] = OrderedDict(
            "measured" => meas,
            "direct" => vd,
            "direct_err" => vd - meas,
            "anchored_on_DM" => va,
            "anchored_err" => va - meas,
        )
    end
    if haskey(res, ANCHOR[1])
        vd, sdd = estimate(ANCHOR[1], ANCHOR_SMILES, model, res)
        out["decyl maltoside (anchor, direct model)"] = OrderedDict(
            "measured" => ANCHOR[2],
            "direct" => vd,
            "direct_sd" => sdd,
            "direct_err" => vd - ANCHOR[2],
        )
    end
    return out
end

end

using .Model

"a polymers row for a finished run and its wiring into the tables"
module Rows

using ...Common
using ..Config
using ..Tables
using ..Model
using ..Layout
using OrderedCollections: OrderedDict

export make_row, wire, RUN_NOTE

const RUN_NOTE =
    "AmberTools 3D-RISM, cSPC/E, KH, GAFF2/AM1-BCC, RDKit conformers, " *
    "(bysl extract pmv) [monomer, infinite dilution, not micellar]"

"""
    make_row(name, smiles, names, aliases, mdl, res) -> Dict

A polymers row for the finished RISM run `name`: raw conformer mean plus the Bayesian
correction, basis `estimated`, note as the tables carry it. `names` is (common, iupac,
formula, charge).
"""
function make_row(name, smiles, names, aliases, mdl, res)
    common, iupac, formula, charge = names
    n, mu, csd = res[name]
    v, sd = estimate(name, smiles, mdl, res)
    corr, psd = correction(smiles, mdl)
    note =
        "3D-RISM raw value $(ff(1, mu)) (SD $(ff(1, csd)) over $n conformers) plus the " *
        "Bayesian group correction $(ffs(1, corr)) (predictive sd $(ff(1, psd))); sd in " *
        "quadrature of predictive sd, conformer error and unmodelled chemistry " *
        "$EXTRA_SD (at least $MIN_SD); $RUN_NOTE"
    return Dict{String,Any}(
        "common" => common,
        "iupac" => iupac,
        "formula" => formula,
        "charge" => charge,
        "v" => round(v; digits = 2),
        "sd" => round(sd; digits = 2),
        "basis" => "estimated",
        "note" => note,
        "aliases" => aliases,
    )
end

"The JSON text of the entries of `sel` (name => [z, v, sd]) as polymers.json is laid out."
_sel_text(sel) = dumps(sel; indent = 2)

"""
    wire(rows, apply) -> Nothing

Appends the rows to polymers.tsv, polymers.json and polymers_lookup.json. Idempotent: a
row whose iupac key exists is skipped; an alias is added only if no lookup (Polymers or
NonBiological) already owns it. Without `apply` it only reports.
"""
function wire(rows, apply::Bool)
    pdir = POLYMERS()
    tsv, js, lk = (
        joinpath(pdir, f) for f in
        ("polymers.tsv", "polymers.json", "polymers_lookup.json")
    )
    nb = loads(read(NONBIO_LOOKUP(), String))
    sel = loads(read(js, String))
    ltext = read(lk, String)
    look = loads(ltext)
    text = read(tsv, String)
    !isempty(text) && !endswith(text, "\n") && (text *= "\n")
    groups = OrderedDict{String,String}[]
    for r in rows
        key = lowercase(r["iupac"])
        if haskey(sel, key)
            println("skip existing ", key)
            continue
        end
        z = electrons(r["formula"], r["charge"])
        sel[key] = Any[z, r["v"], r["sd"]]
        fields = [r["common"], r["iupac"], r["formula"], string(r["charge"]),
            pyfloat(r["v"])]
        text *= join([fields; pyfloat(r["sd"]); r["basis"]; r["note"]], "\t") * "\n"
        group = OrderedDict{String,String}()
        for alias in [key; r["common"]; r["aliases"]]
            a = lowercase(alias)
            if (haskey(look, a) && look[a] != key) || haskey(nb, a)
                println("alias taken, skipped: ", a)
                continue
            end
            look[a] = key
            group[a] = key
        end
        push!(groups, group)
        println("row ", r["common"], ": Z ", z, ", V ", pyfloat(r["v"]), " +- ",
            pyfloat(r["sd"]), " (", r["basis"], ")")
    end
    apply || return nothing
    write(tsv, text)
    write(js, _sel_text(sel))
    body = rstrip(chopsuffix(rstrip(ltext), "}"))
    for g in groups   # one blank-line-separated group per row, as the file is laid out
        lines = [dumps(k) * ": " * dumps(v) for (k, v) in g]
        body *= ",\n\n  " * join(lines, ",\n  ")
    end
    write(lk, body * "\n}")
    return nothing
end

end

using .Rows

"the 3D-RISM driver"
module Rism

using ...Common
using ..Config
using ..Tables
using ..Model
using ..Layout
using Base.ScopedValues: with
using Printf: @sprintf
using RDKitMinimalLib

export run_molecule, batch, conformer_volume, embed, xvv, antechamber_command,
    rism_command, A3_TO_CM3, LEAP_INPUT, sh_log

const A3_TO_CM3 = 0.602214076   # A^3 per molecule -> cm3/mol

"The tleap script of one conformer."
const LEAP_INPUT =
    "source leaprc.gaff2\nm = loadmol2 x.mol2\nloadamberparams x.frcmod\n" *
    "saveamberparm m x.prmtop x.inpcrd\nsavepdb m x.pdb\nquit\n"

"The solvent susceptibility file (cSPC/E, KH)."
xvv() = joinpath(amber_home(), "dat", "rism1d", "cSPCE", "cSPCE_kh.xvv")

"The antechamber command of one conformer: AM1-BCC charges, GAFF2."
antechamber_command(charge) =
    "antechamber -i x.mol -fi mdl -o x.mol2 -fo mol2 -c bcc -nc $charge " *
    "-at gaff2 -rn MOL -s 0 -pf y"

"The rism3d.snglpnt command of one conformer."
rism_command(xvvfile = xvv()) =
    "rism3d.snglpnt --pdb x.pdb --rst x.inpcrd --prmtop x.prmtop --xvv $xvvfile " *
    "--closure kh --buffer $BUFFER --grdspc $GRID,$GRID,$GRID " *
    "--tolerance $TOL --maxstep 5000 --centering 2 --verbose 1"

"""
    sh_log(cmd, cwd, log) -> Int

Runs the shell command `cmd` in `cwd` with the AmberTools environment, its output in the
file `log` there; the exit status (0 is success).
"""
function sh_log(cmd::AbstractString, cwd::AbstractString, log::AbstractString)::Int
    # `nice` wraps the whole shell, so every program of the command inherits the level
    # (setpriority on a Julia thread would only reach that thread, not the children).
    level = Sys.iswindows() ? 0 : NICE[]
    shell = level > 0 ? `nice -n $level sh -c $cmd` : `sh -c $cmd`
    c = addenv(Cmd(ignorestatus(shell); dir = cwd), amber_env()...)
    open(joinpath(cwd, log), "w") do io
        return run(pipeline(c; stdout = io, stderr = io)).exitcode
    end
end

"""
    conformer_volume(c, molblock, charge) -> Union{Float64,Nothing}

One conformer in the folder `c` (antechamber AM1-BCC/GAFF2, tleap, rism3d.snglpnt): the
partial molar volume in cm3/mol, or `nothing` when a step failed. `molblock` is a function
returning the MDL text of the conformer (called only when the job is not done yet); a
finished job (`result.txt`) is read back instead of being run again.
"""
function conformer_volume(c, molblock, charge)
    done = joinpath(c, "result.txt")
    isfile(done) && return parse(Float64, read(done, String))
    block = molblock()
    block === nothing && return nothing
    write(joinpath(c, "x.mol"), block)
    bad = sh_log(antechamber_command(charge), c, "antechamber.log")
    bad |= sh_log("parmchk2 -i x.mol2 -f mol2 -o x.frcmod -s gaff2", c, "parmchk2.log")
    write(joinpath(c, "leap.in"), LEAP_INPUT)
    bad |= sh_log("tleap -f leap.in", c, "tleap.log")
    (bad != 0 || !isfile(joinpath(c, "x.prmtop"))) && return nothing
    sh_log(rism_command(), c, "rism.log")
    m = match(r"(?m)^rism_partialMolarVolume\s+([-\d.eE+]+)",
        read(joinpath(c, "rism.log"), String))
    m === nothing && return nothing
    v = parse(Float64, m[1]) * A3_TO_CM3
    write(done, string(v))
    return v
end

"""
    embed(smiles, seed) -> Union{String,Nothing}

The MDL text of one 3D conformer of the molecule (hydrogens added, ETKDG from `seed`; if
that fails, again from random coordinates, which large flexible molecules such as LMNG
need), or `nothing`. RDKitMinimalLib has no MMFF and no multi-conformer call, so the
conformers of a run come from different seeds and are not force-field relaxed.
"""
function embed(smiles::AbstractString, seed::Integer)
    for random in (false, true)
        m = get_mol(smiles)
        m === nothing && return nothing
        add_hs(m)
        ok = try
            set_3d_coords(m,
                Dict{String,Any}("randomSeed" => seed, "useRandomCoords" => random))
        catch
            0
        end
        ok != 0 && return get_molblock(m)
    end
    return nothing
end

"""
    run_molecule(name, smiles, nconf, charge, seed = 1) -> Union{Tuple,Nothing}

`nconf` ETKDG conformers (seeds `seed` ... `seed + nconf - 1`), 3D-RISM each; appends the
mean and SD to results.tsv and returns them (`nothing` when no conformer finished).
"""
function run_molecule(name, smiles, nconf, charge, seed = 1)
    d = joinpath(work_dir(), name)
    mkpath(d)
    vs = Float64[]
    for i in 0:(nconf-1)
        c = joinpath(d, @sprintf("c%02d", i))
        mkpath(c)
        v = conformer_volume(c, () -> embed(smiles, seed + i), charge)
        if v === nothing
            println("FAIL ", name, " ", i)
        else
            push!(vs, v)
            println(name, " ", i, " ", v)
        end
        flush(stdout)
    end
    isempty(vs) && return nothing
    mu = sum(vs) / length(vs)
    sd = length(vs) > 1 ? sqrt(sum((x - mu)^2 for x in vs) / (length(vs) - 1)) : NaN
    p = results_path()
    mkpath(dirname(p))
    open(p, "a") do f
        write(
            f,
            string(name, "\t", length(vs), "\t", ff(2, mu), "\t", ff(2, sd), "\t",
                BUFFER, "\t", GRID, "\t", TOL, "\n"),
        )
    end
    println("RESULT ", name, " n=", length(vs), " mean=", ff(2, mu), " sd=", ff(2, sd))
    flush(stdout)
    return mu, sd
end

"""
    batch(path, tiers = String[]; nice = 0)

Runs the rows of a spec TSV (columns id, smiles, charge, nconf; a tier column filters
with `tiers`, any of them, none meaning every row) in file order, the RISM name being the
id. Sequential, resumable: an id already in results.tsv is skipped, so a stopped batch is
simply started again. A job that fails (no conformer finished, or an error) is reported
as `FAILED id` on stderr and the batch goes on. `nice` (1 to 19) lowers the priority of the
AmberTools programs, with `nice -n N` (`--nice`). Returns the ids that
failed.
"""
function batch(path, tiers = String[]; nice::Integer = 0)
    done = read_results()
    failed = String[]
    with(NICE => Int(nice)) do
        for r in read_tsv(path)
            (
                haskey(done, r["id"]) ||
                (!isempty(tiers) && !(get(r, "tier", nothing) in tiers))
            ) && continue
            println("run ", r["id"])
            ok = try
                run_molecule(r["id"], r["smiles"], parse(Int, r["nconf"]),
                    parse(Int, r["charge"])) !== nothing
            catch err
                println(stderr, "error in ", r["id"], ": ", sprint(showerror, err))
                false
            end
            ok || (println(stderr, "FAILED ", r["id"]); push!(failed, r["id"]))
        end
    end
    return failed
end

end

using .Rism

"read-only reports on the fit, the runs and the tables"
module Diagnostics

using ...Common
using ..Config
using ..Tables
using ..Model
using ..Layout
using LinearAlgebra
using OrderedCollections: OrderedDict
using Printf: @sprintf
using Random: MersenneTwister, randperm
using Statistics: mean, median, std

export REPORTS, NOTE_RE, check_row, match_runs, emit, status, tables_report, main

const SPREAD_FLAG = 1.0   # cm3/mol: conformer SD above this is flagged
const Z_FLAG = 2.5        # |LOO z| above this is flagged
# The note `Rows.make_row` writes; only such rows can be reproduced from a run.
const NOTE_RE = Regex(
    "3D-RISM raw value (?<raw>[-\\d.]+) \\(SD (?<sd>[-\\d.]+|nan) over (?<n>\\d+) " *
    "conformers\\) plus the Bayesian group correction (?<corr>[-+\\d.]+) " *
    "\\(predictive sd (?<psd>[\\d.]+)\\)",
)

const USAGE = """
Read-only reports on the fit, the runs and the tables.

    bysl extract pmv --out DIR diagnostics REPORT [options]

    residuals     per solute and per group feature: fit, LOO residual, z score
    cv            LOO and repeated k-fold RMS (Bayesian and ridge); --k N, --repeats N
    holdout       held-out solutes (fit = 0) against the model, direct and anchored
    conformers    spread of the conformer volumes of every run; --flag SD
    coefficients  prior, posterior mean and sd, ridge coefficient per group feature
    tables        every `estimated` row of the tables against results.tsv; --specs FILE
    status        rows with no finished run (calibration, tables, spec files); --specs FILE
    all           residuals, cv, holdout, conformers, coefficients, tables

Each prints an aligned table and writes it to <out>/diagnostics/<report>.tsv.
"""

# The value after `flag` in the argument list, or nothing.
function _after(a, flag)
    i = findfirst(==(flag), a)
    return i === nothing || i == length(a) ? nothing : a[i+1]
end

"A table cell as text: strings as they are, numbers with two decimals."
_cell(c) = c isa AbstractString ? String(c) : ff(2, c)

"Pads `s` to `w` characters on the right (by character count, as Python's `ljust`)."
_ljust(s, w) = s * " "^max(0, w - length(s))

"""
    emit(report, header, rows, title = nothing)

Prints an aligned table and writes it to `<out>/diagnostics/<report>.tsv`.
"""
function emit(report, header, rows, title = nothing)
    cells = [String[_cell(c) for c in r] for r in rows]
    widths = [
        max(length(h),
            (length(r[i]) for r in cells)...) for (i, h) in enumerate(header)
    ]
    title === nothing || println("\n== ", title)
    println(join([_ljust(h, w) for (h, w) in zip(header, widths)], "  "))
    for r in cells
        println(join([_ljust(c, w) for (c, w) in zip(r, widths)], "  "))
    end
    d = joinpath(ensure_out(), "diagnostics")
    mkpath(d)
    body = [join(header, "\t"); [join(r, "\t") for r in cells]]
    write(joinpath(d, "$report.tsv"), join(body, "\n") * "\n")
    return nothing
end

# The fitted calibration: (rows, names, X, y, R, prior centre, prior sd, fit).
function setup()
    rows, X, y, R = calibration()
    length(y) < length(NAMES) && throw(
        ToolError(
            "pmv: only $(length(y)) calibration solutes have a run in $(results_path()): " *
            "nothing to diagnose", 1),
    )
    names = [r["name"] for r in rows]
    m0, sd, _ = prior(names, R)
    return rows, names, X, y, R, m0, sd, fit_arrays(X, y, m0, sd)
end

"Per solute (worst LOO first) and per group feature residuals."
function residuals(_a)
    rows, names, X, y, R, _, _, f = setup()
    out = Vector{Any}[]
    for i in sortperm(-abs.(f.loo_bayes))
        flag = abs(f.z[i]) > Z_FLAG ? "!" : ""
        push!(
            out,
            Any[rows[i]["id"], names[i], R[i], y[i]+R[i], y[i]-f.fitted[i],
                f.loo_bayes[i], f.loo_ridge[i], f.z[i], flag],
        )
    end
    emit("residuals_solutes",
        ["id", "name", "R", "V_meas", "resid_in", "resid_loo", "resid_loo_ridge", "z",
            "flag"],
        out, "per solute (V_meas - R - x.beta; worst leave-one-out first)")
    g = Vector{Any}[]
    for (j, k) in enumerate(NAMES)
        m = X[:, j] .> 0
        if any(m)
            push!(
                g,
                Any[k, string(sum(m)), f.mn[j], mean((y-f.fitted)[m]),
                    rms((y-f.fitted)[m]), rms(f.loo_bayes[m])],
            )
        else
            push!(g, Any[k, "0", f.mn[j], NaN, NaN, NaN])
        end
    end
    emit("residuals_groups",
        ["group", "n_solutes", "coef", "mean_resid_in", "rms_resid_in", "rms_resid_loo"],
        g, "per group feature (solutes that contain the group)")
    return 0
end

"LOO and repeated k-fold RMS; options --k N (default 10), --repeats N (default 20)."
function cv(a)
    k = parse(Int, something(_after(a, "--k"), "10"))
    reps = parse(Int, something(_after(a, "--repeats"), "20"))
    _, _, X, y, _, m0, sd, f = setup()
    rng = MersenneTwister(0)
    folds = [rms(kfold_bayes(X, y, m0, sd, k, rng)) for _ in 1:reps]
    ridge_folds = Float64[]
    for _ in 1:reps
        e = zeros(length(y))
        for s in Model._array_split(randperm(rng, length(y)), k)
            keep = setdiff(1:length(y), s)
            b, _ = ridge(X[keep, :], y[keep])
            e[s] = y[s] - X[s, :] * b
        end
        push!(ridge_folds, rms(e))
    end
    sdp(v) = std(v; corrected = false)
    emit("cv", ["scheme", "bayes_rms", "ridge_rms", "note"],
        [
            Any["in-sample", rms(y - f.fitted), rms(y - X * f.rb), "n=$(length(y))"],
            Any["LOO", rms(f.loo_bayes), rms(f.loo_ridge), ""],
            Any["$k-fold mean", mean(folds), mean(ridge_folds), "$reps random splits"],
            Any["$k-fold sd over splits", sdp(folds), sdp(ridge_folds), ""],
        ],
        "cross-validation (RMS of V_meas - V_predicted, cm3/mol)")
    return 0
end

"The held-out table: direct and anchored errors."
function holdout_report(_a)
    h = holdout(load_model(), read_results())
    if isempty(h)
        println("no held-out solute (fit = 0) has a run, or the anchor DM has none")
        return 1
    end
    out = [
        Any[n, d["measured"], d["direct"], d["direct_err"],
            get(d, "anchored_on_DM", NaN), get(d, "anchored_err", NaN)] for (n, d) in h
    ]
    emit("holdout",
        ["solute", "measured", "direct", "direct_err", "anchored",
            "anchored_err"], out, "held-out solutes (not in the fit)")
    return 0
end

"Conformer spread of every run; `--flag X` changes the SD threshold (default 1.0)."
function conformers(a)
    flag = parse(Float64, something(_after(a, "--flag"), string(SPREAD_FLAG)))
    res = read_results()
    out = Vector{Any}[]
    # a stable sort, so equal spreads keep the order of results.tsv
    order = sort(collect(res); by = kv -> -(isnan(kv[2][3]) ? 0.0 : kv[2][3]),
        alg = Base.Sort.MergeSort)
    for (name, (n, mu, sd)) in order
        sem = conformer_error(n, sd)
        why = n == 1 ? "single conformer, no spread" : sd > flag ? "SD above threshold" : ""
        push!(out, Any[name, string(n), mu, sd, sem, why])
    end
    emit("conformers", ["run", "n", "mean", "sd", "sem", "flag"], out,
        "conformer spread (flag: SD > $(pyfloat(flag)) or one conformer); " *
        "$(length(res)) runs")
    spread = [v[3] for v in values(res) if !isnan(v[3])]
    if !isempty(spread)
        println("median SD ", ff(2, median(spread)), ", max ", ff(2, maximum(spread)),
            ", ", count(v -> v[1] == 1, values(res)), " single-conformer runs")
    end
    return 0
end

"Coefficient table with posterior sds (marginal Student-t)."
function coefficients(_a)
    _, _, _, _, _, m0, sd, f = setup()
    psd = coefficient_sd(f.Vn, f.an, f.bn)
    out = [
        Any[k, m0[j], sd[j], f.mn[j], psd[j], (f.mn[j]-m0[j])/sd[j], f.rb[j]]
        for (j, k) in enumerate(NAMES)
    ]
    emit("coefficients",
        ["group", "prior_mean", "prior_sd", "post_mean", "post_sd",
            "shift_in_prior_sd", "ridge"], out,
        "coefficients (cm3/mol per group); residual scale s = " *
        ff(2, sqrt(f.bn / (f.an - 1))))
    return 0
end

# (table, row) of every `estimated` row of the polymers and nonbiological tables.
estimated_rows() = [
    (t, r) for (t, p) in TABLES() for r in read_tsv(p) if get(r, "basis", nothing) ==
                        "estimated"
]

"Names of the runs with n conformers and a mean within rounding of `raw`."
match_runs(res, raw, n) =
    [k for (k, (kn, mu, _)) in res if kn == n && abs(mu - raw) <= 0.051]

"id -> smiles from a spec TSV (the `batch` format)."
spec_smiles(path) = Dict(r["id"] => r["smiles"] for r in read_tsv(path))

"""
    check_row(table, r, res, smiles) -> (status, run, detail)

One estimated row: status OK, MISMATCH, NO_RUN or FREE_TEXT (the note is not the format
`make_row` writes, so the row cannot be reproduced).
"""
function check_row(table, r, res, smiles)
    m = match(NOTE_RE, get(r, "doi", ""))
    m === nothing && return "FREE_TEXT", "",
    "note is not the format `row` writes (hand-derived or anchored)"
    raw, n = parse(Float64, m[:raw]), parse(Int, m[:n])
    corr, psd = parse(Float64, m[:corr]), parse(Float64, m[:psd])
    csd = m[:sd] == "nan" ? NaN : parse(Float64, m[:sd])
    runs = match_runs(res, raw, n)
    isempty(runs) && return "NO_RUN", "",
    "no run with n=$n and mean $(pyfloat(raw)) in the results"
    v = parse(Float64, r["v0_cm3_per_mol"])
    sd = parse(Float64, r["uncertainty_cm3_per_mol"])
    bad = String[]
    abs(raw + corr - v) > 0.11 &&
        push!(bad, "V $(pyfloat(v)) != raw+corr $(ff(2, raw + corr))")
    abs(total_sd(psd, n, csd) - sd) > 0.1 &&
        push!(bad, "sd $(pyfloat(sd)) != $(ff(2, total_sd(psd, n, csd))) from the note")
    drift = ""
    for run in runs
        if haskey(smiles, run)
            c, p = correction(smiles[run], load_model())
            drift =
                "; current model: corr $(ffs(2, c)) (note $(ffs(1, corr))), " *
                "psd $(ff(2, p))"
            abs(c - corr) > 0.06 && push!(bad, "correction drifted to $(ffs(2, c))")
        end
    end
    return isempty(bad) ? "OK" : "MISMATCH", join(runs, "/"), join(bad, "; ") * drift
end

"The counts of the statuses as Python prints a dictionary: {'OK': 66, 'FREE_TEXT': 1}."
_pycounts(counts) = "{" * join(["'$k': $v" for (k, v) in counts], ", ") * "}"

"Checks every estimated row; `--specs FILE` adds SMILES and recomputes corrections."
function tables_report(a)
    res = read_results()
    f = _after(a, "--specs")
    smiles = f === nothing ? Dict{String,String}() : spec_smiles(f)
    out = Vector{Any}[]
    counts = OrderedDict{String,Int}()
    for (t, r) in estimated_rows()
        status, run, detail = check_row(t, r, res, smiles)
        counts[status] = get(counts, status, 0) + 1
        push!(out, Any[status, t, r["common_name"], r["v0_cm3_per_mol"], run, detail])
    end
    emit("tables", ["status", "table", "row", "V", "run", "detail"], out,
        "estimated rows against $(results_path())")
    println(_pycounts(counts))
    return get(counts, "MISMATCH", 0) > 0 || get(counts, "NO_RUN", 0) > 0 ? 1 : 0
end

"Rows with no finished run: calibration solutes, table rows, spec-file rows."
function status(a)
    res = read_results()
    out = Vector{Any}[
        Any["calibration", r["id"], r["name"], r["fit"] == "1" ? "fit" : "holdout"]
        for r in calibration_table() if !haskey(res, r["id"])
    ]
    for (t, r) in estimated_rows()
        s, _, d = check_row(t, r, res, Dict{String,String}())
        s == "NO_RUN" && push!(out, Any[t, r["common_name"], r["v0_cm3_per_mol"], d])
    end
    f = _after(a, "--specs")
    if f !== nothing
        for r in read_tsv(f)
            haskey(res, r["id"]) || push!(out,
                Any["spec", r["id"], first(r["smiles"], 40), get(r, "tier", "")])
        end
    end
    emit("status", ["kind", "id_or_row", "name_or_V", "detail"], out,
        "no finished run in $(results_path()) ($(length(res)) runs there)")
    return 0
end

"residuals, cv, holdout, conformers, coefficients, tables; the worst status."
function all_reports(a)
    worst = 0
    for fn in (residuals, cv, holdout_report, conformers, coefficients, tables_report)
        worst = max(worst, fn(a))
    end
    return worst
end

const REPORTS = [
    "residuals" => residuals,
    "cv" => cv,
    "holdout" => holdout_report,
    "conformers" => conformers,
    "coefficients" => coefficients,
    "tables" => tables_report,
    "status" => status,
    "all" => all_reports,
]

"`diagnostics REPORT [options]`: the exit status."
function main(argv::Vector{String})::Int
    i = isempty(argv) ? nothing : findfirst(p -> first(p) == first(argv), REPORTS)
    if i === nothing
        print(isempty(argv) ? stdout : stderr, USAGE)
        return isempty(argv) ? 0 : 2
    end
    return last(REPORTS[i])(argv[2:end])
end

end

using .Diagnostics

"the checks of the regression on a synthetic table (no RISM, no results.tsv)"
module SelfTest

using ...Common
using ..Config
using ..Tables
using ..Model
using LinearAlgebra
using Random: MersenneTwister
using Statistics: std
using Base.ScopedValues: with

export run_checks, main

const TOL = 1e-8

# Random group counts, a known beta, y = X beta + noise.
function synthetic(rng; n = 60, noise = 2.5)
    X = Float64.(rand(rng, 0:3, n, length(NAMES)))
    beta = 3 .* randn(rng, length(NAMES))
    return X, X * beta + noise .* randn(rng, n), beta
end

"""
    run_checks(; say = println) -> Vector{String}

Runs the checks (the posterior against a normal-equation solution, the hat-matrix LOO
against refits, recovery of a known beta, the alkanol prior slope, the results.tsv reader,
the electron count, the settings and the group counts of a molecule), reporting each with
`say`; the list of failed checks (empty when all pass).
"""
function run_checks(; say = println)
    rng = MersenneTwister(1)
    X, y, beta = synthetic(rng)
    m0 = zeros(length(NAMES))
    sd = fill(1e3, length(NAMES))   # flat prior: posterior mean ~ least squares
    bad = String[]
    function check(ok, what)
        say((ok ? "ok    " : "FAIL  ") * what)
        ok || push!(bad, what)
    end
    f = fit_arrays(X, y, m0, sd)
    check(isapprox(f.mn, X \ y; atol = 1e-4), "flat-prior posterior mean = least squares")
    check(isapprox(f.mn, beta; atol = 1.0), "known beta recovered (noise 2.5)")
    # informative prior: posterior mean = (P0 + X'X)^-1 (P0 m0 + X'y), checked directly
    m1, s1 = ones(length(m0)), fill(2.0, length(m0))
    P0 = Diagonal(1 ./ (s1 ./ S0) .^ 2)
    direct = (P0 + X' * X) \ (P0 * m1 + X' * y)
    check(isapprox(posterior(X, y, m1, s1)[1], direct; atol = TOL), "posterior mean")
    # hat-matrix LOO of ridge against explicit refits
    _, loo = ridge(X, y)
    ref = Float64[]
    for i in eachindex(y)
        k = setdiff(1:length(y), i)
        b, _ = ridge(X[k, :], y[k])
        push!(ref, y[i] - X[i, :]' * b)
    end
    check(isapprox(loo, ref; atol = 1e-6), "ridge LOO shortcut = explicit refits")
    zsd = std(f.z; corrected = false)
    check(0.6 < zsd < 1.5, "LOO z scores are standardised (sd $(round(zsd; digits = 2)))")
    kf = kfold_bayes(X, y, m0, sd, 5, MersenneTwister(2))
    check(rms(kf) < 4.0 && all(isfinite, kf), "k-fold residuals finite and small")
    psd = coefficient_sd(f.Vn, f.an, f.bn)
    check(all(>(0), psd), "coefficient sds positive")
    # prior slope: alkanols with R = 10 + 14 n give slope 14, CH2 centre CH2 - 14
    names = ["ethanol", "1-propanol", "1-butanol", "1-pentanol"]
    m, _, slope = prior(names, [10 + 14 * ALKANOLS[n] for n in names])
    check(abs(slope - 14) < 1e-6 && abs(m[1] - (CH2 - 14)) < 1e-6, "alkanol prior slope")
    check(total_sd(1.0, 1, NaN) == MIN_SD, "sd floor and single conformer")
    check(electrons("C22H42O11") == 262 && electrons("Na", 1) == 10, "electron count")
    mktempdir() do d
        p = joinpath(d, "results.tsv")
        write(p, "A\t2\t1.5\t0.1\t25\t0.5\t1e-6\nA\t3\t2.5\tnan\t25\t0.5\t1e-6\n")
        r = read_results(p)
        check(
            r["A"][1] == 3 && r["A"][2] == 2.5,
            "results.tsv: the last line of a name wins",
        )
        with(OUT => d) do
            check(
                results_path() == joinpath(d, "results.tsv"),
                "the results are written to results.tsv under --out")
        end
    end
    got = features("OCC(O)CC")   # 1,2-butanediol
    want = Dict("CH3_CH2" => 3, "CH_C" => 1, "OH" => 2, "rings" => 0)
    check(all(got[findfirst(==(k), NAMES)] == v for (k, v) in want), "group counts")
    return bad
end

"Prints one line per check; exit status 1 on any failure."
function main(_argv)::Int
    bad = run_checks()
    println(isempty(bad) ? "\nall checks passed" : "\n$(length(bad)) failed")
    return isempty(bad) ? 0 : 1
end

end

# --- the command line

const USAGE = """
3D-RISM partial molar volumes (PMV) with a Bayesian group correction.

    bysl extract pmv --out DIR SUBCOMMAND [args]

    run NAME SMILES NCONF CHARGE [--seed N]
        conformers -> 3D-RISM -> results.tsv                      (heavy, AmberTools)
    batch FILE.tsv [--tier T ...] [--nice N]
        run every row of a spec TSV (id, smiles, charge, nconf [, tier]) in file order,
        one at a time, skipping ids already in results.tsv; --tier (repeatable) keeps
        those tiers, --nice N (1-19) lowers the priority of the AmberTools programs
        (heavy)
    fit
        ridge + Bayesian model on the calibration set -> <out>/coefficients.json
    holdout
        the held-out solutes against the model
    estimate NAME SMILES
        V and sd of a finished run, from the model
    row NAME SMILES COMMON IUPAC FORMULA CHARGE [--alias A ...] [--apply]
        a polymers row for a finished run
    diagnostics REPORT [options]
        residuals | cv | holdout | conformers | coefficients | tables | status | all
        (read-only; `diagnostics` alone lists them)
    status [--specs FILE]
        rows with no finished run (same as `diagnostics status`)
    selftest
        the regression on a synthetic table, no RISM

Global option, before the subcommand: --out DIR (required; no default inside the
repository). Everything the tool generates lives in it: the scratch of the runs
(`DIR/work`), the results file (`DIR/results.tsv`, which `batch` resumes from), the model
(`coefficients.json`) and the diagnostics. Environment: AMBERHOME (default
~/.conda/envs/amber26: antechamber, parmchk2, tleap, rism3d.snglpnt); RDKit is
RDKitMinimalLib.jl (no MMFF, so conformers are ETKDG embeddings from several seeds). A
3D-RISM job takes every core: run one at a time, on a quiet machine. Nothing is written
to the package tables unless `row --apply` is given.
"""

const WHO = "bysl extract pmv"

# The value after `flag` in the argument list `a`, or `default`.
function _opt(a, flag, default = nothing)
    i = findfirst(==(flag), a)
    return i === nothing || i == length(a) ? default : a[i+1]
end

"Every value following `flag` in `a`."
_opt_values(a, flag) = [a[i+1] for (i, x) in enumerate(a) if x == flag && i < length(a)]

"The arguments `a` must hold at least `n` positional values."
_need(a, n, what) = length(a) >= n || fail(WHO, "usage: $what")

function cmd_run(a)
    _need(a, 4, "run NAME SMILES NCONF CHARGE [--seed N]")
    seed = parse(Int, _opt(a, "--seed", "1"))
    return run_molecule(
        a[1], a[2], parse(Int, a[3]), parse(Int, a[4]), seed) === nothing ? 1 : 0
end

function cmd_batch(a)
    _need(a, 1, "batch FILE.tsv [--tier T ...] [--nice N]")
    nice = parse(Int, _opt(a, "--nice", "0"))
    0 <= nice <= 19 || fail(WHO, "--nice must be 0 to 19")
    return isempty(batch(a[1], _opt_values(a, "--tier"); nice)) ? 0 : 1
end

function cmd_fit(_a)
    fit()
    return 0
end

function cmd_holdout(_a)
    println(dumps(holdout(load_model(), read_results()); indent = 1))
    return 0
end

"The results of the run `name`, or nothing after printing why there is none."
function finished(name)
    res = read_results()
    haskey(res, name) && return res
    println(stderr, "no finished run named ", name, " in ", results_path())
    return nothing
end

function cmd_estimate(a)
    _need(a, 2, "estimate NAME SMILES")
    res = finished(a[1])
    res === nothing && return 1
    mdl = load_model()
    v, sd = estimate(a[1], a[2], mdl, res)
    corr, psd = correction(a[2], mdl)
    println(a[1], ": R ", ff(2, res[a[1]][2]), " correction ", ffs(2, corr), " (sd ",
        ff(2, psd), ") -> V ", ff(2, v), " +- ", ff(2, sd))
    return 0
end

function cmd_row(a)
    _need(a, 6, "row NAME SMILES COMMON IUPAC FORMULA CHARGE [--alias A ...] [--apply]")
    res = finished(a[1])
    res === nothing && return 1
    names = (a[3], a[4], a[5], parse(Int, a[6]))
    row = make_row(a[1], a[2], names, _opt_values(a, "--alias"), load_model(), res)
    wire([row], "--apply" in a)
    return 0
end

const COMMANDS = [
    "run" => cmd_run,
    "batch" => cmd_batch,
    "fit" => cmd_fit,
    "holdout" => cmd_holdout,
    "estimate" => cmd_estimate,
    "row" => cmd_row,
    "diagnostics" => Diagnostics.main,
    "status" => a -> Diagnostics.status(a),
    "selftest" => SelfTest.main,
]

"""
    run(argv) -> Int

`bysl extract pmv --out DIR SUBCOMMAND [args]`: the
global options first (they apply to this call only), then the subcommand; the exit status.
"""
function run(argv::Vector{String})::Int
    a = argv
    scoped = Pair[]
    options = ["--out" => OUT]
    while length(a) >= 2 && any(p -> first(p) == a[1], options)
        push!(
            scoped,
            last(options[findfirst(p -> first(p) == a[1], options)]) =>
                abspath(a[2]),
        )
        a = a[3:end]
    end
    if isempty(a) || a[1] in ("-h", "--help")
        usage(USAGE)
        return 0
    end
    i = findfirst(p -> first(p) == a[1], COMMANDS)
    if i === nothing
        println(stderr, WHO, ": unknown subcommand ", a[1])
        return 2
    end
    return with(scoped...) do
        last(COMMANDS[i])(a[2:end])
    end
end

end
