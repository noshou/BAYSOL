# SPDX-License-Identifier: LGPL-2.1-or-later

# End-to-end tests for src/BulkElectronDensity/BulkElectronDensity.jl
# and src/Inference (`ρₑ_prior`): bulk solution electron density
# (`ρₑ`) and its `LogNormal` prior (`ρₑ_prior`), exercised through
# `BulkElectronDensity._ρₑ_w`/`BulkElectronDensity.ϕ°` pipeline.

include(joinpath(@__DIR__, "..", "testsetup.jl"))

const FIT = BAYSOL.Inference
const BED = BAYSOL.BulkElectronDensity
using BAYSOL.BulkElectronDensity:
    Solute, Protein, NonBiological, DNA, RNA, DEFAULT_TEMPERATURE_C
using BAYSOL.Inference: ρₑ_prior
using BAYSOL.PhysicalConstants: AVOGADRO, ANGSTROM3_PER_LITER, CM3_PER_LITER
using BAYSOL.BulkElectronDensity: PMV_REFERENCE_TEMPERATURE_C
using Distributions: mean, var, LogNormal

include(joinpath(@__DIR__, "..", "..", "utils", "floatcompare.jl"))   # close_
# LYSOZYME, ...
include(joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "sequences.jl"))

"""
Independent re-derivation of the `ρₑ`/`ρₑ_prior` formula from the live
`BulkElectronDensity._ρₑ_w`/`BulkElectronDensity.ϕ°` calls:

    ρₑ = ρ_w(T) + Σ_j C_j · (N_A·Z_j/1e27 − ρ_w(T)·ϕ°_j/1e3)
    σ² = (1 − Σ_j C_j·ϕ°_j/1e3)² · σ_w²
        + Σ_j k_j² · σ_C_j²
        + Σ_j (C_j·ρ_w/1e3)² · (σ_ϕ°_j² + (α·ϕ°_j·|t − 25|)²)
"""
function ref_ρₑ(
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Solute};
    t::Real = DEFAULT_TEMPERATURE_C,
)
    ρw, σw = BED._ρₑ_w(t)
    ρw_k = ρw / CM3_PER_LITER
    α = BED.PMV_FRACTIONAL_EXPANSIBILITY

    disp = 0.0
    Δμ = 0.0
    var_conc = 0.0
    var_vol = 0.0
    for s in solutes
        Z, ϕ, σϕ =
            s isa Protein ? BED.ϕ°(pH, s.arg; σ_pH) :
            s isa DNA ? BED.ϕ°(true, pH, s.arg; σ_pH) :
            s isa RNA ? BED.ϕ°(false, pH, s.arg; σ_pH) :
            BED.ϕ°(s.arg)
        C, σC = s.molarity, s.molarity_uncertainty
        k = AVOGADRO * Z / ANGSTROM3_PER_LITER - ρw_k * ϕ

        disp     += C * ϕ / CM3_PER_LITER
        Δμ       += C * k
        var_conc += k^2 * σC^2
        σT       = α * abs(ϕ) * abs(t - PMV_REFERENCE_TEMPERATURE_C)
        var_vol  += (C * ρw_k)^2 * (σϕ^2 + σT^2)
    end

    μ = ρw + Δμ
    σ = sqrt((1.0 - disp)^2 * σw^2 + var_conc + var_vol)
    return μ, σ
end

"""
`LogNormal` params moment-matched to `(μ, σ)` exactly as `ρₑ_prior` does,
independently of `ρₑ_prior`'s own code.
"""
function ref_lognormal(μ::Real, σ::Real)
    σ_ln = sqrt(log(1 + (σ / μ)^2))
    μ_ln = log(μ) - σ_ln^2 / 2
    return μ_ln, σ_ln
end

# `BulkElectronDensity.ϕ°` memoizes per (sequence, pH, σ_pH), so a repeated
# query is free and a query at another pH or σ_pH is computed afresh. The tests
# below still pad each query's sequence with a random run of 'X'/'*' (documented
# no-ops), so no test depends on an earlier one having warmed the entry.
fresh_seq_dns(base::AbstractString) = base * String(rand(('X', '*'), 48))

@testset "BulkElectronDensity + ρₑ_prior" begin

    #------------------------------------------------------------------
    #                 ρₑ -- single-solute agreement
    #------------------------------------------------------------------

    @testset "ρₑ: single NonBiological solute matches the reference formula" begin
        solutes = Solute[NonBiological(0.5, 0.01, "urea")]
        μ, σ = BED.ρₑ(7.0, 0.0, solutes)
        μ_ref, σ_ref = ref_ρₑ(7.0, 0.0, solutes)
        @test close_(μ, μ_ref)
        @test close_(σ, σ_ref)
        # sanity: adding a solute genuinely shifts ρₑ away from pure water.
        ρw, _ = BED._ρₑ_w(DEFAULT_TEMPERATURE_C)
        @test !close_(μ, ρw)
    end

    @testset "ρₑ: single non-ionizable Protein solute matches the reference formula" begin
        solutes = Solute[Protein(1.0e-3, 1.0e-5, "GGGG")]
        μ, σ = BED.ρₑ(7.0, 0.0, solutes)
        μ_ref, σ_ref = ref_ρₑ(7.0, 0.0, solutes)
        @test close_(μ, μ_ref)
        @test close_(σ, σ_ref)
    end

    @testset "ρₑ: mixed Protein + NonBiological solutes sum correctly" begin
        solutes = Solute[
            NonBiological(0.5, 0.01, "urea"),
            Protein(1.0e-3, 1.0e-5, "GGGGXX"),
        ]
        μ, σ = BED.ρₑ(7.0, 0.0, solutes)
        μ_ref, σ_ref = ref_ρₑ(7.0, 0.0, solutes)
        @test close_(μ, μ_ref)
        @test close_(σ, σ_ref)

        # additivity: the two-solute mean shift equals the sum of the
        # single-solute mean shifts (linear in concentration).
        ρw, _ = BED._ρₑ_w(DEFAULT_TEMPERATURE_C)
        μ_urea, _ = BED.ρₑ(7.0, 0.0, Solute[NonBiological(0.5, 0.01, "urea")])
        μ_prot, _ = BED.ρₑ(7.0, 0.0, Solute[Protein(1.0e-3, 1.0e-5, "GGGGXX")])
        @test close_(μ, ρw + (μ_urea - ρw) + (μ_prot - ρw))
    end

    @testset "ρₑ: multiple real Protein + a real small molecule" begin
        solutes = Solute[
            Protein(2.0e-4, 5.0e-6, LYSOZYME),
            Protein(1.0e-4, 2.0e-6, "GGGGZZ"),
            NonBiological(1.0, 0.05, "urea"),
            NonBiological(0.1, 0.001, "glycerol"),
        ]
        μ, σ = BED.ρₑ(7.4, 0.05, solutes)
        μ_ref, σ_ref = ref_ρₑ(7.4, 0.05, solutes)
        @test close_(μ, μ_ref)
        @test close_(σ, σ_ref)
        @test σ > 0.0
    end

    #------------------------------------------------------------------
    #                 ρₑ -- DNA / RNA solutes
    #------------------------------------------------------------------

    @testset "ρₑ: single DNA solute matches the reference formula" begin
        solutes = Solute[DNA(1.0e-4, 1.0e-6, "ATGC")]
        μ, σ = BED.ρₑ(7.0, 0.0, solutes)
        μ_ref, σ_ref = ref_ρₑ(7.0, 0.0, solutes)
        @test close_(μ, μ_ref)
        @test close_(σ, σ_ref)
        ρw, _ = BED._ρₑ_w(DEFAULT_TEMPERATURE_C)
        @test !close_(μ, ρw)
    end

    @testset "ρₑ: single RNA solute matches the reference formula" begin
        solutes = Solute[RNA(1.0e-4, 1.0e-6, "AUGC")]
        μ, σ = BED.ρₑ(7.0, 0.0, solutes)
        μ_ref, σ_ref = ref_ρₑ(7.0, 0.0, solutes)
        @test close_(μ, μ_ref)
        @test close_(σ, σ_ref)
    end

    # …(A/G/C shared, T vs U)
    @testset "ρₑ: DNA and RNA are distinct despite one-letter-code overlap" begin
        # same molarity/uncertainty, same-length sequence; any difference in
        # μ/σ comes only from the DNA vs RNA backend tables and alphabet.
        μ_dna, σ_dna = BED.ρₑ(7.0, 0.0, Solute[DNA(1.0e-4, 1.0e-6, "ATGC")])
        μ_rna, σ_rna = BED.ρₑ(7.0, 0.0, Solute[RNA(1.0e-4, 1.0e-6, "AUGC")])
        @test !close_(μ_dna, μ_rna)
    end

    @testset "ρₑ: Protein + DNA + RNA + NonBiological mix sums correctly" begin
        solutes = Solute[
            Protein(1.0e-3, 1.0e-5, "GGGGCC"),
            DNA(1.0e-4, 1.0e-6, "ATGC"),
            RNA(1.0e-4, 1.0e-6, "AUGC"),
            NonBiological(0.5, 0.01, "urea"),
        ]
        μ, σ = BED.ρₑ(7.0, 0.0, solutes)
        μ_ref, σ_ref = ref_ρₑ(7.0, 0.0, solutes)
        @test close_(μ, μ_ref)
        @test close_(σ, σ_ref)
    end

    @testset "ρₑ: pH and σ_pH are forwarded to DNA/RNA solutes" begin
        for (pH, σ_pH) in ((3.0, 0.0), (7.0, 0.2), (9.0, 0.0))
            solutes = Solute[DNA(1.0e-4, 1.0e-6, "ATGC"), RNA(1.0e-4, 1.0e-6, "AUGC")]
            μ, σ = BED.ρₑ(pH, σ_pH, solutes)
            μ_ref, σ_ref = ref_ρₑ(pH, σ_pH, solutes)
            @test close_(μ, μ_ref)
            @test close_(σ, σ_ref)
        end
    end

    @testset "ρₑ: DNA/RNA solute validation errors propagate" begin
        good = NonBiological(0.5, 0.01, "urea")
        @test_throws DomainError BED.ρₑ(7.0, 0.0, Solute[good, DNA(0.1, -1.0, "ATGC")])
        @test_throws DomainError BED.ρₑ(7.0, 0.0, Solute[good, DNA(0.0, 0.01, "ATGC")])
        @test_throws ArgumentError BED.ρₑ(7.0, 0.0, Solute[good, DNA(0.1, 0.01, "")])
        @test_throws DomainError BED.ρₑ(7.0, 0.0, Solute[good, RNA(-0.1, 0.01, "AUGC")])
        @test_throws ArgumentError BED.ρₑ(7.0, 0.0, Solute[good, RNA(0.1, 0.01, "")])
    end

    # …Protein/NonBiological
    @testset "ρₑ_prior: DNA/RNA solutes moment-match the same as" begin
        solutes = Solute[DNA(1.0e-4, 1.0e-6, "ATGC"), RNA(1.0e-4, 1.0e-6, "AUGC")]
        μ, σ = BED.ρₑ(7.0, 0.0, solutes)
        prior = ρₑ_prior(7.0, 0.0, solutes)
        @test prior isa LogNormal{Float64}
        μ_ln_ref, σ_ln_ref = ref_lognormal(μ, σ)
        @test close_(prior.μ, μ_ln_ref)
        @test close_(prior.σ, σ_ln_ref)
    end

    # …of real protein + real DNA + real RNA is internally consistent
    @testset "ρₑ_prior: a realistic buffer" begin
        # Cross-checks Inference.ρₑ_prior, BulkElectronDensity.ρₑ and
        # BulkElectronDensity.ϕ° together on genuine biological sequences (see
        # test/fixtures/molecules/sequences.jl for provenance), rather than the
        # short synthetic stand-ins ("ATGC"/"AUGC"/"GGGGCC") used above to
        # isolate the DNA/RNA-vs-Protein code paths.
        solutes = Solute[
            Protein(1.0e-4, 1.0e-6, LYSOZYME),
            DNA(5.0e-5, 5.0e-7, PUC19_FRAGMENT),
            RNA(2.0e-5, 2.0e-7, TRNA_PHE),
            NonBiological(0.15, 0.001, "sodium chloride"),
        ]
        μ, σ = BED.ρₑ(7.4, 0.05, solutes)
        μ_ref, σ_ref = ref_ρₑ(7.4, 0.05, solutes)
        @test close_(μ, μ_ref)
        @test close_(σ, σ_ref)
        @test σ > 0.0

        prior = ρₑ_prior(7.4, 0.05, solutes)
        @test prior isa LogNormal{Float64}
        μ_ln_ref, σ_ln_ref = ref_lognormal(μ, σ)
        @test close_(prior.μ, μ_ln_ref)
        @test close_(prior.σ, σ_ln_ref)
        @test close_(mean(prior), μ)
        @test close_(sqrt(var(prior)), σ; atol = DEFAULT_ATOL)

        # sanity: a real macromolecule-laden buffer genuinely shifts ρₑ
        # away from pure water, same qualitative check as the
        # single-solute testsets above.
        ρw, _ = BED._ρₑ_w(DEFAULT_TEMPERATURE_C)
        @test !close_(μ, ρw)
    end

    #------------------------------------------------------------------
    #                 ρₑ -- pH / σ_pH / temperature forwarding
    #------------------------------------------------------------------

    @testset "ρₑ: pH and σ_pH are forwarded to ionizable Protein solutes" begin
        # 'D' (Asp, pKa 4.0) is ionizable; its ϕ° genuinely depends on pH and
        # σ_pH, so ρₑ must change when they change, and must agree with the
        # reference recomputation at each setting. A fresh sequence per query
        # sidesteps ϕ°'s sequence-only cache (see fresh_seq_dns above).
        for (pH, σ_pH) in ((3.0, 0.0), (4.0, 0.0), (4.0, 0.3), (9.0, 0.0))
            solutes = Solute[Protein(1.0e-3, 1.0e-5, fresh_seq_dns("D"))]
            μ, σ = BED.ρₑ(pH, σ_pH, solutes)
            μ_ref, σ_ref = ref_ρₑ(pH, σ_pH, solutes)
            @test close_(μ, μ_ref)
            @test close_(σ, σ_ref)
        end

        μ_lo, _ = BED.ρₑ(3.0, 0.0, Solute[Protein(1.0e-3, 1.0e-5, fresh_seq_dns("D"))])
        μ_hi, _ = BED.ρₑ(9.0, 0.0, Solute[Protein(1.0e-3, 1.0e-5, fresh_seq_dns("D"))])
        @test !close_(μ_lo, μ_hi)   # titration genuinely moves ρₑ
    end

    @testset "ρₑ: pH/σ_pH do not affect NonBiological-only solutions" begin
        solutes = Solute[NonBiological(0.3, 0.01, "urea")]
        a = BED.ρₑ(2.0, 0.0, solutes)
        b = BED.ρₑ(11.0, 5.0, solutes)
        @test a == b
    end

    @testset "ρₑ: temperature is forwarded to BulkElectronDensity._ρₑ_w" begin
        solutes = Solute[NonBiological(0.5, 0.01, "urea")]
        for t in (0.0, 25.0, 37.0, 100.0)
            μ, σ = BED.ρₑ(7.0, 0.0, solutes; t = t)
            μ_ref, σ_ref = ref_ρₑ(7.0, 0.0, solutes; t = t)
            @test close_(μ, μ_ref)
            @test close_(σ, σ_ref)
        end
    end

    #------------------------------------------------------------------
    #                 ρₑ -- validation errors propagate
    #------------------------------------------------------------------

    @testset "ρₑ: solute validation errors propagate through the aggregation loop" begin
        good = NonBiological(0.5, 0.01, "urea")

        @test_throws DomainError BED.ρₑ(
            7.0,
            0.0,
            Solute[good, NonBiological(0.1, -1.0, "urea")],
        )
        @test_throws DomainError BED.ρₑ(
            7.0,
            0.0,
            Solute[good, NonBiological(0.0, 0.01, "urea")],
        )
        @test_throws DomainError BED.ρₑ(
            7.0,
            0.0,
            Solute[good, NonBiological(-0.1, 0.01, "urea")],
        )
        @test_throws ArgumentError BED.ρₑ(
            7.0,
            0.0,
            Solute[good, NonBiological(0.1, 0.01, "")],
        )

        @test_throws DomainError BED.ρₑ(7.0, 0.0, Solute[good, Protein(0.1, -1.0, "A")])
        @test_throws DomainError BED.ρₑ(7.0, 0.0, Solute[good, Protein(0.0, 0.01, "A")])
        @test_throws DomainError BED.ρₑ(7.0, 0.0, Solute[good, Protein(-0.1, 0.01, "A")])
        @test_throws ArgumentError BED.ρₑ(7.0, 0.0, Solute[good, Protein(0.1, 0.01, "")])

        @test_throws ArgumentError BED.ρₑ(
            7.0,
            0.0,
            Solute[NonBiological(0.5, 0.01, "not-a-real-solute-name")],
        )
    end

    #------------------------------------------------------------------
    #                 ρₑ_prior -- moment-matched LogNormal
    #------------------------------------------------------------------

    @testset "ρₑ_prior: LogNormal is moment-matched to ρₑ's (μ, σ) exactly" begin
        cases = [
            Solute[NonBiological(0.5, 0.01, "urea")],
            Solute[Protein(1.0e-3, 1.0e-5, "GGGGAA")],
            Solute[NonBiological(0.5, 0.01, "urea"), Protein(1.0e-3, 1.0e-5, "GGGGBB")],
            Solute[Protein(2.0e-4, 5.0e-6, LYSOZYME), NonBiological(1.0, 0.05, "glycerol")],
        ]
        for solutes in cases
            μ, σ = BED.ρₑ(7.0, 0.0, solutes)
            prior = ρₑ_prior(7.0, 0.0, solutes)
            @test prior isa LogNormal{Float64}

            μ_ln_ref, σ_ln_ref = ref_lognormal(μ, σ)
            @test close_(prior.μ, μ_ln_ref)
            @test close_(prior.σ, σ_ln_ref)

            # the moment-matching identity: LogNormal(μ_ln, σ_ln) built this
            # way has mean == μ and std == σ exactly (up to float roundoff).
            @test close_(mean(prior), μ)
            @test close_(sqrt(var(prior)), σ; atol = DEFAULT_ATOL)
        end
    end

    @testset "ρₑ_prior: propagates pH/σ_pH/t like ρₑ does" begin
        # distinct fresh sequences so ϕ°'s sequence-keyed cache doesn't
        # replay one pH's result for the other (see fresh_seq_dns above).
        prior_lo = ρₑ_prior(3.0, 0.0, Solute[Protein(1.0e-3, 1.0e-5, fresh_seq_dns("D"))])
        prior_hi = ρₑ_prior(9.0, 0.0, Solute[Protein(1.0e-3, 1.0e-5, fresh_seq_dns("D"))])
        @test !close_(mean(prior_lo), mean(prior_hi))

        solutes = Solute[NonBiological(0.5, 0.01, "urea")]
        prior_37 = ρₑ_prior(7.0, 0.0, solutes; t = 37.0)
        μ37, _ = BED.ρₑ(7.0, 0.0, solutes; t = 37.0)
        @test close_(mean(prior_37), μ37)
    end

    @testset "ρₑ: 25 °C solute volumes get a σ widened linearly in |t − 25|" begin
        solutes = Solute[NonBiological(1.0, 0.0, "glycerol")]
        _, σ25 = BED.ρₑ(7.0, 0.0, solutes; t = PMV_REFERENCE_TEMPERATURE_C)
        _, σ15 = BED.ρₑ(7.0, 0.0, solutes; t = 15.0)
        _, σ35 = BED.ρₑ(7.0, 0.0, solutes; t = 35.0)
        _, σ05 = BED.ρₑ(7.0, 0.0, solutes; t = 5.0)
        @test σ15 > σ25 && σ35 > σ25 && σ05 > σ15
        μ15, _ = BED.ρₑ(7.0, 0.0, solutes; t = 15.0)
        μ15_ref, σ15_ref = ref_ρₑ(7.0, 0.0, solutes; t = 15.0)
        @test close_(μ15, μ15_ref) && close_(σ15, σ15_ref)
        # water itself is evaluated exactly at t, not at 25 °C
        @test close_(BED.ρₑ(7.0, 0.0, Solute[]; t = 10.0)[1], BED._ρₑ_w(10.0)[1])
    end

    @testset "ρₑ_prior: argument errors" begin
        # an empty solute list is pure water, not an error
        @test close_(
            mean(ρₑ_prior(7.0, 0.0, Solute[])),
            BED._ρₑ_w(DEFAULT_TEMPERATURE_C)[1];
            atol = DEFAULT_ATOL,
        )
        @test_throws DomainError ρₑ_prior(
            7.0,
            -0.1,
            Solute[NonBiological(0.5, 0.01, "urea")],
        )
        # σ_pH == 0 is allowed (boundary)
        @test ρₑ_prior(7.0, 0.0, Solute[NonBiological(0.5, 0.01, "urea")]) isa
              LogNormal{Float64}
    end

    @testset "ρₑ_prior: solute validation errors still propagate" begin
        @test_throws DomainError ρₑ_prior(
            7.0,
            0.0,
            Solute[NonBiological(0.0, 0.01, "urea")],
        )
        @test_throws ArgumentError ρₑ_prior(7.0, 0.0, Solute[Protein(0.1, 0.01, "")])
    end

end
