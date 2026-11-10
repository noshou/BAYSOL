# SPDX-License-Identifier: LGPL-3.0-or-later

# The polymer families the terminal interface offers (tui/assets/data/polymer_families.json)
# against the code that parses their `arg` strings (`_polymer_ϕ°`): every template, filled
# with sample numbers, must resolve to a finite positive Z and ϕ°, so the file and
# src/BulkElectronDensity/Polymers cannot drift apart.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.BulkElectronDensity: JSON3
using BAYSOL.BulkElectronDensity: _polymer_ϕ°

const FAMILIES =
    joinpath(@__DIR__, "..", "..", "..", "tui", "assets", "data", "polymer_families.json")

# Sample numbers by key; a family that needs another value for a key says so by id.
const SAMPLE = Dict("n" => 10, "Mn" => 3350, "nEO" => 100, "nPO" => 65, "nC" => 12)
const SAMPLE_BY_ID = Dict(("cyclodextrin", "n") => 7)

fill_template(id, form, values = Dict()) = replace(form[:template],
    r"\{([^}]+)\}" =>
        m -> begin
            key = String(m[2:(end-1)])
            string(get(values, key, get(SAMPLE_BY_ID, (id, key), SAMPLE[key])))
        end)

tokens(template) = String[m.captures[1] for m in eachmatch(r"\{([^}]+)\}", template)]

@testset "polymer families of the interface resolve" begin
    families = JSON3.read(read(FAMILIES, String))
    @test families isa AbstractVector && !isempty(families)
    ids = [f[:id] for f in families]
    @test allunique(ids)
    for f in families
        @test !isempty(f[:names]) && all(n -> n == lowercase(n), f[:names])
        @test !isempty(f[:forms])
        for form in f[:forms]
            keys_ = [a[:key] for a in form[:args]]
            @testset "$(f[:id]): $(form[:template])" begin
                # the template uses exactly the arguments it asks for, and each is sampled
                @test sort(unique(tokens(form[:template]))) == sort(keys_)
                @test allunique(keys_)
                @test all(k -> haskey(SAMPLE, k), keys_)
                arg = fill_template(f[:id], form)
                Z, ϕ, σ = _polymer_ϕ°(arg)
                @test isfinite(Z) && Z > 0
                @test isfinite(ϕ) && ϕ > 0
                @test isfinite(σ) && σ >= 0
            end
        end
    end
end

@testset "the Mn of dextran and pullulan reads kDa below 1000, g/mol above" begin
    for name in ("dextran", "pullulan")
        @test _polymer_ϕ°("$name 40") == _polymer_ϕ°("$name 40000")
        @test _polymer_ϕ°("$name 70") == _polymer_ϕ°("$name 70000")
        Z, ϕ, _ = _polymer_ϕ°("$name 40")
        @test Z > 0 && ϕ > 0
    end
    # the units form shares the Mn form's template shape, but is another family input
    @test _polymer_ϕ°("dextran n=10")[1] > 0
end
