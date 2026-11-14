# SPDX-License-Identifier: LGPL-3.0-or-later

# One-off: after the camelCase rename, parses every fitting script (no fit is run) and
# checks that each call of a BAYSOL name uses a function that exists and keywords that
# one of its methods accepts.
#
# Usage: julia --startup-file=no --project=. dev/scripts/naming-check-scripts.jl

using BAYSOL

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))

"The keyword names a function's methods accept (a method with `kw...` accepts any)."
function accepted(f)
    names = Set{Symbol}()
    for m in methods(f)
        for k in Base.kwarg_decl(m)
            if endswith(string(k), "...")
                return nothing
            end
            push!(names, k)
        end
    end
    return names
end

function walk!(problems, file, ex)
    ex isa Expr || return
    if ex.head === :call && ex.args[1] isa Symbol && isdefined(BAYSOL, ex.args[1])
        f = getfield(BAYSOL, ex.args[1])
        if f isa Function
            kws = [a.args[1] for a in ex.args[2:end] if a isa Expr && a.head === :kw]
            for p in ex.args[2:end]
                p isa Expr && p.head === :parameters &&
                    append!(kws,
                        [a.args[1] for a in p.args if a isa Expr && a.head === :kw])
            end
            acc = accepted(f)
            if acc !== nothing
                for k in kws
                    k in acc || push!(problems, "$file: $(ex.args[1]) has no keyword $k")
                end
            end
        end
    end
    for a in ex.args
        walk!(problems, file, a)
    end
end

function main()
    problems = String[]
    names = Set{Symbol}()
    count = 0
    for dir in readdir(joinpath(ROOT, "test", "fitting_tests"); join = true)
        isdir(dir) || continue
        for f in filter(endswith(".jl"), readdir(dir; join = true))
            count += 1
            text = read(f, String)
            ex = Meta.parseall(text; filename = f)
            for m in eachmatch(r"BAYSOL\.([A-Za-z_][A-Za-z0-9_!]*)", text)
                push!(names, Symbol(m.captures[1]))
            end
            walk!(problems, relpath(f, ROOT), ex)
        end
    end
    for n in sort!(collect(names))
        isdefined(BAYSOL, n) || push!(problems, "BAYSOL.$n is not defined")
    end
    nNames, nProblems = length(names), length(problems)
    println("scripts: $count, BAYSOL names used: $nNames, problems: $nProblems")
    foreach(println, problems)
    return isempty(problems) ? 0 : 1
end

exit(main())
