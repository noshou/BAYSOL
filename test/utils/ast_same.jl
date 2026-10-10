# SPDX-License-Identifier: LGPL-2.1-or-later

# Compares Julia files before and after a pure
# re-flowing of lines (dev/linelen.tcl --verify):
#
#   julia test/utils/ast_same.jl OLD_ROOT NEW_ROOT file.jl ...
#
# Each file is parsed in both roots; the syntax trees must be equal once line-number
# nodes are dropped and the whitespace inside string literals (docstrings included)
# is collapsed. Prints the files that differ and exits with status 1 if there is any.

# the tree without line-number nodes, string literals with their whitespace runs collapsed
function normalized(x)
    if x isa LineNumberNode
        return nothing
    elseif x isa AbstractString
        return join(split(x), " ")
    elseif x isa Expr
        # in "a" * "b" * f(x) * "c$(y)" the neighbouring string literals are one string:
        # long strings are split this way
        if x.head == :call && length(x.args) >= 3 && x.args[1] == :*
            parts = Any[]
            for a in x.args[2:end]
                if a isa AbstractString
                    push!(parts, a)
                elseif a isa Expr && a.head == :string
                    append!(parts, a.args)
                else
                    push!(parts, a)
                end
            end
            merged = Any[]
            for p in parts
                if p isa AbstractString && !isempty(merged) &&
                   merged[end] isa AbstractString
                    merged[end] *= p
                else
                    push!(merged, p)
                end
            end
            all_text = all(p -> p isa AbstractString, merged)
            if length(merged) == 1 && all_text
                return normalized(merged[1])
            elseif any(a -> a isa Expr && a.head == :string, x.args[2:end]) &&
                   all(a -> a isa AbstractString || (a isa Expr && a.head == :string),
                x.args[2:end])
                return normalized(Expr(:string, merged...))
            end
            return Expr(:call, :*, Any[normalized(m) for m in merged]...)
        end
        args = Any[normalized(a) for a in x.args if !(a isa LineNumberNode)]
        return Expr(x.head, args...)
    else
        return x
    end
end

function tree(path)
    text = read(path, String)
    return normalized(Meta.parseall(text; filename = path))
end

# the first place where two normalized trees differ, as a short text
function first_difference(a, b)
    if a isa Expr && b isa Expr && a.head == b.head && length(a.args) == length(b.args)
        for (x, y) in zip(a.args, b.args)
            x == y || return first_difference(x, y)
        end
    end
    return string(a, "  <>  ", b)[1:min(end, 300)]
end

function main(args)
    old_root, new_root = args[1], args[2]
    bad = String[]
    for f in args[3:end]
        a = tree(joinpath(old_root, f))
        b = tree(joinpath(new_root, f))
        if a != b
            push!(bad, f)
            println(f, ": ", first_difference(a, b))
        end
    end
    for f in bad
        println("DIFFERENT CODE: ", f)
    end
    exit(isempty(bad) ? 0 : 1)
end

main(ARGS)
