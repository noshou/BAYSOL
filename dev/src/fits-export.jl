# SPDX-License-Identifier: LGPL-3.0-or-later

# `bysl fits export`: turns finished fitting tests (test/fitting_tests/<ID>/) into what
# the terminal interface works with, so nothing has to be typed in by hand: a PROJECT
# (`projects/<ID>/`: `data.tsv`, `data.json`, `buffer.json`, `settings.json`, `models/`,
# `reference-fit/`) and ONE finished RUN of it (`runs/<stamp>.7z`: `run.json`,
# `run.LOG`, and per model its workbook, LOG and figures). The inputs are read back from
# what the fit left: the measured curve from the workbook's `data` sheet, the solution
# conditions from the folder LOG, the buffer solutes from the script's `SOLUTES` block,
# the structures from the fixtures. What a fitting test never made (the terminal plots,
# which only exist on a screen) is absent from the run, so its viewer has no plot tabs.
# An existing project or run is never touched: it is skipped and reported.
module Export

using ..Common
using ..Fixtures
using Dates
using JSON3

const WHO = "bysl fits export"

const USAGE = """
Writes finished fitting tests as projects of the terminal interface, each with one run.

    bysl fits export [ID ...] [options]

    ID          fitting-test folders (default with --all: every one)
    --all       every fitting test that has a workbook
    --out DIR   the projects folder to write into (default: the BAYSOL data folder,
                \$BAYSOL_HOME or \$XDG_DATA_HOME/baysol, then `projects`)
    --dry-run   say what would be written, write nothing

A project that already exists is left alone (reported as skipped); so is an entry whose
workbook, solutes or structure could not be read (the reason is printed). The exit
status is 1 if any entry was skipped for a reason other than an existing project.
"""

# --- the folder LOG ---------------------------------------------------------------

"""
The sections of a folder LOG: the datetime of its last write and, per `=== name ===`,
the rows as an ordered list of (name, value) pairs plus the section's own lines.
"""
function read_log(path::AbstractString)
    stamp = ""
    sections = Pair{String,NamedTuple}[]
    name = nothing
    rows = Pair{String,String}[]
    lines = String[]
    flush() = name === nothing || push!(sections, name => (; rows, lines))
    for line in eachline(path)
        m = match(r"^=== (.+) ===\s*$", line)
        if m !== nothing
            flush()
            name = String(m[1])
            rows = Pair{String,String}[]
            lines = String[]
            continue
        end
        if name === nothing
            startswith(line, "datetime") && (stamp = strip(split(line, '\t'; limit = 2)[2]))
            continue
        end
        push!(lines, line)
        parts = split(line, '\t'; limit = 2)
        length(parts) == 2 && !startswith(line, " ") &&
            push!(rows, String(strip(parts[1])) => String(strip(parts[2])))
    end
    flush()
    return (; stamp, sections)
end

"The value of the row `key` of a LOG section, or `nothing`."
function row_of(section, key)
    for (k, v) in section.rows
        k == key && return v
    end
    return nothing
end

# --- the workbook -----------------------------------------------------------------

"The text of one file of an `.xlsx` (a zip), read by 7-Zip."
unzip(path, entry) = read(`7z x -so $path $entry`, String)

xml_text(s) = replace(
    s,
    "&amp;" => "&", "&lt;" => "<", "&gt;" => ">", "&quot;" => "\"", "&apos;" => "'",
)

"""
The rows of the sheet `sheet` of a workbook as vectors of `Union{Nothing,String,Float64}`
(a blank cell is `nothing`), read from the XML directly (no spreadsheet package).
"""
function read_sheet(path::AbstractString, sheet::AbstractString)
    book = unzip(path, "xl/workbook.xml")
    m = match(Regex("<sheet name=\"$(sheet)\"[^>]*r:id=\"([^\"]+)\""), book)
    m === nothing && error("no sheet `$sheet`")
    rels = unzip(path, "xl/_rels/workbook.xml.rels")
    t = match(Regex("<Relationship [^>]*Id=\"$(m[1])\"[^>]*Target=\"([^\"]+)\""), rels)
    t === nothing && (
        t = match(
            Regex("<Relationship [^>]*Target=\"([^\"]+)\"[^>]*Id=\"$(m[1])\""), rels,
        )
    )
    t === nothing && error("no part for `$sheet`")
    target = String(t[1])
    target = startswith(target, "/") ? target[2:end] : "xl/" * target
    strings = String[]
    if occursin("sharedStrings", unzip_list(path))
        sst = unzip(path, "xl/sharedStrings.xml")
        for si in eachmatch(r"<si>(.*?)</si>"s, sst)
            push!(
                strings,
                xml_text(join((x[1] for x in eachmatch(r"<t[^>]*>(.*?)</t>"s, si[1])), "")),
            )
        end
    end
    xml = unzip(path, target)
    rows = Vector{Any}[]
    for r in eachmatch(r"<row [^>]*>(.*?)</row>"s, xml)
        cells = Any[]
        for c in eachmatch(r"<c r=\"([A-Z]+)\d+\"([^>]*?)(?:/>|>(.*?)</c>)"s, r[1])
            col = 0
            for ch in c[1]
                col = col * 26 + (ch - 'A' + 1)
            end
            while length(cells) < col - 1
                push!(cells, nothing)
            end
            body = c[3] === nothing ? "" : c[3]
            v = match(r"<v>(.*?)</v>"s, body)
            kind = match(r"t=\"(\w+)\"", c[2])
            kind = kind === nothing ? "n" : kind[1]
            val = if kind == "inlineStr"
                xml_text(join((x[1] for x in eachmatch(r"<t[^>]*>(.*?)</t>"s, body)), ""))
            elseif v === nothing
                nothing
            elseif kind == "s"
                strings[parse(Int, v[1])+1]
            elseif kind == "n"
                parse(Float64, v[1])
            else
                xml_text(v[1])
            end
            push!(cells, val)
        end
        push!(rows, cells)
    end
    return rows
end

"The names of the files of a zip, one string (to see whether a part exists)."
unzip_list(path) = read(`7z l -slt $path`, String)

"The sheet names of a workbook."
function sheet_names(path::AbstractString)
    book = unzip(path, "xl/workbook.xml")
    return [xml_text(String(m[1])) for m in eachmatch(r"<sheet name=\"([^\"]+)\"", book)]
end

# --- the script -------------------------------------------------------------------

"""
The solutes of a script's `const SOLUTES = Solute[...]` block as the rows of a
`buffer.json`: `NonBiological(M, σM, "name")` and `Polymer(M, σM, "name")` with the
numbers evaluated (plain arithmetic only), concentrations in mol/L turned into mM.
Throws for anything else.
"""
function script_solutes(text::AbstractString)
    start = findfirst(r"^const SOLUTES\s*=\s*Solute\["m, text)
    start === nothing && error("no `const SOLUTES = Solute[` block")
    i = last(start)
    depth = 1
    j = i
    in_str = false
    while j < lastindex(text) && depth > 0
        j = nextind(text, j)
        c = text[j]
        if c == '"'
            in_str = !in_str
        elseif !in_str
            c == '[' && (depth += 1)
            c == ']' && (depth -= 1)
            # a comment runs to the end of the line (it may hold brackets or quotes)
            if c == '#'
                e = findnext('\n', text, j)
                j = e === nothing ? lastindex(text) : e
            end
        end
    end
    body = text[nextind(text, i):prevind(text, j)]
    body = replace(body, r"#[^\n]*" => "")
    rows = Dict{String,Any}[]
    for m in eachmatch(r"\b(NonBiological|Polymer)\(([^()]*)\)", body)
        args = String.(strip.(split(m[2], ",")))
        length(args) == 3 || error("unexpected solute call `$(m[0])`")
        conc = arith(args[1])
        sigma = arith(args[2])
        name = match(r"^\"(.*)\"$", args[3])
        name === nothing && error("solute name is not a string: `$(m[0])`")
        push!(
            rows,
            Dict{String,Any}(
                "name" => String(name[1]), "mM" => round(conc * 1000; sigdigits = 12),
                "kind" => m[1] == "Polymer" ? "polymer" : "nonbiological",
                "arg" => String(name[1]), "sigmaMm" => round(sigma * 1000; sigdigits = 12),
            ),
        )
    end
    isempty(rows) && error("the SOLUTES block holds no solute")
    return rows
end

"The value of an expression made of numbers and `+ - * /` only (an error otherwise)."
function arith(s::AbstractString)
    ex = Meta.parse(s)
    ok(e) =
        e isa Number || (
            e isa Expr && e.head == :call &&
            e.args[1] in (:+, :-, :*, :/) && all(ok, e.args[2:end])
        )
    ok(ex) || error("not plain arithmetic: `$s`")
    return Float64(eval(ex))
end

"""
The structure file of a workbook (`res`, `res_fit2`, `res_fit3_model1`) in the fixtures
of `id`: `<id>_<suffix>.pdb`, then `<id>_<suffix>_model1.pdb`, and for the plain `res`
the folder's only structure (or the one whose name holds `fit1`). `nothing` if none.
"""
function structure_of(id, suffix, dir, scriptText)
    files = filter(f -> endswith(f, ".pdb") || endswith(f, ".cif"), readdir(dir))
    pick(stem) = (i = findfirst(f -> splitext(f)[1] == stem, files);
        i === nothing ? nothing : joinpath(dir, files[i]))
    if isempty(suffix)
        # the structure the script names: a literal `"<file>.pdb"` of the fixtures
        for m in eachmatch(r"\"([\w.-]+\.(?:pdb|cif))\"", scriptText)
            p = pick(splitext(m[1])[1])
            p === nothing || return p
        end
        length(files) == 1 && return joinpath(dir, only(files))
        return nothing
    end
    for stem in ("$(id)_$(suffix)", "$(id)_$(suffix)_model1")
        p = pick(stem)
        p === nothing || return p
    end
    return nothing
end

# --- one entry --------------------------------------------------------------------

"The `<stamp>` run name of a LOG datetime `DD-MM-YYYY HH:MM:SS ±HHMM`."
function run_name(stamp::AbstractString)
    m = match(r"^(\d\d)-(\d\d)-(\d{4}) (\d\d):(\d\d):(\d\d) ([+-])(\d\d)(\d\d)$", stamp)
    m === nothing && error("unreadable LOG datetime `$stamp`")
    zone = m[7] == "+" && m[8] == "00" && m[9] == "00" ? "UTC" : "LOC"
    return "$(m[4])-$(m[5])-$(m[6])-000_$(zone)_$(m[7])$(m[8])$(m[9])_" *
           "$(m[3])-$(m[2])-$(m[1])"
end

"The instant of a LOG datetime as the UTC `Z` string of `run.json`."
function utc_of(stamp::AbstractString)
    m = match(r"^(\d\d)-(\d\d)-(\d{4}) (\d\d):(\d\d):(\d\d) ([+-])(\d\d)(\d\d)$", stamp)
    local_time = DateTime(
        parse(Int, m[3]), parse(Int, m[2]), parse(Int, m[1]),
        parse(Int, m[4]), parse(Int, m[5]), parse(Int, m[6]),
    )
    offset = Minute((m[7] == "-" ? -1 : 1) * (60 * parse(Int, m[8]) + parse(Int, m[9])))
    return Dates.format(local_time - offset, dateformat"yyyy-mm-dd\THH:MM:SS") * "Z"
end

"A number as the plain text a clean TSV holds (`string`, never a rounded one)."
num(x) = string(x)

"The model workbooks of a fitting-test folder: (workbook path, suffix after `res`)."
function workbooks(dir::AbstractString)
    out = Tuple{String,String}[]
    for f in sort(readdir(dir))
        m = match(r"^res(?:_(.+))?\.xlsx$", f)
        m === nothing ||
            push!(out, (joinpath(dir, f), m[1] === nothing ? "" : String(m[1])))
    end
    return out
end

"""
Exports one fitting test into `projects`. Returns `:written`, `:exists` or throws an
error whose message is the reason it was skipped.
"""
function export_entry(id::AbstractString, projects::AbstractString, dry::Bool)
    # the structures come from the fixtures: unpacked from the archive while this runs
    return Fixtures.with_fixture(id) do fixtures
        _export_entry(id, projects, dry, fixtures)
    end
end

"""
The section `section_name` of the statistics log `statistics-<id>.LOG` in `dir`, as the
text of a one-section file (the datetime of the log's last write, a blank line, the
`=== name ===` section), or `nothing` when there is no such file or section. The file
is read like the run log ([`read_log`](@ref)) but is not a run log: `Report.parse_log`
never sees it.
"""
function statistics_section(dir::AbstractString, id::AbstractString, section_name)
    path = joinpath(dir, "statistics-$id.LOG")
    isfile(path) || return nothing
    log = read_log(path)
    for (name, section) in log.sections
        name == section_name || continue
        return "datetime\t$(log.stamp)\n\n=== $name ===\n" *
               join(section.lines, "\n") * "\n"
    end
    return nothing
end

function _export_entry(id, projects, dry, fixtures)
    dir = joinpath(root(), FIT_DIR, id)
    isdir(dir) || error("no folder $dir")
    isempty(workbooks(dir)) && error("no workbook (res*.xlsx): the fit has not been run")
    logpath = joinpath(dir, "$id.LOG")
    isfile(logpath) || error("no $id.LOG")
    log = read_log(logpath)
    script = joinpath(dir, "$id.jl")
    solutes = script_solutes(read(script, String))
    project = joinpath(projects, id)
    ispath(project) && return :exists
    # every model: its workbook, its LOG section, its structure
    models = NamedTuple[]
    scriptText = read(script, String)
    # the LOG decides which runs exist (workbooks of removed runs may lie around):
    # the section `<folder name>` is `res.xlsx`, a section `X` is `res_X.xlsx`
    for (section_name, section) in log.sections
        row_of(section, "status") == "failed" && continue
        suffix = section_name == id ? "" : section_name
        book = joinpath(dir, isempty(suffix) ? "res.xlsx" : "res_$(suffix).xlsx")
        isfile(book) ||
            error("the LOG has `$section_name` but $(basename(book)) is missing")
        structure = structure_of(id, suffix, fixtures, scriptText)
        structure === nothing &&
            error("$(basename(book)): no structure for `$suffix` in the fixtures")
        push!(
            models,
            (; book, suffix, section_name, section, structure,
                stem = splitext(basename(structure))[1]),
        )
    end
    isempty(models) && error("every run of the LOG failed")
    # two runs of one structure (a script run under two labels) keep distinct names
    seen = Set{String}()
    for (k, m) in enumerate(models)
        stem = m.stem in seen ? "$(m.stem)_$(m.section_name)" : m.stem
        push!(seen, stem)
        models[k] = (; m..., stem)
    end
    first_section = first(models).section
    conditions = (
        ph = row_of(first_section, "ph"), sigma = row_of(first_section, "sigmaPh"),
        temp = row_of(first_section, "temperatureC"),
        energy = row_of(first_section, "energyEv"),
    )
    any(isnothing, values(conditions)) &&
        error("the LOG lacks pH, σ, temperature or energy")
    # the measured curve: the workbook's `data` sheet (q in 1/Å, I, σ)
    rows = read_sheet(first(models).book, "data")
    header = rows[1]
    icol(names...) = findfirst(h -> h isa String && lowercase(h) in names, header)
    qc, ic, sc = icol("q"), icol("i", "intensity"), icol("sigma", "σ", "error")
    (qc === nothing || ic === nothing || sc === nothing) &&
        error("the `data` sheet has no q / I / σ columns (header: $(header))")
    curve = [
        (r[qc], r[ic], r[sc]) for r in rows[2:end]
        if
        length(r) >= max(qc, ic, sc) && all(x -> x isa Float64, (r[qc], r[ic], r[sc]))
    ]
    isempty(curve) && error("the `data` sheet is empty")
    dry && return :dry
    name = run_name(log.stamp)
    mkpath(joinpath(project, "models"))
    open(joinpath(project, "data.tsv"), "w") do io
        for (q, i, s) in curve
            println(io, num(q), "\t", num(i), "\t", num(s))
        end
    end
    write_json(
        joinpath(project, "data.json"),
        Dict(
            "units" => "A-1", "energy" => parse(Float64, conditions.energy),
            "energyUnit" => "eV",
            "source" => "fitting test $id (workbook data sheet)",
            "points" => length(curve),
        ),
    )
    write_json(
        joinpath(project, "buffer.json"),
        Dict(
            "solutes" => solutes, "conc-unit" => "mM",
            "pH" => parse(Float64, conditions.ph),
            "sigmaPh" => parse(Float64, conditions.sigma),
            "temperature" => parse(Float64, conditions.temp),
        ),
    )
    write(joinpath(project, "settings.json"), "{}\n")
    write_json(
        joinpath(project, "project.json"),
        Dict("id" => id, "created" => utc_of(log.stamp)),
    )
    try
        for s in unique(m.structure for m in models)
            cp(s, joinpath(project, "models", basename(s)))
        end
        write_run(project, id, name, log, models, conditions, solutes)
    catch
        # the project this call began is left half written: remove it, so a rerun is clean
        rm(project; recursive = true, force = true)
        rethrow()
    end
    return :written
end

"A JSON file, indented by four spaces."
function write_json(path, value)
    open(path, "w") do io
        JSON3.pretty(io, value, JSON3.AlignmentContext(indent = 4))
        println(io)
    end
end

"""
Writes the run `name` of `project`: a staging folder with the flat files, packed into
`runs/<name>.7z` with 7-Zip, the staging removed (the program's own folder).
"""
function write_run(project, id, name, log, models, conditions, solutes)
    runs = joinpath(project, "runs")
    mkpath(runs)
    stage = mktempdir()
    entries = Any[]
    seconds_total = 0.0
    for m in models
        files = String[]
        put(src, dest) = (cp(src, joinpath(stage, dest)); push!(files, dest))
        put(m.book, "$(m.stem).xlsx")
        # the figures of the fit: `res.tex` -> `<stem>.tex`,
        # `res_hist_x.tex` -> `<stem>_hist_x.tex`
        plots = joinpath(dirname(m.book), "plots")
        base = splitext(basename(m.book))[1]
        if isdir(plots)
            for f in sort(readdir(plots))
                startswith(f, base * "_") || f == base * ".tex" || continue
                put(joinpath(plots, f), m.stem * f[(length(base)+1):end])
            end
        end
        logtext =
            "datetime\t$(log.stamp)\n\n=== $(m.section_name) ===\n" *
            join(m.section.lines, "\n") * "\n"
        write(joinpath(stage, "$(m.stem).LOG"), logtext)
        push!(files, "$(m.stem).LOG")
        # the same run's section of `statistics-<ID>.LOG` (the sampler's statistics, one
        # block for each attempt), pulled in beside it when the fit has one
        stat = statistics_section(dirname(m.book), id, m.section_name)
        if stat !== nothing
            write(joinpath(stage, "statistics-$(m.stem).LOG"), stat)
            push!(files, "statistics-$(m.stem).LOG")
        end
        sort!(files)
        secs = parse(Float64, something(row_of(m.section, "wallSeconds"), "0"))
        seconds_total += secs
        push!(
            entries,
            Dict{String,Any}(
                "name" => m.stem,
                "path" => joinpath(project, "models", basename(m.structure)),
                "size" => filesize(m.structure),
                "sha256" => first(split(read(`sha256sum $(m.structure)`, String))),
                "status" => "done", "seconds" => secs, "error" => nothing,
                "plotSizes" => Any[], "overrides" => Any[], "files" => files,
            ),
        )
    end
    started = utc_of(log.stamp)
    write_json(
        joinpath(stage, "run.json"),
        Dict{String,Any}(
            "schema" => 1, "status" => "done", "pid" => 0, "host" => gethostname(),
            "ui" => "tui", "project" => project, "started" => started,
            "heartbeat" => started, "ended" => started,
            "julia" => something(row_of(first(models).section, "julia"), ""),
            "baysol" => something(row_of(first(models).section, "baysol"), ""),
            "rngSeed" =>
                parse(Int, something(row_of(first(models).section, "rngSeed"), "0")),
            "models" => entries,
            "timings" => Dict(
                "seconds" => seconds_total,
                "models" => Dict(e["name"] => e["seconds"] for e in entries),
            ),
        ),
    )
    write_json(
        joinpath(stage, "models.json"),
        [
            Dict(
                "name" => e["name"], "path" => e["path"], "size" => e["size"],
                "sha256" => e["sha256"],
            ) for e in entries
        ],
    )
    write(
        joinpath(stage, "run.LOG"),
        "datetime\t$(log.stamp)\nproject\t$project\nrun\t$name\nui\ttui\n" *
        "started\t$started\n" *
        "temperatureC\t$(conditions.temp)\nph\t$(conditions.ph)\n" *
        "sigmaPh\t$(conditions.sigma)\nenergyEv\t$(conditions.energy)\n" *
        "models\t$(length(models))\nsource\timported by `bysl fits export` from the " *
        "fitting test $id\n\n--- output ---\nimported from the fitting test $id " *
        "(no live output; the terminal plots were never written)\n",
    )
    write(joinpath(stage, "solutes.json"), JSON3.write(Dict("solutes" => solutes)))
    archive = joinpath(runs, name * ".7z")
    Base.run(Cmd(`7z a -t7z -mx=5 -bso0 -bsp0 $archive $(readdir(stage))`; dir = stage))
    rm(stage; recursive = true)
    return archive
end

# --- the command ------------------------------------------------------------------

"The projects folder of the terminal interface (`BAYSOL_HOME` or the XDG data folder)."
function default_projects()
    home = get(ENV, "BAYSOL_HOME", "")
    base = if isabspath(home)
        home
    else
        joinpath(
            get(ENV, "XDG_DATA_HOME", joinpath(homedir(), ".local", "share")),
            "baysol",
        )
    end
    return joinpath(base, "projects")
end

"`bysl fits export`: fitting tests as projects with one run each."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    args = split_args(WHO, ["--out"], ["--all", "--dry-run"], argv)
    all = "--all" in args.flags
    dry = "--dry-run" in args.flags
    ids = args.specs
    if all
        isempty(ids) || fail(WHO, "--all takes no ID")
        ids = sort([
            d for d in readdir(joinpath(root(), FIT_DIR)) if
            isfile(joinpath(root(), FIT_DIR, d, d * ".jl"))
        ])
    end
    isempty(ids) && fail(WHO, "name the fitting tests, or give --all")
    outs = [last(p) for p in args.opts if first(p) == "--out"]
    projects = isempty(outs) ? default_projects() : abspath(last(outs))
    println(WHO, ": ", dry ? "dry run, " : "", "writing into ", projects)
    counts = Dict(:written => 0, :exists => 0, :dry => 0, :skipped => 0)
    for id in ids
        try
            r = export_entry(id, projects, dry)
            counts[r] += 1
            println("  ", rpad(id, 9), r == :exists ? "exists, left alone" : String(r))
        catch e
            e isa InterruptException && rethrow()
            counts[:skipped] += 1
            println("  ", rpad(id, 9), "skipped: ", sprint(showerror, e))
        end
    end
    println(
        "written $(counts[:written]), would write $(counts[:dry]), " *
        "exist $(counts[:exists]), " *
        "skipped $(counts[:skipped])",
    )
    return counts[:skipped] > 0 ? 1 : 0
end

end
