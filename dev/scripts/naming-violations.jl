# SPDX-License-Identifier: LGPL-3.0-or-later

# One-off: the second half of the camelCase rename (notes/naming-rename.md, step 1):
# names that already existed but break the rules (PascalCase or UPPER_CASE variables,
# lower-case constants). Unlike `naming-apply.jl` this works on the tokens of the Julia
# code only (strings and comments are not touched), file by file: a name is renamed in
# every file where it is an identifier token (not a field access `x.Name`), and only
# when the new name is free in that file.
#
# Usage: julia --startup-file=no dev/scripts/naming-violations.jl [--dry]

using Base.JuliaSyntax: JuliaSyntax, kind, tokenize, @K_str

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const BY_HAND = joinpath(ROOT, "notes", "naming", "by-hand.md")

# Constants that hold values: UPPER_CASE (a leading underscore stays).
const CONSTS = Dict(
    "_Protein" => "_PROTEIN", "_DNA_ionization" => "_DNA_IONIZATION",
    "_RNA_ionization" => "_RNA_IONIZATION", "_polymers" => "_POLYMERS",
    "_pts" => "_PTS", "_ux" => "_UX", "_uy" => "_UY", "_uz" => "_UZ",
    "_solutes" => "_SOLUTES", "_wildcards" => "_WILDCARDS",
)

# Names that are not variables: types, foreign names, a keyword.
const SKIP = Set([
    "Atom", "Vec3", "Legacy", "XLSX", "MODEL", "If", "If1", "AliasBack", "BoundedBeta",
])

# A different name where the plain camel case is a keyword.
const HAND = Dict("If" => "iF", "If1" => "iF1")

"The names of a by-hand.md section (`- `name``), ASCII only."
function section(title)
    names = String[]
    on = false
    for line in eachline(BY_HAND)
        if startswith(line, "## ")
            on = startswith(line, "## " * title)
        elseif on && startswith(line, "- `")
            n = match(r"^- `([^`]+)`", line).captures[1]
            all(isascii, n) && push!(names, n)
        end
    end
    return names
end

"camelCase of a PascalCase or UPPER_CASE variable name."
function camel(n::AbstractString)
    lead = n[1:(length(n)-length(lstrip(n, '_')))]
    parts = filter(!isempty, split(lstrip(n, '_'), '_'))
    first_ = parts[1]
    first_ =
        all(c -> isuppercase(c) || isdigit(c), first_) ? lowercase(first_) :
        lowercasefirst(first_)
    return lead * first_ * join(uppercasefirst.(parts[2:end]))
end

function julia_files()
    out = String[]
    for rel in eachline(Cmd(`git ls-files`; dir = ROOT))
        endswith(rel, ".jl") || continue
        startswith(rel, "dev/") && continue
        push!(out, rel)
    end
    return out
end

"The Identifier tokens of a source text, with their byte ranges and the previous token."
function identifiers(text::String)
    out = Tuple{String,UnitRange{Int},Bool}[]
    bytes = codeunits(text)
    prev = K"None"
    for t in tokenize(text)
        k = kind(t)
        k == K"Whitespace" && continue
        if k == K"Identifier"
            r = Int(first(t.range)):Int(last(t.range))
            push!(out, (String(bytes[r]), r, prev == K"."))
        end
        prev = k
    end
    return out
end

function main(args)
    dry = "--dry" in args
    consts_defined = Set{String}()
    files = julia_files()
    texts = Dict(f => read(joinpath(ROOT, f), String) for f in files)
    for t in values(texts), m in eachmatch(r"^const (\w+)"m, t)
        push!(consts_defined, m.captures[1])
    end
    targets = Dict{String,String}(CONSTS)
    for n in vcat(section("PascalCase"), section("UPPER_CASE"))
        (n in SKIP || n in consts_defined) && continue
        targets[n] = get(HAND, n, camel(n))
    end
    if "--map" in args
        for (o, n) in sort!(collect(targets))
            println(o, '\t', n)
        end
        return 0
    end
    report = String[]
    renamed = 0
    perName = Dict{String,Int}()
    for f in files
        ids = identifiers(texts[f])
        present = Set(first.(ids))
        edits = Tuple{UnitRange{Int},String}[]
        for (name, r, afterdot) in ids
            haskey(targets, name) || continue
            afterdot && continue
            new = targets[name]
            if new in present
                push!(report, "$f: $name -> $new is taken in the file")
                continue
            end
            push!(edits, (r, new))
            perName[name] = get(perName, name, 0) + 1
        end
        isempty(edits) && continue
        renamed += length(edits)
        bytes = Vector{UInt8}(codeunits(texts[f]))
        for (r, new) in sort(edits; by = e -> -first(e[1]))
            splice!(bytes, r, Vector{UInt8}(codeunits(new)))
        end
        dry || write(joinpath(ROOT, f), bytes)
    end
    println("targets: $(length(targets)), identifier tokens renamed: $renamed")
    if dry
        for (n, c) in sort!(collect(perName); by = x -> -x[2])
            println("  $n -> $(targets[n]): $c")
        end
    end
    foreach(println, unique(report))
    return 0
end

exit(main(ARGS))
