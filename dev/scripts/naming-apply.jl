# SPDX-License-Identifier: LGPL-3.0-or-later

# One-off: applies the camelCase rename of notes/naming-rename.md (step 1).
#
# The names come from `notes/naming/mapping.tsv` (identifiers the code defines) and from
# the data-format names of `notes/naming/data-names.tsv` (JSON keys, LOG rows, workbook
# and run-sheet headers, settings keywords, TypeScript keys), plus a few hand decisions
# (below). Every whole word of every text file of the repository that is one of the old
# names is replaced, so code, strings, docstrings, comments, documentation and the
# TypeScript that calls Julia by name all follow the same table. A word is a maximal run
# of letters, digits, underscores (and primes), with a trailing `!` for a mutating name.
#
# Usage: julia --startup-file=no dev/scripts/naming-apply.jl [--dry]
#
# Writes `notes/naming/applied.tsv` (old, new, replacements) and prints a summary.

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const NAMING = joinpath(ROOT, "notes", "naming")

# Hand decisions: constants are UPPER_CASE, not camelCase, and one collision is resolved
# by a descriptive name (`c1` is a different quantity in the files that also have it).
const CONST_NAMES = [
    "_protein_ionization", "_wildcards_nuc", "pc_q", "scat_stubamp", "sdg_q", "smpl_E",
    "smpl_chunk", "smpl_lmax", "smpl_pH", "smpl_q",
]
const HAND = Dict("c_1" => "c1Factor")

# Kebab-case JSON keys of the data formats (the other kebab names are values: solute
# names, folder names, step names, terminal names).
const KEBAB_KEYS = [
    "set-at", "sigma-pH", "sigma-mM", "sigma-pmv", "rest-mM", "pmv-ends", "sigma-ends",
    "z-ends",
]

# Kinds of a data name that make it part of a data format.
const DATA_KINDS = Set([
    "json-key", "ts-key", "log-row", "run-sheet-row", "workbook", "settings-keyword",
])

# Words of an identifier: letters, digits, underscore, combining marks, primes.
const WORD =
    r"(?<![\p{L}\p{N}\p{M}_′″])[\p{L}\p{N}\p{M}_′″]++!?+(?!\.(json|sqlite3|tex|tsv)\b)"

"Camel case of a data name that mixes letters and digits, as the table proposes."
function camel(name::AbstractString)
    parts = split(name, '_')
    lead = ""
    while !isempty(parts) && isempty(parts[1])
        lead *= "_"
        popfirst!(parts)
    end
    isempty(parts) && return name
    return lead * parts[1] * join(uppercasefirst.(parts[2:end]))
end

"The table of old => new words."
function load_table()
    table = Dict{String,String}()
    for line in Iterators.drop(eachline(joinpath(NAMING, "mapping.tsv")), 1)
        f = split(line, '\t')
        length(f) >= 2 && !isempty(f[1]) && (table[f[1]] = f[2])
    end
    for n in CONST_NAMES
        table[n] = uppercase(n)
    end
    for (o, n) in HAND
        table[o] = n
    end
    kebab = Dict{String,String}()
    for line in Iterators.drop(eachline(joinpath(NAMING, "data-names.tsv")), 1)
        f = split(line, '\t')
        name, proposed = f[1], f[2]
        kinds = Set(split(f[3], ','))
        isempty(kinds ∩ DATA_KINDS) && continue
        if name in KEBAB_KEYS
            kebab[name] = proposed
        elseif all(c -> isascii(c), name) && !occursin('-', name) && !haskey(table, name) &&
               (occursin('_', name) || (any(isuppercase, name) && any(islowercase, name)))
            table[name] = proposed
        end
    end
    return table, kebab
end

"The files of the rename: tracked text files, and the untracked notes and CLAUDE.md."
function target_files()
    listed = String[]
    for rel in eachline(Cmd(`git ls-files`; dir = ROOT))
        push!(listed, rel)
    end
    push!(listed, "CLAUDE.md")
    for rel in readdir(joinpath(ROOT, "notes"); join = false)
        endswith(rel, ".md") && push!(listed, joinpath("notes", rel))
    end
    keep = String[]
    for rel in unique(listed)
        path = joinpath(ROOT, rel)
        isfile(path) || continue
        ext = splitext(rel)[2]
        ext in (".jl", ".ts", ".tsx", ".md", ".json") || continue
        startswith(rel, "notes/naming/") && continue
        rel in ("notes/naming-rename.md", "package-lock.json", "tui/package.json") &&
            continue
        startswith(rel, "docs/build/") && continue
        startswith(rel, "dev/scripts/naming_") && continue
        startswith(rel, "test/fixtures/experiments/") && continue
        startswith(rel, "src/bulk-electron-density/") && ext == ".json" && continue
        startswith(rel, "tui/assets/data/colour-sets/") && continue
        endswith(rel, "biome.json") && continue
        push!(keep, rel)
    end
    return keep
end

function main(args)
    dry = "--dry" in args
    table, kebab = load_table()
    counts = Dict{String,Int}()
    files = target_files()
    changed = 0
    for rel in files
        path = joinpath(ROOT, rel)
        text = try
            read(path, String)
        catch
            continue
        end
        isvalid(text) || continue
        out = replace(text, WORD => function (w)
            if haskey(table, w)
                counts[w] = get(counts, w, 0) + 1
                return table[w]
            elseif endswith(w, "!") && haskey(table, chop(w))
                counts[chop(w)] = get(counts, chop(w), 0) + 1
                return table[chop(w)] * "!"
            end
            return w
        end)
        for (o, n) in kebab
            rx = Regex("(?<![\\p{L}\\p{N}_])" * o * "(?![\\p{L}\\p{N}_])")
            k = count(rx, out)
            if k > 0
                counts[o] = get(counts, o, 0) + k
                out = replace(out, rx => n)
            end
        end
        if out != text
            changed += 1
            dry || write(path, out)
        end
    end
    open(joinpath(NAMING, "applied.tsv"), "w") do io
        println(io, "old\tnew\treplacements")
        for (o, c) in sort!(collect(counts); by = first)
            println(io, o, '\t', get(table, o, get(kebab, o, "?")), '\t', c)
        end
    end
    unused = [o for o in keys(table) if !haskey(counts, o)]
    println("files scanned: ", length(files), ", changed: ", changed)
    println("names: ", length(table) + length(kebab), ", used: ", length(counts),
        ", never seen: ", length(unused))
    println("replacements: ", sum(values(counts)))
    return 0
end

exit(main(ARGS))
