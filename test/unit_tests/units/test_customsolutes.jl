# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests for `CustomNonBio` and `CustomPolymer` (src/BulkElectronDensity): user-supplied
# non-biological components and polymer chain families. Each is compared with the
# built-in solute whose numbers it is given: the table row "sodium chloride" and the
# PEG line (`PEG_V0_INTERCEPT`, `PEG_V0_PER_UNIT`, 24 electrons per unit) at n = 22.

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.BulkElectronDensity:
    Solute, NonBiological, Polymer, CustomNonBio, CustomPolymer, ρₑ
using BAYSOL.BulkElectronDensity: NONBIO_MEAN_UNCERTAINTY, POLYMER_UNKNOWN_REL_UNC
using BAYSOL.BulkElectronDensity: PEG_V0_INTERCEPT, PEG_V0_PER_UNIT
using BAYSOL.BulkElectronDensity: _ρₑ_i, ϕ°

const BED_ = BAYSOL.BulkElectronDensity
const PH, SPH = 7.4, 0.05
chk(s) = ρₑ(PH, SPH, Solute[s])

@testset "CustomNonBio" begin
    Z, v, u = ϕ°("sodium chloride")
    ref = ρₑ(PH, SPH, Solute[NonBiological(0.2, 0.002, "sodium chloride")])

    @testset "table numbers reproduce the table row" begin
        got = ρₑ(PH, SPH, Solute[CustomNonBio(0.2, 0.002, "NaCl", Z, v, u)])
        @test got[1] == ref[1]
        @test got[2] == ref[2]
    end

    @testset "σ_ϕ° = nothing is the fallback and follows pmv_fallback_uncert" begin
        c = Solute[CustomNonBio(0.2, 0.002, "x", Z, v, nothing)]
        e = Solute[CustomNonBio(0.2, 0.002, "x", Z, v, NONBIO_MEAN_UNCERTAINTY)]
        @test ρₑ(PH, SPH, c) == ρₑ(PH, SPH, e)
        wide = ρₑ(PH, SPH, c; pmv_fallback_uncert = 10 * NONBIO_MEAN_UNCERTAINTY)
        @test wide[1] == ρₑ(PH, SPH, c)[1]
        @test wide[2] > ρₑ(PH, SPH, c)[2]
        @test _ρₑ_i(c[1], PH, SPH, 3.5)[3] == 3.5
    end

    @testset "a negative ϕ° (an ion) is accepted" begin
        r = ρₑ(PH, SPH, Solute[CustomNonBio(0.1, 0.001, "ion", 18, -20.0, 1.0)])
        @test all(isfinite, r)
    end

    @testset "guards" begin
        @test_throws DomainError chk(CustomNonBio(0.1, 0.0, "x", 0, 1.0, 1.0))
        @test_throws DomainError chk(CustomNonBio(0.1, 0.0, "x", 5, NaN, 1.0))
        @test_throws DomainError chk(CustomNonBio(0.1, 0.0, "x", 5, Inf, 1.0))
        @test_throws DomainError chk(CustomNonBio(0.1, 0.0, "x", 5, 1.0, -1.0))
        @test_throws DomainError chk(CustomNonBio(0.1, 0.0, "x", 5, 1.0, NaN))
        @test_throws ArgumentError chk(CustomNonBio(0.1, 0.0, "", 5, 1.0, 1.0))
        @test_throws DomainError chk(CustomNonBio(0.0, 0.0, "x", 5, 1.0, 1.0))
        @test_throws DomainError chk(CustomNonBio(0.1, -1.0, "x", 5, 1.0, 1.0))
    end
end

@testset "CustomPolymer" begin
    n = 22
    Zp, vp, up = BED_._polymer_ϕ°("PEG n=22", PH, SPH)
    # one kind of unit: the PEG line, end groups H and OH (10 electrons, stated by the user)
    peg(σ_unit; nn = n, σ_ends = nothing) = CustomPolymer(
        0.01, 1e-4, "PEG", [nn], [24], [PEG_V0_PER_UNIT], [σ_unit], 10,
        PEG_V0_INTERCEPT,
        σ_ends,
    )

    @testset "one kind of unit reproduces the built-in PEG line" begin
        Z, v, _ = _ρₑ_i(peg(nothing), PH, SPH, 1.0)
        @test Z == Zp
        @test v ≈ vp atol = DEFAULT_ATOL
        a = ρₑ(PH, SPH, Solute[Polymer(0.01, 1e-4, "PEG n=22")])
        b = ρₑ(PH, SPH, Solute[peg(nothing)])
        @test b[1] ≈ a[1] atol = DEFAULT_ATOL
    end

    @testset "two kinds of unit reproduce the built-in Pluronic family" begin
        nEO, nPO = 100.0, 65.0
        Zp2, vp2, _ = BED_._polymer_ϕ°("Pluronic nEO=100 nPO=65", PH, SPH)
        two(σ_unit, σ_ends) = CustomPolymer(
            0.01, 1e-4, "two-unit polymer", [nEO, nPO], [24, 32],
            [BED_.PLURONIC_EO_V0, BED_.PLURONIC_PO_V0], σ_unit, 10,
            BED_.PLURONIC_END_V0,
            σ_ends,
        )
        Z, v, σ = _ρₑ_i(two([nothing, nothing], nothing), PH, SPH, 1.0)
        @test Z == Zp2
        @test v ≈ vp2 atol = DEFAULT_ATOL
        @test Z == 4490
        @test v ≈ 7154.45 atol = 1e-9
        # all unstated: the polymer-grade rule, 2 % of the whole ϕ°
        @test σ ≈ POLYMER_UNKNOWN_REL_UNC * abs(v) atol = DEFAULT_ATOL
        # stated per-unit σ and end σ add in quadrature
        _, _, σ = _ρₑ_i(two([0.3, 0.5], 8.0), PH, SPH, 1.0)
        @test σ ≈ sqrt((0.3 * nEO)^2 + (0.5 * nPO)^2 + 8.0^2) atol = DEFAULT_ATOL
        # a kind that states none contributes 2 % of its own part, the other its own σ
        _, _, σ = _ρₑ_i(two([0.3, nothing], nothing), PH, SPH, 1.0)
        po_part = POLYMER_UNKNOWN_REL_UNC * BED_.PLURONIC_PO_V0 * nPO
        @test σ ≈ sqrt((0.3 * nEO)^2 + po_part^2) atol = DEFAULT_ATOL
    end

    @testset "four kinds of unit, the most" begin
        four = CustomPolymer(
            0.01, 0.0, "tetra", [3.0, 4.0, 5.0, 6.0], [10, 20, 30, 40],
            [1.0, 2.0, 3.0, 4.0], fill(nothing, 4), 5, 7.0, nothing,
        )
        Z, v, _ = _ρₑ_i(four, PH, SPH, 1.0)
        @test Z == 5 + 30 + 80 + 150 + 240
        @test v ≈ 7.0 + 3 + 8 + 15 + 24 atol = DEFAULT_ATOL
        @test BED_.CUSTOM_POLYMER_MAX_UNITS == 4
        five = CustomPolymer(
            0.01, 0.0, "five", fill(3.0, 5), fill(10, 5), fill(1.0, 5),
            fill(nothing, 5),
            5, 7.0, nothing,
        )
        @test_throws ArgumentError ρₑ(PH, SPH, Solute[five])
        none = CustomPolymer(0.01, 0.0, "none", Float64[], Int[], Float64[],
            Union{Nothing,Float64}[], 5, 7.0, nothing)
        @test_throws ArgumentError ρₑ(PH, SPH, Solute[none])
    end

    @testset "the end groups have no default and may be zero" begin
        c = CustomPolymer(0.01, 0.0, "c", [10.0], [24], [36.0], [nothing], 0, 0.0, nothing)
        Z, v, _ = _ρₑ_i(c, PH, SPH, 1.0)
        @test Z == 240 && v == 360.0
    end

    @testset "uncertainty rules, one kind" begin
        _, v, σ = _ρₑ_i(peg(0.05), PH, SPH, 1.0)
        @test σ ≈ 0.05 * n atol = DEFAULT_ATOL
        _, v, σ = _ρₑ_i(peg(nothing), PH, SPH, 1.0)
        @test σ ≈ POLYMER_UNKNOWN_REL_UNC * abs(v) atol = DEFAULT_ATOL
        @test POLYMER_UNKNOWN_REL_UNC == 0.02
        # the stated σ shows in ρₑ's uncertainty, the mean is unchanged
        a = ρₑ(PH, SPH, Solute[peg(0.0)])
        b = ρₑ(PH, SPH, Solute[peg(1.0)])
        @test a[1] == b[1]
        @test b[2] > a[2]
    end

    @testset "guards" begin
        bad(; n = [10.0], Zu = [5], sl = [1.0], su = [nothing], Ze = 10, v0 = 1.0,
            se = nothing, name = "p") =
            ρₑ(PH, SPH, Solute[CustomPolymer(0.01, 0.0, name, n, Zu, sl, su, Ze, v0, se)])
        @test_throws ArgumentError bad(n = [1.5])                 # fewer than 2 units
        @test_throws ArgumentError bad(n = [0.5, 0.5])            # ... in all
        @test_throws DomainError bad(Zu = [0])
        @test_throws DomainError bad(sl = [Inf])
        @test_throws DomainError bad(v0 = NaN)
        @test_throws DomainError bad(n = [NaN])
        @test_throws DomainError bad(n = [-1.0])
        @test_throws DomainError bad(Ze = -1)
        @test_throws DomainError bad(su = [-0.1])
        @test_throws DomainError bad(se = -2.0)
        @test_throws ArgumentError bad(name = "")
        @test_throws ArgumentError bad(n = [10.0, 10.0])          # lengths differ
    end
end

@testset "both types in a mixed Vector{Solute}" begin
    Z, v, u = ϕ°("sodium chloride")
    mixed = Solute[
        NonBiological(0.1, 0.001, "tris"),
        CustomNonBio(0.2, 0.002, "NaCl", Z, v, u),
        CustomPolymer(0.01, 1e-4, "PEG", [22.0], [24], [PEG_V0_PER_UNIT], [nothing], 10,
            PEG_V0_INTERCEPT, nothing),
    ]
    r = ρₑ(PH, SPH, mixed)
    @test all(isfinite, r)
    @test r[2] > 0
end
