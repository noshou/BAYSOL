# SPDX-License-Identifier: LGPL-3.0-or-later

# The report writers of `naming_map.jl` (included by it): the data-format names, the
# list of places a token rename misses, and the summary.

# ---------------------------------------------------------------------------
# 6. The data-format names
# ---------------------------------------------------------------------------

"More qualifying keys than this in a file: its keys are data."
const DATA_KEYED_KEYS = 150

"The JSON files whose keys are data (filled by [`json_keys`](@ref))."
const DATA_KEYED = String[]

"The JSON keys that need a rename (an interior `_` or `-`) per file."
function json_keys()::Dict{String,Dict{String,Int}}
    out = Dict{String,Dict{String,Int}}()
    # the solute tables are keyed by the names of solutes (data), whatever their size
    append!(
        DATA_KEYED,
        files_under("src", p -> endswith(p, ".json") &&
                                occursin("BulkElectronDensity", p)),
    )
    files = vcat(
        files_under("tui/assets/data", p -> endswith(p, ".json")),
        files_under("test/fixtures", p -> endswith(p, ".json")),
        files_under(
            "test/baselines",
            p -> endswith(p, ".json") &&
                 filesize(joinpath(ROOT, p)) < 2_000_000,
        ),
        files_under("src",
            p -> endswith(p, ".json") && !occursin("BulkElectronDensity", p)),
    )
    for f in files
        text = read(joinpath(ROOT, f), String)
        isvalid(text) || continue
        d = Dict{String,Int}()
        for m in eachmatch(r"\"([A-Za-z][A-Za-z0-9]*(?:[_-][A-Za-z0-9]+)+)\"\s*:", text)
            d[String(m.captures[1])] = get(d, String(m.captures[1]), 0) + 1
        end
        isempty(d) && continue
        # a file with that many keys is a table keyed by data (names of solutes), not by
        # the names of a format
        length(d) > DATA_KEYED_KEYS ? push!(DATA_KEYED, f) : (out[f] = d)
    end
    return out
end

"A TypeScript key: a quoted kebab or snake name, or a snake property, then a colon."
const TS_KEY = Regex(
    "(?:\"([a-z][A-Za-z0-9]*(?:[_-][A-Za-z0-9]+)+)\"|" *
    "\\b([a-z][a-z0-9]*(?:_[a-z0-9]+)+)\\??)\\s*:",
)

function write_data_names(out, st::Scan, tokens, new_of)
    universe = Dict{String,Dict{String,Any}}()
    add(name, kind, where_) = begin
        isuppercase(first(name)) && return    # settings names, residue and env keys
        e = get!(
            universe,
            name,
            Dict{String,Any}("kinds" => Set{String}(),
                "where" => String[]),
        )
        push!(e["kinds"], kind)
        length(e["where"]) < 4 && push!(e["where"], where_)
    end
    jk = json_keys()
    json_noise = Dict(f => length(d) for (f, d) in jk)
    for (f, d) in jk, k in keys(d)
        add(k, "json-key", f)
    end
    for s in st.idstrs
        base = basename(s.file)
        kind_ =
            base == "Log.jl" ? "log-row" :
            base == "Summary.jl" ? "run-sheet-row" :
            base in ("Tables.jl", "Results.jl") ? "workbook" :
            base == "Settings.jl" ? "settings" : "julia-string"
        add(s.text, kind_, "$(s.file):$(s.line)")
    end
    for s in st.syms
        s.callee == "_kw" && occursin('_', s.name) &&
            add(s.name, "settings-keyword", "$(s.file):$(s.line)")
    end
    # keys the TypeScript declares or writes: `"set-at":`, `energy_unit?:`
    for (f, _) in tokens
        (endswith(f, ".ts") || endswith(f, ".tsx")) && startswith(f, "tui/src/") ||
            continue
        for (i, l) in enumerate(eachline(joinpath(ROOT, f)))
            for m in eachmatch(TS_KEY, l)
                name = String(something(m.captures[1], m.captures[2]))
                add(name, "ts-key", "$f:$i")
            end
        end
    end
    read_count(name, prefixes) = sum(
        (get(d, name, 0) for (f, d) in tokens if any(p -> startswith(f, p), prefixes));
        init = 0)
    quoted_ts(name) = begin
        n = 0
        for (f, _) in tokens
            (endswith(f, ".ts") || endswith(f, ".tsx")) || continue
            startswith(f, "tui/") || continue
            n += count(name, read(joinpath(ROOT, f), String))
        end
        n
    end
    open(joinpath(out, "data-names.tsv"), "w") do io
        println(
            io,
            join(
                ["name", "proposed", "kinds", "files_with_the_key",
                    "written_at", "julia_tokens", "ts_uses", "dev_tokens", "note"], '\t'),
        )
        for name in sort!(collect(keys(universe)))
            e = universe[name]
            kebab = occursin('-', name)
            julia = read_count(name, ["src/", "tui/src/store/", "test/", "tui/test/"])
            ts = kebab ? quoted_ts(name) : read_count(name, ["tui/src/", "tui/test/"])
            dev = read_count(name, ["dev/"])
            jfiles = [f for (f, d) in jk if haskey(d, name)]
            note = String[]
            any(f -> json_noise[f] > 150, jfiles) && push!(note,
                "maybe a data key (file has many)")
            kebab && push!(note, "kebab-case")
            println(
                io,
                join(
                    [name, camel(name), join(sort!(collect(e["kinds"])), ","),
                        join(jfiles, ";"), join(e["where"], ";"), julia, ts, dev,
                        join(note, "; ")], '\t'),
            )
        end
    end
end

# ---------------------------------------------------------------------------
# 7. By hand and summary
# ---------------------------------------------------------------------------

function write_by_hand(out, st::Scan, tokens, byname, mapped, blocked, new_of,
    string_hits, files)
    mapped_set = Set(mapped)
    io = IOBuffer()
    println(io, "# Places a token rename misses, and decisions it needs\n")
    println(io, "Written by `dev/scripts/naming_map.jl`; nothing here is applied.\n")

    # symbol literals
    syms = [s for s in st.syms if s.name in mapped_set]
    println(io, "## Symbol literals (`:a_b`): $(length(syms)) sites\n")
    println(io, "They are renamed with the names, but they are data: a `Symbol` built at")
    println(io, "run time or compared with a string would not follow. The calls they sit")
    println(io, "in (full list: `symbol-sites.tsv`):\n")
    bycall = Dict{String,Int}()
    for s in syms
        bycall[s.callee] = get(bycall, s.callee, 0) + 1
    end
    for (c, n) in sort!(collect(bycall); by = x -> -x[2])
        println(io, "- `$(isempty(c) ? "(no call)" : c)`: $n")
    end

    # run-time derived names
    println(io, "\n## Names built or read at run time\n")
    pats = ["Symbol(", "lowercase(", "getfield(", "hasproperty(", "propertynames(",
        "fieldnames(", "kwargs[", "override_", "NamedTuple(", "Meta.parse", "@eval"]
    for p in pats
        hits = String[]
        for f in files
            startswith(f, "dev/") && continue
            for (i, l) in enumerate(eachline(joinpath(ROOT, f)))
                occursin(p, l) && push!(hits, "$f:$i")
            end
        end
        println(io, "- `$p`: $(length(hits)) lines",
            isempty(hits) ? "" :
            " (" * join(first(hits, 8), ", ") *
            (length(hits) > 8 ? ", ..." : "") * ")")
    end
    println(io, "\nThe settings keywords are NOT derived: `SETTING_KEYWORDS` in")
    println(io, "`src/Pipeline/Settings.jl` lists every keyword as a symbol (`_kw(...)`),")
    println(io, "so the table is renamed with the other symbols; `override_<setting>`")
    println(io, "LOG rows are built from the setting name (see `data-names.tsv`).\n")

    # strings
    docs = count(h -> h[3] == "doc", string_hits)
    println(io, "## Strings that hold a mapped name: $(length(string_hits)) sites\n")
    println(io, "$docs are docstrings (code names in prose, backticked: renamed with the")
    println(io, "token pass), the others are messages, keys or log texts. Error texts a")
    println(io, "test matches must change together; the sites by call",
        " (`string-sites.tsv`):\n")
    bycall = Dict{String,Int}()
    for h in string_hits
        h[3] == "doc" && continue
        bycall[h[4]] = get(bycall, h[4], 0) + 1
    end
    for (c, n) in sort!(collect(bycall); by = x -> -x[2])[1:min(15, length(bycall))]
        println(io, "- `$(isempty(c) ? "(no call)" : c)`: $n")
    end
    testhits = count(h -> startswith(h[1], "test/") || startswith(h[1], "tui/test/"),
        string_hits)
    println(io, "\nIn test files: $testhits string sites hold a mapped name.\n")

    # the language boundary
    println(io, "## Mapped names that cross into other code\n")
    for (area, prefixes) in (("TypeScript (the TUI calls Julia by name)",
        ["tui/src/", "tui/test/"]), ("Dev tools (exempt from the rule, but they call",
        ["dev/"]))
        found = Dict{String,Vector{String}}()
        for (f, d) in tokens
            any(p -> startswith(f, p), prefixes) || continue
            (endswith(f, ".ts") || endswith(f, ".tsx") || startswith(f, "dev/")) ||
                continue
            for n in mapped
                haskey(d, n) && push!(get!(found, n, String[]), f)
            end
        end
        println(io, "### $area", startswith(area, "Dev") ? " into `src/`)" : "", "\n")
        println(io, "$(length(found)) names; the files:\n")
        files_ = sort!(unique(reduce(vcat, values(found); init = String[])))
        for f in first(files_, 40)
            println(
                io,
                "- `$f`: ",
                join(first(sort!([n for (n, fs) in found
                                        if f in fs]), 12), ", "),
            )
        end
        println(io)
    end
    println(io, "`bysl results table` reads `ref_chi2 = \"...\"` out of every fitting")
    println(io, "script and `Report.parse_log` reads the LOG rows by name: both need the")
    println(io, "new names (dev tools, `dev/src/`). The `default-settings` check and the")
    println(io, "harvest tools read `Params.jl` constants (UPPER, untouched) and the")
    println(io, "keyword table.\n")

    # unicode and odd names
    println(io, "## Unicode names with an underscore (left alone, decide)\n")
    uni = sort!(
        unique([
            n for n in keys(byname) if !isascii(n) &&
                occursin(r"\w_\w", lstrip(n, '_'))
        ]),
    )
    println(io, "$(length(uni)) names mix words and Greek symbols, for example ",
        join(first(uni, 12), ", "), ". Options: `boundsδρ₁₂` (join as a camel word)")
    println(io, "or leave them (the rule allows 'unicode symbols').\n")
    for n in uni
        println(io, "- `$n`: ", join(unique(String.([d.kind for d in byname[n]])), ","),
            ", $(length(byname[n])) defs")
    end
    odd_const = sort!(
        unique([d.name for d in st.defs if d.kind == :const &&
                any(islowercase, d.name)]),
    )
    println(io, "\n## Constants that are not UPPER_CASE ($(length(odd_const)))\n")
    for n in odd_const
        println(io, "- `$n` ($(first(byname[n]).file):$(first(byname[n]).line))")
    end
    pascal = sort!(
        unique([
            d.name for d in st.defs if d.kind in (:function, :kwarg,
                    :arg, :local, :variable, :field, :loopvar) && !isempty(d.name) &&
                isuppercase(first(lstrip(d.name, '_'))) && any(islowercase, d.name) &&
                !(d.name in st.types)
        ]),
    )
    println(io, "\n## PascalCase names that are not types ($(length(pascal)))\n")
    for n in first(pascal, 60)
        println(io, "- `$n`")
    end
    upper = sort!(
        unique([
            d.name for d in st.defs if
            d.kind in (:local, :arg, :loopvar, :variable, :kwarg, :field) &&
                !any(islowercase, d.name) && length(d.name) > 1 &&
                any(isuppercase, d.name)
        ]),
    )
    println(io, "\n## UPPER_CASE names that are not constants ($(length(upper)))\n")
    for n in first(upper, 60)
        println(io, "- `$n`")
    end
    ut = sort!([t for t in st.types if occursin('_', t)])
    println(io, "\n## Type names with an underscore ($(length(ut)))\n")
    foreach(t -> println(io, "- `$t`"), ut)
    println(io, "\n## JSON files keyed by data (their keys are not renamed)\n")
    foreach(f -> println(io, "- `$f`"), sort!(unique(DATA_KEYED)))
    println(io, "\n## Blocked names ($(length(blocked)))\n")
    println(io, "Not mapped because a foreign API uses them: see `foreign-blocklist.txt`.")
    write(joinpath(out, "by-hand.md"), String(take!(io)))
end

function write_summary(out, st::Scan, byname, mapped, blocked, collisions, flag, tokens)
    io = IOBuffer()
    kinds = Dict{Symbol,Int}()
    pairs = Dict{Symbol,Int}()
    for n in mapped
        ks = unique([d.kind for d in byname[n]])
        kinds[primary_kind(ks)] = get(kinds, primary_kind(ks), 0) + 1
        for k in ks
            pairs[k] = get(pairs, k, 0) + 1
        end
    end
    pub = Dict("fn" => 0, "kw" => 0, "field" => 0, "PlotStyle-field" => 0)
    for n in mapped
        for f in split(flag(n), ',')
            haskey(pub, f) && (pub[f] += 1)
        end
    end
    println(io, "convertible names defined in the code: ", length(mapped) + length(blocked))
    println(io, "mapped: ", length(mapped), "   blocked (foreign): ", length(blocked))
    println(io, "collision lines: ", length(collisions))
    println(io, "\nby primary kind (a name counted once):")
    for k in PRECEDENCE
        haskey(kinds, k) && println(io, "  ", rpad(k, 10), kinds[k])
    end
    println(io, "\nby kind, every kind a name has:")
    for k in PRECEDENCE
        haskey(pairs, k) && println(io, "  ", rpad(k, 10), pairs[k])
    end
    println(
        io,
        "\npublic subset (names): ",
        join(["$k=$v" for (k, v) in sort!(
            collect(pub))], ", "),
    )
    println(io, "  fn = exported or public function, kw = keyword of one, field = field")
    println(io, "  of an exported type, PlotStyle-field = a field of PlotStyle")
    write(joinpath(out, "summary.txt"), String(take!(io)))
end
