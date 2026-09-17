# SPDX-License-Identifier: LGPL-2.1-or-later

# End-to-end tests for src/Fitting/Priors/DensityOfSolvent.jl: bulk solution
# electron density (`_ρₑ`) and its `LogNormal` prior (`dns_prior`), exercised
# through `Interfaces.ρₑ_w`/`Interfaces.ϕ°` pipeline.

const FIT = ScatterNet.Fitting
using ScatterNet.Fitting: Solute, Protein, NonBiological, DNA, RNA, dns_prior
using ScatterNet.Constants: AVOGADRO
using Distributions: mean, var, LogNormal

include(joinpath(@__DIR__, "fixtures", "floatcompare.jl"))   # close_
include(joinpath(@__DIR__, "fixtures", "sequences.jl"))      # LYSOZYME, ...

"""
Independent re-derivation of the `_ρₑ`/`dns_prior` formula from the live
`Interfaces.ρₑ_w`/`Interfaces.ϕ°` calls:

    ρₑ = ρ_w(T) + Σ_j C_j · (N_A·Z_j/1e27 − ρ_w(T)·ϕ°_j/1e3)
    σ² = (1 − Σ_j C_j·ϕ°_j/1e3)² · σ_w²
        + Σ_j k_j² · σ_C_j²
        + Σ_j (C_j·ρ_w/1e3)² · σ_ϕ°_j²
"""
function ref_ρₑ(pH::Real, σ_pH::Real, solutes::Vector{Solute}; t::Real = 25.0)
    ρw, σw = ScatterNet.Interfaces.ρₑ_w(t)
    ρw_k = ρw * 1e-3

    disp = 0.0; Δμ = 0.0; var_conc = 0.0; var_vol = 0.0
    for s in solutes
        Z, ϕ, σϕ =
            s isa Protein       ? ScatterNet.Interfaces.ϕ°(pH, s.arg; σ_pH) :
            s isa DNA            ? ScatterNet.Interfaces.ϕ°(true, pH, s.arg; σ_pH) :
            s isa RNA            ? ScatterNet.Interfaces.ϕ°(false, pH, s.arg; σ_pH) :
            ScatterNet.Interfaces.ϕ°(s.arg)
        C, σC = s.molarity, s.molarity_uncertainty
        k = AVOGADRO * Z / 1e27 - ρw_k * ϕ

        disp     += C * ϕ / 1e3
        Δμ       += C * k
        var_conc += k^2 * σC^2
        var_vol  += (C * ρw_k)^2 * σϕ^2
    end

    μ = ρw + Δμ
    σ = sqrt((1.0 - disp)^2 * σw^2 + var_conc + var_vol)
    return μ, σ
end

"""
`LogNormal` params moment-matched to `(μ, σ)` exactly as `dns_prior` does,
independently of `dns_prior`'s own code.
"""
function ref_lognormal(μ::Real, σ::Real)
    σ_ln = sqrt(log(1 + (σ / μ)^2))
    μ_ln = log(μ) - σ_ln^2 / 2
    return μ_ln, σ_ln
end

# `Interfaces.ϕ°` caches a Protein solute's result off of its sequence alone
# (documented on `ϕ°`), so re-querying the same literal sequence at a
# different pH/σ_pH just replays the first call's cached answer. Every test
# below that needs to vary pH/σ_pH for an otherwise-identical sequence uses a
# fresh, never-before-seen sequence per query. Padded with a random run of
# 'X'/'*' (both documented no-ops) rather than a small sequential counter
# (test_pmv.jl's own `fresh_seq` helper) so the two files' paddings can't
# collide on the same cache key.
fresh_seq_dns(base::AbstractString) = base * String(rand(('X', '*'), 48))

@testset "DensityOfSolvent" begin

    #------------------------------------------------------------------
    #                 _ρₑ -- single-solute agreement
    #------------------------------------------------------------------

    @testset "_ρₑ: single NonBiological solute matches the reference formula" begin
        solutes = Solute[NonBiological(0.5, 0.01, "urea")]
        μ, σ = FIT._ρₑ(7.0, 0.0, solutes)
        μ_ref, σ_ref = ref_ρₑ(7.0, 0.0, solutes)
        @test close_(μ, μ_ref)
        @test close_(σ, σ_ref)
        # sanity: adding a solute genuinely shifts ρₑ away from pure water.
        ρw, _ = ScatterNet.Interfaces.ρₑ_w(25.0)
        @test !close_(μ, ρw; atol = 1e-9)
    end

    @testset "_ρₑ: single non-ionizable Protein solute matches the reference formula" begin
        solutes = Solute[Protein(1.0e-3, 1.0e-5, "GGGG")]
        μ, σ = FIT._ρₑ(7.0, 0.0, solutes)
        μ_ref, σ_ref = ref_ρₑ(7.0, 0.0, solutes)
        @test close_(μ, μ_ref)
        @test close_(σ, σ_ref)
    end

    @testset "_ρₑ: mixed Protein + NonBiological solutes sum correctly" begin
        solutes = Solute[
            NonBiological(0.5, 0.01, "urea"),
            Protein(1.0e-3, 1.0e-5, "GGGGXX"),
        ]
        μ, σ = FIT._ρₑ(7.0, 0.0, solutes)
        μ_ref, σ_ref = ref_ρₑ(7.0, 0.0, solutes)
        @test close_(μ, μ_ref)
        @test close_(σ, σ_ref)

        # additivity: the two-solute mean shift equals the sum of the
        # single-solute mean shifts (linear in concentration).
        ρw, _ = ScatterNet.Interfaces.ρₑ_w(25.0)
        μ_urea, _ = FIT._ρₑ(7.0, 0.0, Solute[NonBiological(0.5, 0.01, "urea")])
        μ_prot, _ = FIT._ρₑ(7.0, 0.0, Solute[Protein(1.0e-3, 1.0e-5, "GGGGXX")])
        @test close_(μ, ρw + (μ_urea - ρw) + (μ_prot - ρw); atol = 1e-9)
    end

    @testset "_ρₑ: multiple real Protein + a real small molecule" begin
        solutes = Solute[
            Protein(2.0e-4, 5.0e-6, LYSOZYME),
            Protein(1.0e-4, 2.0e-6, "GGGGZZ"),
            NonBiological(1.0, 0.05, "urea"),
            NonBiological(0.1, 0.001, "glycerol"),
        ]
        μ, σ = FIT._ρₑ(7.4, 0.05, solutes)
        μ_ref, σ_ref = ref_ρₑ(7.4, 0.05, solutes)
        @test close_(μ, μ_ref)
        @test close_(σ, σ_ref)
        @test σ > 0.0
    end

    #------------------------------------------------------------------
    #                 _ρₑ -- DNA / RNA solutes
    #------------------------------------------------------------------

    @testset "_ρₑ: single DNA solute matches the reference formula" begin
        solutes = Solute[DNA(1.0e-4, 1.0e-6, "ATGC")]
        μ, σ = FIT._ρₑ(7.0, 0.0, solutes)
        μ_ref, σ_ref = ref_ρₑ(7.0, 0.0, solutes)
        @test close_(μ, μ_ref)
        @test close_(σ, σ_ref)
        ρw, _ = ScatterNet.Interfaces.ρₑ_w(25.0)
        @test !close_(μ, ρw; atol = 1e-9)
    end

    @testset "_ρₑ: single RNA solute matches the reference formula" begin
        solutes = Solute[RNA(1.0e-4, 1.0e-6, "AUGC")]
        μ, σ = FIT._ρₑ(7.0, 0.0, solutes)
        μ_ref, σ_ref = ref_ρₑ(7.0, 0.0, solutes)
        @test close_(μ, μ_ref)
        @test close_(σ, σ_ref)
    end

    @testset "_ρₑ: DNA and RNA are distinct despite one-letter-code overlap (A/G/C shared, T vs U)" begin
        # same molarity/uncertainty, same-length sequence; any difference in
        # μ/σ comes only from the DNA vs RNA backend tables and alphabet.
        μ_dna, σ_dna = FIT._ρₑ(7.0, 0.0, Solute[DNA(1.0e-4, 1.0e-6, "ATGC")])
        μ_rna, σ_rna = FIT._ρₑ(7.0, 0.0, Solute[RNA(1.0e-4, 1.0e-6, "AUGC")])
        @test !close_(μ_dna, μ_rna; atol = 1e-9)
    end

    @testset "_ρₑ: Protein + DNA + RNA + NonBiological mix sums correctly" begin
        solutes = Solute[
            Protein(1.0e-3, 1.0e-5, "GGGGCC"),
            DNA(1.0e-4, 1.0e-6, "ATGC"),
            RNA(1.0e-4, 1.0e-6, "AUGC"),
            NonBiological(0.5, 0.01, "urea"),
        ]
        μ, σ = FIT._ρₑ(7.0, 0.0, solutes)
        μ_ref, σ_ref = ref_ρₑ(7.0, 0.0, solutes)
        @test close_(μ, μ_ref)
        @test close_(σ, σ_ref)
    end

    @testset "_ρₑ: pH and σ_pH are forwarded to DNA/RNA solutes" begin
        for (pH, σ_pH) in ((3.0, 0.0), (7.0, 0.2), (9.0, 0.0))
            solutes = Solute[DNA(1.0e-4, 1.0e-6, "ATGC"), RNA(1.0e-4, 1.0e-6, "AUGC")]
            μ, σ = FIT._ρₑ(pH, σ_pH, solutes)
            μ_ref, σ_ref = ref_ρₑ(pH, σ_pH, solutes)
            @test close_(μ, μ_ref)
            @test close_(σ, σ_ref)
        end
    end

    @testset "_ρₑ: DNA/RNA solute validation errors propagate" begin
        good = NonBiological(0.5, 0.01, "urea")
        @test_throws DomainError FIT._ρₑ(7.0, 0.0, Solute[good, DNA(0.1, -1.0, "ATGC")])
        @test_throws DomainError FIT._ρₑ(7.0, 0.0, Solute[good, DNA(0.0, 0.01, "ATGC")])
        @test_throws ArgumentError FIT._ρₑ(7.0, 0.0, Solute[good, DNA(0.1, 0.01, "")])
        @test_throws DomainError FIT._ρₑ(7.0, 0.0, Solute[good, RNA(-0.1, 0.01, "AUGC")])
        @test_throws ArgumentError FIT._ρₑ(7.0, 0.0, Solute[good, RNA(0.1, 0.01, "")])
    end

    @testset "dns_prior: DNA/RNA solutes moment-match the same as Protein/NonBiological" begin
        solutes = Solute[DNA(1.0e-4, 1.0e-6, "ATGC"), RNA(1.0e-4, 1.0e-6, "AUGC")]
        μ, σ = FIT._ρₑ(7.0, 0.0, solutes)
        prior = dns_prior(7.0, 0.0, solutes)
        @test prior isa LogNormal{Float64}
        μ_ln_ref, σ_ln_ref = ref_lognormal(μ, σ)
        @test close_(prior.μ, μ_ln_ref)
        @test close_(prior.σ, σ_ln_ref)
    end

    @testset "dns_prior: a realistic buffer of real protein + real DNA + real RNA is internally consistent" begin
        # Cross-checks Priors.dns_prior, DensityOfSolvent._ρₑ and
        # Interfaces.ϕ° together on genuine biological sequences (see
        # test/fixtures/sequences.jl for provenance), rather than the
        # short synthetic stand-ins ("ATGC"/"AUGC"/"GGGGCC") used above to
        # isolate the DNA/RNA-vs-Protein code paths.
        solutes = Solute[
            Protein(1.0e-4, 1.0e-6, LYSOZYME),
            DNA(5.0e-5, 5.0e-7, PUC19_FRAGMENT),
            RNA(2.0e-5, 2.0e-7, TRNA_PHE),
            NonBiological(0.15, 0.001, "sodium chloride"),
        ]
        μ, σ = FIT._ρₑ(7.4, 0.05, solutes)
        μ_ref, σ_ref = ref_ρₑ(7.4, 0.05, solutes)
        @test close_(μ, μ_ref)
        @test close_(σ, σ_ref)
        @test σ > 0.0

        prior = dns_prior(7.4, 0.05, solutes)
        @test prior isa LogNormal{Float64}
        μ_ln_ref, σ_ln_ref = ref_lognormal(μ, σ)
        @test close_(prior.μ, μ_ln_ref)
        @test close_(prior.σ, σ_ln_ref)
        @test close_(mean(prior), μ; atol = 1e-9)
        @test close_(sqrt(var(prior)), σ; atol = 1e-9)

        # sanity: a real macromolecule-laden buffer genuinely shifts ρₑ
        # away from pure water, same qualitative check as the
        # single-solute testsets above.
        ρw, _ = ScatterNet.Interfaces.ρₑ_w(25.0)
        @test !close_(μ, ρw; atol = 1e-9)
    end

    #------------------------------------------------------------------
    #                 _ρₑ -- pH / σ_pH / temperature forwarding
    #------------------------------------------------------------------

    @testset "_ρₑ: pH and σ_pH are forwarded to ionizable Protein solutes" begin
        # 'D' (Asp, pKa 4.0) is ionizable; its ϕ° genuinely depends on pH and
        # σ_pH, so _ρₑ must change when they change, and must agree with the
        # reference recomputation at each setting. A fresh sequence per query
        # sidesteps ϕ°'s sequence-only cache (see fresh_seq_dns above).
        for (pH, σ_pH) in ((3.0, 0.0), (4.0, 0.0), (4.0, 0.3), (9.0, 0.0))
            solutes = Solute[Protein(1.0e-3, 1.0e-5, fresh_seq_dns("D"))]
            μ, σ = FIT._ρₑ(pH, σ_pH, solutes)
            μ_ref, σ_ref = ref_ρₑ(pH, σ_pH, solutes)
            @test close_(μ, μ_ref)
            @test close_(σ, σ_ref)
        end

        μ_lo, _ = FIT._ρₑ(3.0, 0.0, Solute[Protein(1.0e-3, 1.0e-5, fresh_seq_dns("D"))])
        μ_hi, _ = FIT._ρₑ(9.0, 0.0, Solute[Protein(1.0e-3, 1.0e-5, fresh_seq_dns("D"))])
        @test !close_(μ_lo, μ_hi; atol = 1e-9)   # titration genuinely moves ρₑ
    end

    @testset "_ρₑ: pH/σ_pH do not affect NonBiological-only solutions" begin
        solutes = Solute[NonBiological(0.3, 0.01, "urea")]
        a = FIT._ρₑ(2.0, 0.0, solutes)
        b = FIT._ρₑ(11.0, 5.0, solutes)
        @test a == b
    end

    @testset "_ρₑ: temperature is forwarded to Interfaces.ρₑ_w" begin
        solutes = Solute[NonBiological(0.5, 0.01, "urea")]
        for t in (0.0, 25.0, 37.0, 100.0)
            μ, σ = FIT._ρₑ(7.0, 0.0, solutes; t = t)
            μ_ref, σ_ref = ref_ρₑ(7.0, 0.0, solutes; t = t)
            @test close_(μ, μ_ref)
            @test close_(σ, σ_ref)
        end
    end

    #------------------------------------------------------------------
    #                 _ρₑ -- validation errors propagate
    #------------------------------------------------------------------

    @testset "_ρₑ: solute validation errors propagate through the aggregation loop" begin
        good = NonBiological(0.5, 0.01, "urea")

        @test_throws DomainError FIT._ρₑ(7.0, 0.0, Solute[good, NonBiological(0.1, -1.0, "urea")])
        @test_throws DomainError FIT._ρₑ(7.0, 0.0, Solute[good, NonBiological(0.0, 0.01, "urea")])
        @test_throws DomainError FIT._ρₑ(7.0, 0.0, Solute[good, NonBiological(-0.1, 0.01, "urea")])
        @test_throws ArgumentError FIT._ρₑ(7.0, 0.0, Solute[good, NonBiological(0.1, 0.01, "")])

        @test_throws DomainError FIT._ρₑ(7.0, 0.0, Solute[good, Protein(0.1, -1.0, "A")])
        @test_throws DomainError FIT._ρₑ(7.0, 0.0, Solute[good, Protein(0.0, 0.01, "A")])
        @test_throws DomainError FIT._ρₑ(7.0, 0.0, Solute[good, Protein(-0.1, 0.01, "A")])
        @test_throws ArgumentError FIT._ρₑ(7.0, 0.0, Solute[good, Protein(0.1, 0.01, "")])

        @test_throws ArgumentError FIT._ρₑ(7.0, 0.0, Solute[NonBiological(0.5, 0.01, "not-a-real-solute-name")])
    end

    #------------------------------------------------------------------
    #                 dns_prior -- moment-matched LogNormal
    #------------------------------------------------------------------

    @testset "dns_prior: LogNormal is moment-matched to _ρₑ's (μ, σ) exactly" begin
        cases = [
            Solute[NonBiological(0.5, 0.01, "urea")],
            Solute[Protein(1.0e-3, 1.0e-5, "GGGGAA")],
            Solute[NonBiological(0.5, 0.01, "urea"), Protein(1.0e-3, 1.0e-5, "GGGGBB")],
            Solute[Protein(2.0e-4, 5.0e-6, LYSOZYME), NonBiological(1.0, 0.05, "glycerol")],
        ]
        for solutes in cases
            μ, σ = FIT._ρₑ(7.0, 0.0, solutes)
            prior = dns_prior(7.0, 0.0, solutes)
            @test prior isa LogNormal{Float64}

            μ_ln_ref, σ_ln_ref = ref_lognormal(μ, σ)
            @test close_(prior.μ, μ_ln_ref)
            @test close_(prior.σ, σ_ln_ref)

            # the moment-matching identity: LogNormal(μ_ln, σ_ln) built this
            # way has mean == μ and std == σ exactly (up to float roundoff).
            @test close_(mean(prior), μ; atol = 1e-9)
            @test close_(sqrt(var(prior)), σ; atol = 1e-9)
        end
    end

    @testset "dns_prior: propagates pH/σ_pH/t like _ρₑ does" begin
        # distinct fresh sequences so ϕ°'s sequence-keyed cache doesn't
        # replay one pH's result for the other (see fresh_seq_dns above).
        prior_lo = dns_prior(3.0, 0.0, Solute[Protein(1.0e-3, 1.0e-5, fresh_seq_dns("D"))])
        prior_hi = dns_prior(9.0, 0.0, Solute[Protein(1.0e-3, 1.0e-5, fresh_seq_dns("D"))])
        @test !close_(mean(prior_lo), mean(prior_hi); atol = 1e-9)

        solutes = Solute[NonBiological(0.5, 0.01, "urea")]
        prior_37 = dns_prior(7.0, 0.0, solutes; t = 37.0)
        μ37, _ = FIT._ρₑ(7.0, 0.0, solutes; t = 37.0)
        @test close_(mean(prior_37), μ37; atol = 1e-9)
    end

    @testset "dns_prior: argument errors" begin
        @test_throws ArgumentError dns_prior(7.0, 0.0, Solute[])
        @test_throws DomainError dns_prior(7.0, -0.1, Solute[NonBiological(0.5, 0.01, "urea")])
        # σ_pH == 0 is allowed (boundary)
        @test dns_prior(7.0, 0.0, Solute[NonBiological(0.5, 0.01, "urea")]) isa LogNormal{Float64}
    end

    @testset "dns_prior: solute validation errors still propagate" begin
        @test_throws DomainError dns_prior(7.0, 0.0, Solute[NonBiological(0.0, 0.01, "urea")])
        @test_throws ArgumentError dns_prior(7.0, 0.0, Solute[Protein(0.1, 0.01, "")])
    end

end
