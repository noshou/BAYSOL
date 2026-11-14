# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/molecular-structure/atomic-radii.jl: ion-string parsing, the
# ionKey round-trip, the raw table lookups, and the resolveOne fallback chain.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.MolecularStructure:
    Ion, tryparseIon, ionKey, ionRadius,
    elementRadius, nearestIon, resolveOne, lookupRadii

lookupOne(ion) = lookupRadii([ion])[1][2]

@testset "AtomicRadii" begin

    @testset "tryparseIon: magnitude-then-sign and sign-then-magnitude" begin
        @test tryparseIon("fe3+") == Ion("fe", 3)
        @test tryparseIon("fe+3") == Ion("fe", 3)
        @test tryparseIon("fe3-") == Ion("fe", -3)
        @test tryparseIon("fe-3") == Ion("fe", -3)
        @test tryparseIon("fe12+") == Ion("fe", 12)     # multi-digit magnitude
        @test tryparseIon("h1+") == Ion("h", 1)
        @test tryparseIon("x+") == Ion("x", 1)        # 1-letter element
    end

    @testset "tryparseIon: a bare sign means +/-1" begin
        @test tryparseIon("fe+") == Ion("fe", 1)
        @test tryparseIon("fe-") == Ion("fe", -1)
        @test tryparseIon("fe+") == tryparseIon("fe1+") == tryparseIon("fe+1")
        @test tryparseIon("fe-") == tryparseIon("fe1-") == tryparseIon("fe-1")
    end

    @testset "tryparseIon: surrounding and interior whitespace is tolerated" begin
        @test tryparseIon(" fe3+ ") == Ion("fe", 3)
        @test tryparseIon("fe 3 +") == Ion("fe", 3)
        @test tryparseIon("\tfe+3\n") == Ion("fe", 3)
    end

    @testset "tryparseIon: bare elements are not ions" begin
        # `nothing` here is the signal that sends resolveOne straight to the
        # bare-element table, so it is a contract, not an error.
        @test tryparseIon("fe") === nothing
        @test tryparseIon("h") === nothing
        @test tryparseIon("rn") === nothing
    end

    @testset "tryparseIon: charge 0 is rejected outright" begin
        # the magnitude alternation starts at [1-9], so "0" cannot be a magnitude
        @test tryparseIon("fe0+") === nothing
        @test tryparseIon("fe+0") === nothing
        @test tryparseIon("fe0-") === nothing
    end

    @testset "tryparseIon: unparseable junk" begin
        @test tryparseIon("") === nothing
        @test tryparseIon("Fe3+") === nothing   # uppercase: table keys are lowercase
        @test tryparseIon("fe3") === nothing   # magnitude with no sign
        @test tryparseIon("abc3+") === nothing   # element is 1-2 letters
        @test tryparseIon("3+") === nothing   # no element
        @test tryparseIon("fe!!") === nothing
        @test tryparseIon("fe3++") === nothing
        @test tryparseIon("fe3.5+") === nothing
    end

    @testset "ionKey: canonical digits-then-sign form, charge 0 rejected" begin
        @test ionKey(Ion("fe", 3)) == "fe3+"
        @test ionKey(Ion("fe", -3)) == "fe3-"
        @test ionKey(Ion("fe", 1)) == "fe1+"
        @test ionKey(Ion("au", -1)) == "au1-"
        @test_throws ArgumentError ionKey(Ion("fe", 0))
    end

    @testset "ionKey normalizes either token order to one key" begin
        @test ionKey(tryparseIon("fe+3")) == ionKey(tryparseIon("fe3+")) == "fe3+"
        @test ionKey(tryparseIon("fe-")) == "fe1-"
    end

    @testset "raw table lookups" begin
        @test checkFloat(ionRadius("fe3+"), 0.49)      # pm -> Å conversion applied
        @test checkFloat(ionRadius("o2-"), 1.35)
        @test ionRadius("qq9+") === nothing
        er = elementRadius("fe")
        @test er isa Tuple{Float64,String}
        @test checkFloat(er[1], 2.44) && er[2] == "vdw"
        @test elementRadius("o")[2] == "vdw"
        @test elementRadius("qq") === nothing
    end

    @testset "nearestIon picks the closest on-file charge state" begin
        # fe has 2+, 3+, 4+, 6+ on file (no 5+)
        @test nearestIon("fe", 3) == "fe3+"          # exact state is also the nearest
        @test nearestIon("fe", 5) == "fe4+"          # tie 4+/6+ broken toward the first
        @test nearestIon("fe", 9) == "fe6+"
        @test nearestIon("fe", -3) == "fe2+"         # distance is on signed charge
        @test nearestIon("h", -1) == "h1-"           # h has both signs on file
        @test nearestIon("h", 4) == "h1+"
        @test nearestIon("qq", 1) === nothing        # element has no charge states
        @test nearestIon("rn", 1) === nothing        # noble gas: no charge states on file
    end

    @testset "resolveOne, step 1: exact ionic match, both token orderings" begin
        @test checkFloat(0.49, resolveOne("fe3+"))
        @test checkFloat(0.49, resolveOne("fe+3"))
        @test checkFloat(2.2, resolveOne("au1-"))
        @test checkFloat(1.35, resolveOne("o2-"))
        @test resolveOne("fe3+") === ionRadius("fe3+")   # straight from the ionic table
    end

    @testset "resolveOne, step 2: nearest-charge fallback" begin
        # fe5+ is not on file; the chain must land on fe4+, not on bare fe
        v5, v4 = resolveOne("fe5+"), resolveOne("fe4+")
        @test v5 !== nothing && v4 !== nothing && checkFloat(v5, v4)
        @test v5 !== elementRadius("fe")[1]              # it did NOT fall to bare fe
        @test checkFloat(resolveOne("fe5+"), ionRadius(nearestIon("fe", 5)))
        @test checkFloat(resolveOne("fe9+"), ionRadius("fe6+"))
    end

    @testset "resolveOne, step 3: bare-element fallback for a parsed ion" begin
        # rn parses as an ion but has no ionic entry and no charge states at all,
        # so the only rung left is atomic_radii
        @test checkFloat(resolveOne("rn3+"), 2.4)
        @test checkFloat(resolveOne("rn3+"), elementRadius("rn")[1])
        @test checkFloat(resolveOne("ne1+"), elementRadius("ne")[1])
    end

    @testset "resolveOne: unparseable strings go straight to the bare table" begin
        @test checkFloat(2.44, resolveOne("fe"))
        @test checkFloat(2.4, resolveOne("rn"))
        @test checkFloat(1.2, resolveOne("h"))
        @test resolveOne("Fe") === nothing   # unparseable AND not a table key
        @test resolveOne("fe!!") === nothing
    end

    @testset "resolveOne, step 4: total miss returns nothing" begin
        @test resolveOne("qq3+") === nothing   # parses, but no ionic/charge/atomic data
        @test resolveOne("zzzz9+") === nothing # does not even parse
        @test resolveOne("") === nothing
    end

    @testset "resolveOne is exhaustive over the chain's return type" begin
        for s in ("fe3+", "fe5+", "rn3+", "fe", "qq3+", "")
            v = resolveOne(s)
            @test v === nothing || v isa Float64
        end
    end

    @testset "lookup: order/count preserved, repeats deduped" begin
        input = ["fe3+", "zzzz9+", "fe3+", "rn"]
        res = lookupRadii(input)
        @test res isa Vector{Tuple{String,Union{Float64,Nothing}}}
        @test length(res) == length(input)
        @test [k for (k, _) in res] == input
        r1, m, r2, r3 = (v for (_, v) in res)
        @test r1 !== nothing && m === nothing && r3 !== nothing && checkFloat(r1, r2)
    end

    @testset "lookup: repeated misses are deduped too" begin
        res = lookupRadii(["qq3+", "qq3+", "fe", "qq3+"])
        @test [v for (_, v) in res] == [nothing, nothing, resolveOne("fe"), nothing]
    end

    @testset "lookup agrees with resolveOne entry by entry" begin
        input = ["fe3+", "fe+3", "fe5+", "rn3+", "o2-", "h", "qq3+", "fe!!"]
        @test [v for (_, v) in lookupRadii(input)] == [resolveOne(s) for s in input]
    end

    @testset "lookup: empty input" begin
        res = lookupRadii(String[])
        @test isempty(res)
        @test res isa Vector{Tuple{String,Union{Float64,Nothing}}}
    end

    @testset "lookup: non-String element types are normalized to String" begin
        res = lookupRadii(SubString.(["fe3+", "rn"]))
        @test [k for (k, _) in res] == ["fe3+", "rn"]
        @test all(k -> k isa String, first.(res))
    end

end
