# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises the `SETTING_LIMITS` tables of the four `Params.jl` files, which the terminal
# interface enforces when a user edits a setting: every limit names a setting that exists,
# uses a known kind of limit, and the default of the setting satisfies it.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL: Inference, Geometry, Scattering, Pipeline

const MODULES = (Inference, Geometry, Scattering, Pipeline)
const KINDS = (:above, :below, :at_least, :at_most)

"Does `v` satisfy the limit `kind` with bound `bound`?"
function satisfies(v, kind::Symbol, bound)
    kind === :above && return v > bound
    kind === :below && return v < bound
    kind === :at_least && return v ≥ bound
    return v ≤ bound
end

@testset "setting limits" begin
    for m in MODULES
        table = getfield(m, :SETTING_LIMITS)
        @testset "$(nameof(m))" begin
            for (name, limits) in pairs(table)
                @test isdefined(m, name)
                @test all(k -> k in KINDS, keys(limits))
                v = getfield(m, name)
                @test v isa Real && !(v isa Bool)
                for (kind, bound) in pairs(limits)
                    @test satisfies(v, kind, bound)
                end
            end
        end
    end

    @testset "the choices of a setting hold its default" begin
        for (name, choices) in pairs(Pipeline.SETTING_CHOICES)
            @test isdefined(Pipeline, name)
            @test all(c -> c in choices, getfield(Pipeline, name))
            @test allunique(choices)
        end
    end

    @testset "every tuple setting has a name for each of its parts" begin
        tuples = Symbol[]
        for m in MODULES, name in getfield(m, :SETTING_NAMES)
            Pipeline.setting_kind(name, getfield(m, name)) === :tuple && push!(tuples, name)
        end
        named = Symbol[]
        for m in MODULES
            isdefined(m, :SETTING_PARTS) || continue
            for (name, parts) in pairs(getfield(m, :SETTING_PARTS))
                push!(named, name)
                @test Base.binding_module(m, name) === m
                @test length(parts) == length(getfield(m, name))
                @test allunique(parts)
                @test all(p -> p isa String && !isempty(p), parts)
                getfield(m, name) isa NamedTuple &&
                    @test collect(Symbol.(parts)) == collect(keys(getfield(m, name)))
            end
        end
        @test Set(named) == Set(tuples)
    end

    @testset "a limit lives with the module that defines the setting" begin
        for m in MODULES, name in keys(getfield(m, :SETTING_LIMITS))
            @test Base.binding_module(m, name) === m
        end
    end
end
