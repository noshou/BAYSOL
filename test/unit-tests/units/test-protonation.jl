# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises the Henderson-Hasselbalch protonation helpers in
# src/hydrogenator/propka.jl (used to choose pdb2pqr's
# --neutraln/--neutralc terminus flags).

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Hydrogenator: Hydrogenator

include(joinpath(@__DIR__, "..", "floatcompare.jl"))   # close_

const _fractionProtonated   = Hydrogenator._fractionProtonated
const _fractionDeprotonated = Hydrogenator._fractionDeprotonated
const _groupProtonated      = Hydrogenator._groupProtonated

# Independent re-derivation of the HH fraction formulas, not a call into the
# functions under test wearing a different hat.
refFracBase(pH, pKa) = 1.0 / (1.0 + 10.0^(pH - pKa))
refFracAcid(pH, pKa) = 1.0 / (1.0 + 10.0^(pKa - pH))

@testset "Protonation" begin

    @testset "HH: pH == pKa -> fraction is exactly 0.5, both acid and base" begin
        @test close_(_fractionProtonated(7.0, 7.0), 0.5)
        @test close_(_fractionDeprotonated(7.0, 7.0), 0.5)
    end

    # …-> 0 well above
    @testset "HH: base group -> protonated fraction -> 1 well below pKa" begin
        @test close_(_fractionProtonated(0.0, 10.0), 1.0; atol = 1e3 * DEFAULT_ATOL)
        @test close_(_fractionProtonated(20.0, 10.0), 0.0; atol = 1e3 * DEFAULT_ATOL)
    end

    # …-> 1 well above
    @testset "HH: acid group -> deprotonated fraction -> 0 well below pKa" begin
        @test close_(_fractionDeprotonated(0.0, 10.0), 0.0; atol = 1e3 * DEFAULT_ATOL)
        @test close_(_fractionDeprotonated(20.0, 10.0), 1.0; atol = 1e3 * DEFAULT_ATOL)
    end

    @testset "HH: matches an independent reference re-derivation" begin
        for (pH, pKa) in [(7.4, 3.9), (7.4, 10.5), (5.0, 6.0), (9.0, 6.0)]
            @test close_(_fractionProtonated(pH, pKa), refFracBase(pH, pKa))
            @test close_(_fractionDeprotonated(pH, pKa), refFracAcid(pH, pKa))
        end
    end

    @testset "_groupProtonated: base protonated below pKa, acid protonated below pKa" begin
        @test _groupProtonated("base", 5.0, 10.0)
        @test !_groupProtonated("base", 12.0, 10.0)
        @test _groupProtonated("acid", 2.0, 4.0)
        @test !_groupProtonated("acid", 7.0, 4.0)
    end

    @testset "_groupProtonated: exactly at pKa rounds to the uncharged state" begin
        @test !_groupProtonated("base", 7.0, 7.0)   # uncharged base = deprotonated
        @test _groupProtonated("acid", 7.0, 7.0)    # uncharged acid = protonated
    end

    @testset "_groupProtonated: rejects unknown type" begin
        @test_throws ArgumentError _groupProtonated("neither", 7.0, 7.0)
    end
end
