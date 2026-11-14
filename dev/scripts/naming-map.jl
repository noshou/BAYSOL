# SPDX-License-Identifier: LGPL-3.0-or-later

# naming-map.jl: the analysis half of the camelCase rename (notes/naming-rename.md).
#
# Reads the Julia code of `src/`, `tui/src/store/*.jl` and the tests (`test/`,
# `tui/test/*.jl`) with Julia's own parser, collects every name DEFINED there (functions,
# macros, struct fields, own keyword arguments, arguments, locals and variables), and
# writes what a rename would do to `notes/naming/`. It changes nothing else: no source
# file is edited, no fit and no test is run.
#
#   julia --startup-file=no dev/scripts/naming-map.jl [--out notes/naming]
#
# Outputs: mapping.tsv, collisions.txt, foreign-blocklist.txt, foreign-sites.tsv,
# symbol-sites.tsv, string-sites.tsv, data-names.tsv, by-hand.md and summary.txt.
#
# The rule: `_foo_bar!` -> `_fooBar!`, acronyms as words (`load_buffer_ph` ->
# `loadBufferPh`), digits kept (`ref_chi2` -> `refChi2`). UPPER_CASE constants, names with a
# Unicode letter and names without an interior underscore are left alone. A name that
# also belongs to a foreign API (Optim's `g_tol`, a keyword of a Base or package call,
# a method extended from another package) is not mapped: it is on the blocklist.

using Base.JuliaSyntax:
    JuliaSyntax, SyntaxNode, @K_str, children, kind, parseall,
    source_location, sourcetext
using Dates: Dates
using LinearAlgebra: LinearAlgebra
using Random: Random
using Statistics: Statistics
using Test: Test

const ROOT = dirname(dirname(@__DIR__))

# ---------------------------------------------------------------------------
# 1. Files
# ---------------------------------------------------------------------------

"The directories no scan enters."
const SKIP_DIRS = ["node_modules", ".git", "_cache", "sources", "manuscript", "build",
    "dist", "naming", "results"]

"The text file types the counts and the data scans read."
const TEXT_EXT = [".jl", ".md", ".ts", ".tsx", ".js", ".json", ".toml", ".tex", ".tsv",
    ".txt", ".yml", ".yaml", ".scss", ".css", ".sh"]

"The files under `dir` for which `keep` holds, as paths relative to the repository."
function files_under(dir::String, keep::Function)::Vector{String}
    out = String[]
    isdir(joinpath(ROOT, dir)) || return out
    for (root, dirs, fs) in walkdir(joinpath(ROOT, dir))
        filter!(d -> !(d in SKIP_DIRS), dirs)
        for f in fs
            p = relpath(joinpath(root, f), ROOT)
            keep(p) && push!(out, p)
        end
    end
    return sort!(out)
end

"The Julia files whose names the rename covers."
function julia_files()::Vector{String}
    isjl = p -> endswith(p, ".jl")
    store = filter(
        p -> endswith(p, ".jl"),
        readdir(joinpath(ROOT, "tui/src/store");
            join = false),
    )
    return vcat(
        files_under("src", isjl),
        ["tui/src/store/" * f for f in store],
        files_under("test", isjl),
        filter(p -> dirname(p) == "tui/test", files_under("tui/test", isjl)),
    )
end

"The area a file counts under: `src`, `test`, `tui`, `dev` or `docs` (the rest)."
function area_of(path::String)::String
    top = first(split(path, '/'))
    return top in ("src", "test", "tui", "dev") ? top : "docs"
end

# ---------------------------------------------------------------------------
# 2. Scanning the syntax trees
# ---------------------------------------------------------------------------

"A name defined in the code: where, of what kind and in what (function or type)."
struct Def
    name::String
    kind::Symbol          # :function :macro :field :kwarg :arg :loopvar :local ...
    file::String
    line::Int
    foreign::Bool         # a method of a foreign function (`Base.show`, `import X: f`)
    owner::String         # the function or type that holds it ("" at top level)
    ofn::Bool             # its owner is a foreign method
end

"A keyword at a call: the callee, and whether it is qualified (`A.f`)."
struct CallKw
    file::String
    line::Int
    col::Int
    callee::String
    root::String
    kw::String
end

"A `Root.name` access (a call or a field)."
struct Dot
    file::String
    line::Int
    root::String
    name::String
end

"A `:symbol` literal and the call it is an argument of."
struct Sym
    file::String
    line::Int
    name::String
    callee::String
end

"A string literal: its source text, its place and the call it is an argument of."
struct Str
    file::String
    line::Int
    text::String
    kind::Symbol          # :doc or :str
    callee::String
end

"What the scan collects."
mutable struct Scan
    defs::Vector{Def}
    kws::Vector{CallKw}
    dots::Vector{Dot}
    syms::Vector{Sym}
    strs::Vector{Str}
    idstrs::Vector{Str}   # strings that are one identifier-like word ("q_min", "set-at")
    exported::Set{String}
    modules::Set{String}
    types::Set{String}
    imports::Vector{Tuple{String,Bool,Vector{String}}}   # root, is `import`, names
    extension_imports::Set{String}
    foreign_imports::Set{String}
end

Scan() = Scan(Def[], CallKw[], Dot[], Sym[], Str[], Str[], Set{String}(),
    Set{String}(), Set{String}(), [], Set{String}(), Set{String}())

"Where the scan is: the function it is in, the call whose argument it is."
struct Ctx
    owner::String
    ofn::Bool
    infunc::Bool
    callee::String
    indoc::Bool
end

kids(n::SyntaxNode) = (c = children(n); c === nothing ? SyntaxNode[] : c)
isid(n::SyntaxNode) = kind(n) == K"Identifier"
idname(n::SyntaxNode) = String(n.val)
line_of(n::SyntaxNode) = source_location(n)[1]

"The identifiers a pattern binds: `x`, `x::T`, `x = 1`, `x...`, `(a, b)`, `(; a, b)`."
function pattern_ids(n::SyntaxNode)::Vector{SyntaxNode}
    k = kind(n)
    isid(n) && return [n]
    if k == K"::"
        return length(kids(n)) == 2 ? pattern_ids(kids(n)[1]) : SyntaxNode[]
    elseif k in (K"=", K"...")
        return isempty(kids(n)) ? SyntaxNode[] : pattern_ids(kids(n)[1])
    elseif k in (K"tuple", K"parens", K"parameters")
        return reduce(vcat, [pattern_ids(c) for c in kids(n)]; init = SyntaxNode[])
    end
    return SyntaxNode[]
end

"The module a dotted name starts from, and its last name: `A.B.f` -> (`A`, `f`)."
function dotted(n::SyntaxNode)::Tuple{String,String}
    k = kind(n)
    isid(n) && return ("", idname(n))
    if k == K"."
        cs = kids(n)
        length(cs) == 2 || return ("", "")
        root = cs[1]
        while kind(root) == K"." && !isempty(kids(root))
            root = kids(root)[1]
        end
        last = cs[2]
        name = isid(last) ? idname(last) : ""
        return (isid(root) ? idname(root) : "", name)
    elseif k == K"curly" && !isempty(kids(n))
        return dotted(kids(n)[1])
    end
    return ("", "")
end

function define!(st::Scan, file, id::SyntaxNode, kind_::Symbol, ctx::Ctx;
    foreign = false)
    name = idname(id)
    all(==('_'), name) && return
    push!(st.defs, Def(name, kind_, file, line_of(id), foreign, ctx.owner, ctx.ofn))
end

"The call node under the `where`s and return type of a signature, or `nothing`."
function sigcall(n::SyntaxNode)::Union{SyntaxNode,Nothing}
    while kind(n) in (K"where", K"::") && !isempty(kids(n))
        n = kids(n)[1]
    end
    return kind(n) == K"call" ? n : nothing
end

"Scans what a pattern holds besides its names: defaults and type annotations."
function scan_extras!(st::Scan, p::SyntaxNode, file, ctx::Ctx)
    k = kind(p)
    cs = kids(p)
    if k == K"="
        length(cs) == 2 || return
        scan_extras!(st, cs[1], file, ctx)
        scan!(st, cs[2], file, ctx)
    elseif k == K"::"
        length(cs) == 2 && scan_extras!(st, cs[1], file, ctx)
        isempty(cs) || scan!(st, cs[end], file, ctx)
    elseif k in (K"...", K"tuple", K"parens", K"parameters")
        foreach(c -> scan_extras!(st, c, file, ctx), cs)
    end
end

"Defines the names of a pattern (all of one kind) and scans the rest of it."
function define_pattern!(st::Scan, file, p::SyntaxNode, kind_::Symbol, ctx::Ctx)
    for id in pattern_ids(p)
        define!(st, file, id, kind_, ctx)
    end
    scan_extras!(st, p, file, ctx)
end

"The name a method signature defines and whether it extends a foreign function."
function method_name(st::Scan, callee::SyntaxNode)::Tuple{String,Bool}
    if isid(callee)
        return (idname(callee), idname(callee) in st.extension_imports)
    elseif kind(callee) == K"."
        _, name = dotted(callee)
        return (name, true)
    elseif kind(callee) == K"curly" && !isempty(kids(callee))
        return method_name(st, kids(callee)[1])
    end
    return ("", false)
end

"A method definition: the signature `sig` and the body nodes."
function define_function!(st::Scan, sig::SyntaxNode, body, file, ctx::Ctx)
    call = sigcall(sig)
    if call === nothing
        # `function f end`, an anonymous `function (x, y)` or a tuple signature
        if isid(sig)
            define!(st, file, sig, :function, ctx;
                foreign = idname(sig) in st.extension_imports)
        elseif kind(sig) == K"tuple"
            for a in kids(sig)
                define_pattern!(st, file, a, :arg, Ctx("", false, true, "", false))
            end
        end
        foreach(b -> scan!(st, b, file, Ctx("", false, true, "", false)), body)
        return
    end
    cs = kids(call)
    name, foreign = method_name(st, cs[1])
    head = isid(cs[1]) || kind(cs[1]) in (K".", K"curly")
    head || scan!(st, cs[1], file, ctx)          # `(f::Foo)(x)`: scan the type
    inner = Ctx(name, foreign, true, "", false)
    if head
        id = cs[1]
        while kind(id) == K"curly" && !isempty(kids(id))
            id = kids(id)[1]
        end
        if isid(id)
            define!(st, file, id, :function, ctx; foreign)
        elseif kind(id) == K"." && length(kids(id)) == 2 && isid(kids(id)[2])
            define!(st, file, kids(id)[2], :function, ctx; foreign = true)
        end
    end
    for a in cs[2:end]
        if kind(a) == K"parameters"
            for p in kids(a)
                define_pattern!(st, file, p, :kwarg, inner)
            end
        else
            define_pattern!(st, file, a, :arg, inner)
        end
    end
    for b in body
        scan!(st, b, file, inner)
    end
end

"The type name of a `struct` header: `A`, `A{T}`, `A <: B`."
function type_name(n::SyntaxNode)::String
    while kind(n) in (K"curly", K"<:") && !isempty(kids(n))
        n = kids(n)[1]
    end
    return isid(n) ? idname(n) : ""
end

"One field line of a `struct` body."
function define_field!(st::Scan, f::SyntaxNode, file, ctx::Ctx)
    k = kind(f)
    cs = kids(f)
    if isid(f) || k == K"::"
        for id in pattern_ids(f)
            define!(st, file, id, :field, ctx)
        end
        scan_extras!(st, f, file, ctx)
    elseif k == K"const" && !isempty(cs)
        define_field!(st, cs[1], file, ctx)
    elseif k == K"=" && length(cs) == 2 && sigcall(cs[1]) === nothing
        define_pattern!(st, file, cs[1], :field, ctx)
        scan!(st, cs[2], file, ctx)
    else
        scan!(st, f, file, ctx)
    end
end

"Records the keywords of a call and scans its arguments."
function scan_call!(st::Scan, n::SyntaxNode, file, ctx::Ctx)
    cs = kids(n)
    isempty(cs) && return
    root, name = dotted(cs[1])
    if kind(cs[1]) == K"."
        push!(st.dots, Dot(file, line_of(cs[1]), root, name))
    elseif !(isid(cs[1]) || kind(cs[1]) == K"curly")
        scan!(st, cs[1], file, ctx)
    end
    inner = Ctx(ctx.owner, ctx.ofn, ctx.infunc, name, false)
    record = function (p)
        if kind(p) == K"=" && length(kids(p)) == 2 && isid(kids(p)[1])
            id = kids(p)[1]
            loc = source_location(id)
            push!(st.kws, CallKw(file, loc[1], loc[2], name, root, idname(id)))
            scan!(st, kids(p)[2], file, inner)
        elseif isid(p)
            loc = source_location(p)
            push!(st.kws, CallKw(file, loc[1], loc[2], name, root, idname(p)))
        else
            scan!(st, p, file, inner)
        end
    end
    for a in cs[2:end]
        if kind(a) == K"parameters"
            foreach(record, kids(a))
        elseif kind(a) == K"="
            record(a)
        else
            scan!(st, a, file, inner)
        end
    end
end

"Collects the names of an import or using statement."
function scan_import!(st::Scan, n::SyntaxNode)
    isimport = kind(n) == K"import"
    for c in kids(n)
        paths = kind(c) == K":" ? kids(c) : [c]
        isempty(paths) && continue
        head = kind(paths[1]) == K"importpath" ? kids(paths[1]) : SyntaxNode[]
        relative = !isempty(head) && kind(head[1]) == K"."
        root = ""
        for h in head
            isid(h) && (root = idname(h); break)
        end
        names = String[]
        if kind(c) == K":"
            for p in paths[2:end]
                q = kind(p) == K"as" ? kids(p)[1] : p
                ids = filter(isid, kids(q))
                isempty(ids) || push!(names, idname(last(ids)))
            end
        end
        relative || push!(st.imports, (root, isimport, names))
    end
end

"The default scan: dispatches on the kind of a node."
function scan!(st::Scan, n::SyntaxNode, file, ctx::Ctx)
    k = kind(n)
    cs = kids(n)
    if k == K"function" && !isempty(cs)
        define_function!(st, cs[1], cs[2:end], file, ctx)
    elseif k == K"macro" && !isempty(cs)
        call = sigcall(cs[1])
        inner = Ctx("", false, true, "", false)
        if call !== nothing && isid(kids(call)[1])
            define!(st, file, kids(call)[1], :macro, ctx)
            for a in kids(call)[2:end]
                define_pattern!(st, file, a, :arg, inner)
            end
        end
        foreach(b -> scan!(st, b, file, inner), cs[2:end])
    elseif k == K"=" && length(cs) == 2 && sigcall(cs[1]) !== nothing
        define_function!(st, cs[1], [cs[2]], file, ctx)
    elseif k == K"=" && length(cs) == 2 && !isempty(pattern_ids(cs[1]))
        define_pattern!(st, file, cs[1], ctx.infunc ? :local : :variable, ctx)
        scan!(st, cs[2], file, ctx)
    elseif k == K"const" && !isempty(cs)
        c = cs[1]
        if kind(c) == K"=" && length(kids(c)) == 2
            for id in pattern_ids(kids(c)[1])
                define!(st, file, id, :const, ctx)
            end
            scan_extras!(st, kids(c)[1], file, ctx)
            scan!(st, kids(c)[2], file, ctx)
        else
            foreach(x -> scan!(st, x, file, ctx), cs)
        end
    elseif k in (K"local", K"global")
        for c in cs
            if isid(c)
                define!(st, file, c, ctx.infunc ? :local : :variable, ctx)
            else
                scan!(st, c, file, ctx)
            end
        end
    elseif k == K"struct" && length(cs) >= 2
        tname = type_name(cs[1])
        tname == "" || push!(st.types, tname)
        scan_header_params!(st, cs[1], file, ctx)
        body = Ctx(tname, false, false, "", false)
        for f in kids(cs[2])
            define_field!(st, f, file, body)
        end
    elseif k in (K"abstract", K"primitive") && !isempty(cs)
        t = type_name(cs[1])
        t == "" || push!(st.types, t)
    elseif k == K"module" && length(cs) >= 2
        isid(cs[1]) && push!(st.modules, idname(cs[1]))
        foreach(c -> scan!(st, c, file, ctx), cs[2:end])
    elseif k == K"->" && length(cs) == 2
        inner = Ctx(ctx.owner, ctx.ofn, true, "", false)
        define_pattern!(st, file, cs[1], :arg, inner)
        scan!(st, cs[2], file, inner)
    elseif k == K"do" && length(cs) == 3
        scan!(st, cs[1], file, ctx)
        inner = Ctx(ctx.owner, ctx.ofn, true, "", false)
        define_pattern!(st, file, cs[2], :arg, inner)
        scan!(st, cs[3], file, inner)
    elseif k == K"iteration"
        for spec in cs
            if kind(spec) in (K"in", K"=") && length(kids(spec)) == 2
                define_pattern!(st, file, kids(spec)[1], :loopvar, ctx)
                scan!(st, kids(spec)[2], file, ctx)
            else
                scan!(st, spec, file, ctx)
            end
        end
    elseif k == K"catch" && !isempty(cs)
        isid(cs[1]) ? define!(st, file, cs[1], :local, ctx) : scan!(st, cs[1], file, ctx)
        foreach(c -> scan!(st, c, file, ctx), cs[2:end])
    elseif k == K"call"
        scan_call!(st, n, file, ctx)
    elseif k == K"macrocall" && !isempty(cs)
        name = isid(cs[1]) ? idname(cs[1]) : last(dotted(cs[1]))
        if kind(cs[1]) == K"."
            root, nm = dotted(cs[1])
            push!(st.dots, Dot(file, line_of(n), root, nm))
        end
        inner = Ctx(ctx.owner, ctx.ofn, ctx.infunc, name, false)
        foreach(c -> scan!(st, c, file, inner), cs[2:end])
    elseif k == K"doc" && length(cs) == 2
        push_string!(st, cs[1], file, Ctx(ctx.owner, ctx.ofn, ctx.infunc, "", true))
        scan!(st, cs[2], file, ctx)
    elseif k == K"string"
        push_string!(st, n, file, ctx)
        foreach(c -> scan!(st, c, file, ctx), cs)
    elseif k == K"quote" && length(cs) == 1 && isid(cs[1])
        push!(st.syms, Sym(file, line_of(n), idname(cs[1]), ctx.callee))
    elseif k == K"ref"
        inner = Ctx(ctx.owner, ctx.ofn, ctx.infunc, "[]", false)
        foreach(c -> scan!(st, c, file, inner), cs)
    elseif k == K"."
        if length(cs) == 2 && isid(cs[2])
            root, name = dotted(n)
            push!(st.dots, Dot(file, line_of(n), root, name))
        end
        isempty(cs) || scan!(st, cs[1], file, ctx)
        length(cs) == 2 && !isid(cs[2]) && scan!(st, cs[2], file, ctx)
    elseif k in (K"export", K"public")
        for c in cs
            isid(c) && push!(st.exported, idname(c))
        end
    elseif k in (K"import", K"using")
        scan_import!(st, n)
    else
        foreach(c -> scan!(st, c, file, ctx), cs)
    end
end

"Scans the type parameters and supertypes of a `struct` header."
function scan_header_params!(st::Scan, n::SyntaxNode, file, ctx::Ctx)
    kind(n) in (K"curly", K"<:") && foreach(c -> scan!(st, c, file, ctx), kids(n)[2:end])
end

"Records a string literal."
function push_string!(st::Scan, n::SyntaxNode, file, ctx::Ctx)
    text = sourcetext(n)
    line = line_of(n)
    kind_ = ctx.indoc ? :doc : :str
    occursin('_', text) && push!(st.strs, Str(file, line, text, kind_, ctx.callee))
    m = match(r"^\"([A-Za-z][A-Za-z0-9]*(?:[_-][A-Za-z0-9]+)+)\"$", text)
    m === nothing || push!(st.idstrs, Str(file, line, String(m.captures[1]), :str,
        ctx.callee))
end

# ---------------------------------------------------------------------------
# 3. The rule
# ---------------------------------------------------------------------------

"Whether the rule renames `s`: an ASCII name with an interior underscore and a lower
case letter that does not start with a capital (a type or a constant)."
function convertible(s::AbstractString)::Bool
    core = rstrip(lstrip(s, '_'), '!')
    isempty(core) && return false
    isascii(core) || return false
    occursin(r"[A-Za-z0-9]_+[A-Za-z0-9]", core) || return false
    any(islowercase, core) || return false
    return !isuppercase(first(core))
end

"The camelCase of a snake_case (or kebab-case) name; leading `_` and trailing `!` stay."
function camel(s::AbstractString)::String
    lead = match(r"^_*", s).match
    rest = s[(length(lead)+1):end]
    bang = match(r"!*$", rest).match
    rest = rest[1:(end-length(bang))]
    trail = match(r"_*$", rest).match
    rest = rest[1:(end-length(trail))]
    segs = split(rest, r"[_-]+"; keepempty = false)
    isempty(segs) && return String(s)
    out = lowercasefirst(String(segs[1]))
    for seg in segs[2:end]
        out *= uppercasefirst(lowercase(String(seg)))
    end
    return lead * out * trail * bang
end

# ---------------------------------------------------------------------------
# 4. Counting uses in every text file
# ---------------------------------------------------------------------------

const TOKEN = r"[\p{L}_][\p{L}\p{N}_]*!?"

"Per area and file: how often each identifier-like token occurs."
function count_tokens()::Dict{String,Dict{String,Int}}
    roots = ["src", "test", "tui", "dev", "docs", "notes"]
    files = String[]
    for r in roots
        append!(
            files,
            files_under(
                r,
                p ->
                    any(e -> endswith(p, e), TEXT_EXT) &&
                    filesize(joinpath(ROOT, p)) < 2_000_000,
            ),
        )
    end
    for p in readdir(ROOT)
        isfile(joinpath(ROOT, p)) && endswith(p, ".md") && push!(files, p)
    end
    counts = Dict{String,Dict{String,Int}}()                # file => token => count
    for p in unique(files)
        text = try
            read(joinpath(ROOT, p), String)
        catch
            continue
        end
        isvalid(text) || continue
        d = Dict{String,Int}()
        for m in eachmatch(TOKEN, text)
            d[m.match] = get(d, m.match, 0) + 1
        end
        counts[p] = d
    end
    return counts
end

# ---------------------------------------------------------------------------
# 5. The analysis
# ---------------------------------------------------------------------------

"The base names a foreign module defines that a renamed name must not collide with."
function base_clash(new::String)::Bool
    sym = Symbol(new)
    return any(
        m -> isdefined(m, sym),
        (Base, Core, LinearAlgebra, Statistics, Random,
            Dates, Test),
    )
end

const PRECEDENCE = [:function, :macro, :field, :kwarg, :arg, :variable, :loopvar,
    :local, :const]

primary_kind(kinds) = first(filter(k -> k in kinds, PRECEDENCE))

function main(argv)
    out = joinpath(ROOT, "notes", "naming")
    i = findfirst(==("--out"), argv)
    i === nothing || (out = joinpath(ROOT, argv[i+1]))
    mkpath(out)
    files = julia_files()
    trees = Dict{String,SyntaxNode}()
    for f in files
        text = read(joinpath(ROOT, f), String)
        trees[f] = parseall(SyntaxNode, text; filename = f)
    end
    # the dev tools are exempt from the rule but they are our code: what they define is
    # ours, so a call into them is not a call into a foreign API
    sd = Scan()
    for f in files_under("dev", p -> endswith(p, ".jl"))
        scan!(sd, parseall(SyntaxNode, read(joinpath(ROOT, f), String); filename = f), f,
            Ctx("", false, false, "", false))
    end
    st = Scan()
    # first pass: the modules and the imports, so a method of a foreign function is known
    for f in files
        scan!(st, trees[f], f, Ctx("", false, false, "", false))
    end
    foreign_roots = Set{String}()
    own = union(st.modules, sd.modules, Set(["BAYSOL", "Main"]))
    for (root, isimport, names) in st.imports
        root in own && continue
        push!(foreign_roots, root)
        for n in names
            push!(st.foreign_imports, n)
            isimport && push!(st.extension_imports, n)
        end
    end
    # second pass with the extensions known
    imports_found = st.imports
    st = Scan()
    st.extension_imports = Set{String}(
        n for (r, im, ns) in imports_found if !(r in own) && im for n in ns
    )
    for f in files
        scan!(st, trees[f], f, Ctx("", false, false, "", false))
    end
    st.foreign_imports = Set{String}(
        n for (r, im, ns) in st.imports if !(r in own) for n in ns
    )
    own = union(st.modules, sd.modules, Set(["BAYSOL", "Main"]))

    byname = Dict{String,Vector{Def}}()
    for d in st.defs
        push!(get!(byname, d.name, Def[]), d)
    end
    ours = Set{String}(d.name for d in st.defs if !d.foreign)
    union!(ours, st.types, st.modules)
    union!(ours, (d.name for d in sd.defs if !d.foreign), sd.types, sd.modules)

    # ---- foreign use: keywords of foreign calls, foreign qualified names
    foreign_site(kw::CallKw) = begin
        kw.root == "" ? !(kw.callee in ours) : !(kw.root in ours) && !(kw.root in own)
    end
    foreign_kws = Dict{String,Vector{CallKw}}()
    for kw in st.kws
        foreign_site(kw) && push!(get!(foreign_kws, kw.kw, CallKw[]), kw)
    end
    foreign_qual = Dict{String,Vector{Dot}}()
    for d in st.dots
        d.root == "" && continue
        (d.root in ours || d.root in own) && continue
        push!(get!(foreign_qual, d.name, Dot[]), d)
    end

    # ---- candidates and the blocklist
    candidates = sort!([n for n in keys(byname) if convertible(n)])
    blocked = Dict{String,Vector{String}}()
    for n in candidates
        why = String[]
        haskey(foreign_kws, n) && push!(
            why,
            "keyword of the foreign call " *
            join(
                unique([
                    "$(k.root == "" ? "" : k.root * ".")$(k.callee)"
                    for k in foreign_kws[n]
                ]), ", "),
        )
        haskey(foreign_qual, n) && push!(
            why,
            "a foreign qualified name " *
            join(unique([d.root * "." * d.name for d in foreign_qual[n]]), ", "),
        )
        n in st.foreign_imports && push!(why, "imported from a foreign package")
        any(d -> d.foreign, byname[n]) && push!(why, "extends a foreign function")
        any(d -> d.kind == :kwarg && d.ofn, byname[n]) &&
            push!(why, "keyword of a method of a foreign function")
        isempty(why) || (blocked[n] = why)
    end
    mapped = filter(n -> !haskey(blocked, n), candidates)
    new_of = Dict(n => camel(n) for n in candidates)

    # ---- collisions
    all_defined = Set(keys(byname))
    collisions = String[]
    by_new = Dict{String,Vector{String}}()
    for n in mapped
        push!(get!(by_new, new_of[n], String[]), n)
    end
    for (new, olds) in sort!(collect(by_new); by = first)
        if length(olds) > 1
            push!(collisions, "SAME NEW NAME  $new <- " * join(olds, ", "))
        end
        if new in all_defined && !(new in mapped)
            kinds = unique([d.kind for d in byname[new]])
            files_ = unique([d.file for d in byname[new]])
            scope =
                any(k -> k in (:function, :macro, :field, :const, :variable), kinds) ?
                "global" : "scoped (check by hand)"
            push!(
                collisions,
                "EXISTING NAME  $new (already defined: " *
                join(kinds, ",") * "; " * join(first(files_, 3), ", ") * ") <- " *
                join(olds, ", ") * "  [$scope]",
            )
        end
        if base_clash(new)
            push!(collisions, "BASE/STDLIB NAME  $new <- " * join(olds, ", "))
        end
        if haskey(foreign_kws, new) || haskey(foreign_qual, new)
            push!(
                collisions,
                "FOREIGN NAME  $new is also used by a foreign API <- " *
                join(olds, ", "),
            )
        end
    end

    # ---- public flags
    public_fns = union(
        st.exported,
        Set(["seed_model", "run_model", "write_log",
            "print_summary", "results", "compare_results", "font_available",
            "seed_keywords",
            "run_keywords", "run_arguments", "results_keywords"]),
    )
    flag(n) = begin
        fl = String[]
        for d in byname[n]
            d.kind == :function && d.name in public_fns && push!(fl, "fn")
            d.kind == :kwarg && d.owner in public_fns && push!(fl, "kw")
            d.kind == :field && (d.owner in public_fns || d.owner == "PlotStyle") &&
                push!(fl, d.owner == "PlotStyle" ? "PlotStyle-field" : "field")
        end
        join(sort!(unique(fl)), ",")
    end

    # ---- counts
    tokens = count_tokens()
    area_count(n) = begin
        c = Dict("src" => 0, "test" => 0, "docs" => 0, "tui" => 0, "dev" => 0)
        for (f, d) in tokens
            haskey(d, n) && (c[area_of(f)] += d[n])
        end
        c
    end
    foreign_count(n) = length(get(foreign_kws, n, CallKw[]))

    open(joinpath(out, "mapping.tsv"), "w") do io
        println(
            io,
            join(
                ["old", "new", "kinds", "primary", "defined_in", "public",
                    "uses_src", "uses_test", "uses_docs", "uses_tui", "uses_dev",
                    "uses_total",
                    "foreign_kw_sites"], '\t'),
        )
        rows = Tuple[]
        for n in mapped
            ds = byname[n]
            kinds = sort!(unique(String.([d.kind for d in ds])))
            c = area_count(n)
            first_def = first(sort(ds; by = d -> (d.file, d.line)))
            push!(
                rows,
                (n, new_of[n], join(kinds, ","),
                    String(primary_kind(Symbol.(kinds))),
                    "$(first_def.file):$(first_def.line)", flag(n), c["src"], c["test"],
                    c["docs"], c["tui"], c["dev"], sum(values(c)), foreign_count(n)),
            )
        end
        for r in rows
            println(io, join(r, '\t'))
        end
    end
    write(
        joinpath(out, "collisions.txt"),
        isempty(collisions) ?
        "no collisions\n" : join(collisions, '\n') * '\n',
    )
    open(joinpath(out, "foreign-blocklist.txt"), "w") do io
        println(io, "# Names the code defines that a foreign API also uses: not renamed.")
        println(io, "# name -> proposed camelCase (do it by hand if wanted) : reasons")
        for n in sort!(collect(keys(blocked)))
            println(io, n, " -> ", new_of[n], " : ", join(blocked[n], "; "))
        end
    end
    open(joinpath(out, "foreign-sites.tsv"), "w") do io
        println(io, "file\tline\tcol\tcallee\tkeyword\tdefined_by_us")
        for kw in st.kws
            foreign_site(kw) || continue
            occursin('_', kw.kw) || continue
            println(
                io,
                join(
                    [kw.file, kw.line, kw.col,
                        (kw.root == "" ? "" : kw.root * ".") * kw.callee, kw.kw,
                        kw.kw in all_defined], '\t'),
            )
        end
    end

    mapped_set = Set(mapped)
    open(joinpath(out, "symbol-sites.tsv"), "w") do io
        println(io, "file\tline\tsymbol\tnew\tin_call")
        for s in st.syms
            s.name in mapped_set || continue
            println(
                io,
                join([s.file, s.line, ":" * s.name, ":" * new_of[s.name],
                    s.callee], '\t'),
            )
        end
    end
    string_hits = Tuple{String,Int,String,String,String}[]
    open(joinpath(out, "string-sites.tsv"), "w") do io
        println(io, "file\tline\tkind\tin_call\tnames")
        for s in st.strs
            hits = unique([m.match for m in eachmatch(TOKEN, s.text)
                                if m.match in mapped_set])
            isempty(hits) && continue
            push!(string_hits, (s.file, s.line, String(s.kind), s.callee,
                join(hits, ",")))
            println(io, join([s.file, s.line, s.kind, s.callee, join(hits, ",")], '\t'))
        end
    end

    write_data_names(out, st, tokens, new_of)
    write_by_hand(out, st, tokens, byname, mapped, blocked, new_of, string_hits,
        files)
    write_summary(out, st, byname, mapped, blocked, collisions, flag, tokens)
    println("naming_map: ", length(mapped), " names mapped, ", length(blocked),
        " blocked, ", length(collisions), " collision lines; written to ", out)
    return 0
end

include(joinpath(@__DIR__, "naming-report.jl"))

exit(main(ARGS) === 0 ? 0 : 1)
