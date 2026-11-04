# SPDX-License-Identifier: LGPL-3.0-or-later

# Harvests the default of every setting into one JSON file,
# `tui/assets/data/default_settings.json`: setting name -> `{default, type, limits}` and,
# where they apply, `choices` (a setting with a fixed set of values) and `shape` and
# `parts` (a tuple: what each part is, and its name).

using BAYSOL
using Colors: color_names
using JSON3

const ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const DEFAULT_OUT = joinpath(ROOT, "tui", "assets", "data", "default_settings.json")
const MODULES = (BAYSOL.Inference, BAYSOL.Geometry, BAYSOL.Scattering, BAYSOL.Pipeline)
const LIMIT_KEYS = (:above, :below, :at_least, :at_most)
const RELATION_RULES =
    (:inside, :within_width, :ordered, :all_above, :at_most_setting, :opacity)

"The module whose `Params.jl` defines the setting `s`."
function owner(s::Symbol)
    owners = [m for m in MODULES if isdefined(m, s) && Base.binding_module(m, s) === m]
    length(owners) == 1 || error("setting $s is defined in $(length(owners)) modules")
    return only(owners)
end

"JSON text of the value `v`."
json(::Nothing) = "null"
json(v::Bool) = v ? "true" : "false"
json(v::Integer) = string(v)
json(v::AbstractFloat) = isfinite(v) ? string(v) : error("a non-finite default: $v")
json(v::Union{Symbol,AbstractString}) = JSON3.write(String(v))
json(v::Union{Tuple,AbstractVector}) = "[" * join(json.(v), ", ") * "]"
json(v::NamedTuple) = json_object((String(k), x) for (k, x) in pairs(v))
json(v::AbstractDict) = json_object((String(k), x) for (k, x) in v)

"JSON text of an object with the `(key, value)` pairs in order."
json_object(pairs) =
    "{" * join(("$(JSON3.write(k)): $(json(x))" for (k, x) in pairs), ", ") * "}"

"The choices of `name` (`SETTING_CHOICES` of its module), or `nothing`."
function choices_of(name::Symbol)
    m = owner(name)
    isdefined(m, :SETTING_CHOICES) || return nothing
    return get(getfield(m, :SETTING_CHOICES), name, nothing)
end

"""
The shape of a tuple default: the kind of each part (`"int"`, `"float"` or `"colour"`), in
an array, or in an object for a named tuple.
"""
function shape_of(v)
    kind(x) =
        x isa Integer ? "int" :
        x isa Real ? "float" :
        x isa Symbol ? "colour" :
        error("a tuple default has a part of type $(typeof(x))")
    v isa NamedTuple && return NamedTuple{keys(v)}(map(kind, values(v)))
    return kind.(v)
end

"""
The part names of the tuple setting `name` (`SETTING_PARTS` of its module).
"""
function parts_of(name::Symbol, v)
    m = owner(name)
    table = isdefined(m, :SETTING_PARTS) ? getfield(m, :SETTING_PARTS) : (;)
    haskey(table, name) || error("tuple setting $name has no SETTING_PARTS")
    parts = table[name]
    length(parts) == length(v) ||
        error("setting $name has $(length(v)) parts but $(length(parts)) names")
    return collect(parts)
end

"The limits of `name` (`SETTING_LIMITS` of its module); empty when it has none."
function limits_of(name::Symbol)
    table = getfield(owner(name), :SETTING_LIMITS)
    haskey(table, name) || return (;)
    lim = table[name]
    for k in keys(lim)
        k in LIMIT_KEYS || error("setting $name: unknown limit $k")
    end
    return lim
end

"The whole defaults file."
function harvest()
    names = BAYSOL.Pipeline._setting_names()
    allunique(names) || error("a setting is in SETTING_NAMES twice")
    named = Set(names)
    lines = String[]
    for name in names
        v = getfield(owner(name), name)
        kind = BAYSOL.Pipeline.setting_kind(name, v)
        choices = choices_of(name)
        if choices !== nothing
            all(c -> c in choices, v) || error("setting $name: a default is no choice")
        end
        fields =
            Pair{String,Any}["default"=>v, "type"=>String(kind), "limits"=>limits_of(name)]
        choices === nothing || push!(fields, "choices" => collect(choices))
        if kind === :tuple
            push!(fields, "shape" => shape_of(v), "parts" => parts_of(name, v))
        end
        push!(lines, " $(JSON3.write(String(name))): " * json_object(fields))
    end
    for m in MODULES, table in (:SETTING_LIMITS, :SETTING_CHOICES, :SETTING_PARTS)
        isdefined(m, table) || continue
        for k in keys(getfield(m, table))
            k in named ||
                error("$table of $(nameof(m)) names $k, which is in no SETTING_NAMES")
        end
    end
    return "{\n" * join(lines, ",\n") * "\n}\n", named
end

"""
The rules that tie settings together: an array of objects, the `SETTING_RELATIONS` of
every module.
"""
function relations_json(named::Set{Symbol})
    lines = String[]
    for m in MODULES
        isdefined(m, :SETTING_RELATIONS) || continue
        for r in getfield(m, :SETTING_RELATIONS)
            r.rule in RELATION_RULES || error("unknown relation rule $(r.rule)")
            fields = Pair{String,Any}[]
            for (k, v) in pairs(r)
                v === nothing && continue
                if v isa Symbol && k !== :rule
                    v in named || error("relation $(r.rule): $v is in no SETTING_NAMES")
                end
                push!(fields, String(k) => v)
            end
            push!(lines, " " * json_object(fields))
        end
    end
    return "[\n" * join(lines, ",\n") * "\n]\n"
end

"""
The colours a setting may hold as one JSON object, `"name": "#rrggbb"`: the names
`Colors.parse` knows and their colour, which the terminal interface shows as a swatch.
"""
function colour_names()
    hex(c) = "#" * join(string.(c; base = 16, pad = 2))
    rows = [
        " $(JSON3.write(name)): $(JSON3.write(hex(c)))"
        for (name, c) in sort!(collect(color_names); by = first)
    ]
    return "{\n" * join(rows, ",\n") * "\n}\n"
end

function main(args)
    out = isempty(args) ? DEFAULT_OUT : abspath(only(args))
    text, named = harvest()
    mkpath(dirname(out))
    write(out, text)
    colours = joinpath(
        dirname(out),
        replace(basename(out), "default_settings" => "colours"),
    )
    relations = joinpath(
        dirname(out),
        replace(basename(out), "default_settings" => "setting_relations"),
    )
    write(colours, colour_names())
    write(relations, relations_json(named))
    println("harvest defaults: wrote $out, $colours and $relations")
    return 0
end

exit(main(ARGS))
