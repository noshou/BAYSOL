# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/BulkElectronDensity/ (CalcDensity.jl, Titration.jl, Protein/,
# NonBiological/, Nucleotide/, Polymers/): bulk water electron density (Kell-equation
# density -> e/A^-3, `_ρₑ_w`) and protein/non-protein partial molar volumes at infinite
# dilution (`ϕ°`), including the pH-dependent titration formula, ambiguity-code (B/J/Z)
# averaging, the uncertainty backfill for solutes with no reported error, and the
# `BulkElectronDensity` internal dispatch surface (`_common2target`, backend markers).
#
# Data provenance for every hardcoded number below: `_ρₑ_w` reference values
# are a re-derivation of the published Kell (1975) density equation plus the same
# ideal mass-density -> electron-density conversion BulkElectronDensity uses. Protein
# values are hand-derived closed forms from `Protein/protein.json`/
# `Protein/ionization.json` (Lee et al. 2008, DOI 10.1016/j.bpc.2008.02.009) as they
# stood when this file was written.

include(joinpath(@__DIR__, "..", "testsetup.jl"))

const IFACE = BAYSOL.BulkElectronDensity
using BAYSOL.PhysicalConstants:
    AVOGADRO, WATER_ELECTRONS, ANGSTROM3_PER_LITER, CM3_PER_LITER

"Fully-qualified handle onto the submodule, for the private caches/tables below."
const PMVMOD = BAYSOL.BulkElectronDensity

include(joinpath(@__DIR__, "..", "..", "utils", "floatcompare.jl"))   # close_
# LYSOZYME, ...
include(joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "sequences.jl"))

# fresh_seq(base): a sequence that computes identically to `base` (padded with inert 'X'
# no-ops) but is guaranteed never to have been queried before anywhere in this file. (The
# memo is keyed by (sequence, pH, σ_pH), so this is no longer needed for correctness; it
# keeps a test from depending on an earlier test having warmed the entry.)
let _fresh_n = Ref(0)
    global fresh_seq(base::AbstractString) = (_fresh_n[] += 1; base * "X"^_fresh_n[])
end

@testset "BulkElectronDensity" begin

    #------------------------------------------------------------------
    #                    _ρₑ_w -- bulk water electron density
    #------------------------------------------------------------------

    @testset "_ρₑ_w: Kell-equation electron density at reference temperatures" begin
        # (t degC, rho_e expected e.A^-3, uncertainty expected e.A^-3)
        # rho_e(25) ~ 0.3333 e/A^-3 is the textbook bulk-water constant
        ref = [
            (0.0, 0.3342261867461997, 6.685596639472697e-6),
            (3.984, 0.33427047092945, 6.685596639472695e-6),   # density maximum, see below
            (4.0, 0.3342704701746428, 6.685596639472696e-6),
            (20.0, 0.333679509587399, 6.685596639472695e-6),
            (25.0, 0.3332920001104711, 6.685596639472696e-6),
            (37.0, 0.3320497365290211, 6.685596639472695e-6),   # body temperature
            (100.0, 0.3203616422488662, 6.685596639472695e-6),
            (150.0, 0.30647748126647417, 6.6855966394726945e-6),
        ]
        for (t, ρe_expected, u_expected) in ref
            ρe, u = IFACE._ρₑ_w(t)
            @test close_(ρe, ρe_expected; atol = 1e-3 * DEFAULT_ATOL)
            @test close_(u, u_expected; atol = 1e-6 * DEFAULT_ATOL)
        end
    end

    @testset "_ρₑ_w: relative uncertainty is a temperature-independent constant" begin
        # unc(t) = rho_e(t) * 0.02/rho(t), and rho_e(t) is proportional
        # to rho(t) (same conversion factor at every t), so the ratio
        # rho_e/rho is a fixed constant and unc(t) must come out identical at
        # every temperature.
        u_ref = IFACE._ρₑ_w(0.0)[2]
        for t in (1.0, 22.5, 49.9, 88.0, 133.3, 150.0)
            @test close_(IFACE._ρₑ_w(t)[2], u_ref; atol = 1e-10 * DEFAULT_ATOL)
        end
    end

    @testset "_ρₑ_w: density maximum near 3.98 C" begin
        ρe_0  = IFACE._ρₑ_w(0.0)[1]
        ρe_4  = IFACE._ρₑ_w(3.984)[1]
        ρe_10 = IFACE._ρₑ_w(10.0)[1]
        @test ρe_4 > ρe_0
        @test ρe_4 > ρe_10
        # monotonically decreasing above the maximum, matching the real
        # density curve out to the boiling point and beyond (the equation is
        # only nominally valid to 150 C at 1 atm, but is still smooth there).
        prev = ρe_4
        for t in 5.0:5.0:150.0
            cur = IFACE._ρₑ_w(t)[1]
            @test cur < prev
            prev = cur
        end
    end

    @testset "_ρₑ_w: domain is [0, 150] C inclusive, exclusive outside" begin
        @test IFACE._ρₑ_w(0.0)[1] isa Float64      # lower boundary allowed
        @test IFACE._ρₑ_w(150.0)[1] isa Float64    # upper boundary allowed
        @test_throws DomainError IFACE._ρₑ_w(-1.0e-9)
        @test_throws DomainError IFACE._ρₑ_w(150.0 + 1.0e-9)
        @test_throws DomainError IFACE._ρₑ_w(-50.0)
        @test_throws DomainError IFACE._ρₑ_w(1000.0)
    end

    @testset "_ρₑ_w: memoization returns the exact cached value" begin
        a = IFACE._ρₑ_w(63.219)
        b = IFACE._ρₑ_w(63.219)
        @test a === b
        @test haskey(PMVMOD._ρₑ_w_cache, round(Int64, 63.219 * 1000))
    end

    @testset "_ρₑ_w: the cache key is quantized to 1e-3 C" begin
        # key = round(Int64, t*1000), so two temperatures within 0.0005 C of
        # each other collide on the same cache slot. Whichever is queried
        # first "wins".
        t_a, t_b = 111.111, 111.1114              # both round(*1000) to 111111
        @test round(Int64, t_a * 1000) == round(Int64, t_b * 1000)
        first  = IFACE._ρₑ_w(t_a)
        second = IFACE._ρₑ_w(t_b)                  # served from t_a's cache slot
        @test second === first
        # t_b's *true* value
        @test !close_(second[1], 0.3175976147955338; atol = 1e-3 * DEFAULT_ATOL)
        # t_a's value, reused
        @test close_(second[1], 0.317597717642839; atol = 1e-3 * DEFAULT_ATOL)
    end

    #------------------------------------------------------------------
    #                    ϕ° -- protein partial molar volume
    #------------------------------------------------------------------

    @testset "ϕ°(pH, seq): non-ionizable single/short sequences are pH-independent" begin
        # G contributes nothing beyond the shared backbone (its own V0/e are 0
        # by Lee et al.'s glycine-relative convention); A is a simple
        # non-ionizable side chain. Every residue adds one backbone unit
        # (37.4 cm3/mol, 30 e); the chain adds one water's worth of electrons
        # (10 e) exactly once, regardless of length.
        for pH in (0.0, 7.0, 14.0)
            @test IFACE.ϕ°(pH, "GGGG") == (130, 149.6, 0.2)
            @test IFACE.ϕ°(pH, "A") == (48, 54.2, sqrt(0.1))
        end
    end

    @testset "ϕ°(pH, seq): titration sigmoid at pH == pKa is an exact midpoint" begin
        # frac = 1/(1 + 10^0) = 0.5 exactly (10.0^0.0 == 1.0 is exact in
        # double precision), so this is a clean closed-form check.
        # D: acidic, pKa=4.0, V0=31.7, dV=12.1, u0=0.1, du=0.4
        e, v, u = IFACE.ϕ°(4.0, fresh_seq("D"))
        @test e == 70          # backbone(30) + D(30) + formation-water(10), pH-independent
        @test close_(v, 37.4 + (31.7 - 12.1/2))
        @test close_(u, sqrt(0.1^2 + (0.1^2 + (0.4/2)^2)))
        # K: basic, pKa=10.6, V0=70.1, dV=-5.9, u0=0.4, du=0.5
        e2, v2, u2 = IFACE.ϕ°(10.6, fresh_seq("K"))
        @test e2 == 80          # backbone(30) + K(40) + formation-water(10)
        @test close_(v2, 37.4 + (70.1 + (-5.9) * 0.5))
        @test close_(u2, sqrt(0.1^2 + (0.4^2 + (0.5 * 0.5)^2)))
    end

    # …method
    @testset "ϕ°(pH, seq; σ_pH): pH-measurement uncertainty propagates via the delta" begin
        # dpmv/dpH = dV*ln(10)*frac*(1-frac); at pH == pKa (frac = 0.5) this
        # is at its maximum magnitude, so sigma_pH's contribution
        # ((dpmv/dpH * sigma_pH)^2, added in quadrature) is largest there.
        v_expected = 37.4 + (31.7 - 12.1 * 0.5)
        for (σ, u_expected) in [(0.0, 0.24494897427831783),
            (0.05, 0.42578069882627495),
            (0.2, 1.414435313433547),
            (0.5, 3.4912634316675533)]
            e, v, u = IFACE.ϕ°(4.0, fresh_seq("D"); σ_pH = σ)
            @test e == 70          # backbone(30) + D(30) + formation-water(10)
            @test close_(v, v_expected)
            @test close_(u, u_expected)
        end
    end

    @testset "ϕ°(pH, seq; σ_pH): non-ionizable residues are agnostic to σ_pH" begin
        # sigma_pH only ever reaches `_titrated`'s delta-method term; the
        # non-ionizable branch of `_residue_var` never sees it at all.
        baseline = IFACE.ϕ°(7.0, "GAVLIPFWMCYSTNQ")
        # padded: fresh cache slot
        loud = IFACE.ϕ°(7.0, "GAVLIPFWMCYSTNQX"; σ_pH = 1.0e6)
        @test loud[1] == baseline[1]                    # X adds no electrons either
        @test close_(loud[2], baseline[2])
        @test close_(loud[3], baseline[3])
    end

    @testset "ϕ°(pH, seq; σ_pH): saturates away from the sigmoid's steep region" begin
        # Far from pKa, frac*(1-frac) -> 0, so dpmv/dpH -> 0 and even a huge
        # sigma_pH contributes essentially nothing. pH uncertainty only
        # matters when the residue is genuinely near its titration point.
        pKa   = 4.0
        quiet = IFACE.ϕ°(pKa - 30.0, fresh_seq("D"); σ_pH = 5.0)
        hush  = IFACE.ϕ°(pKa - 30.0, fresh_seq("D"); σ_pH = 0.0)
        @test close_(quiet[2], hush[2]; atol = 1e3 * DEFAULT_ATOL)
        @test close_(quiet[3], hush[3]; atol = 1e3 * DEFAULT_ATOL)
    end

    # …ionizable half
    @testset "ϕ°(pH, seq; σ_pH): wildcard averaging applies σ_pH only to the" begin
        # B = Asp/Asn at Asp's own pKa (4.0): Asn contributes no pH-derivative
        # term at all, so sigma_pH's effect is exactly the D-branch's
        # contribution above, divided by 4 by the wildcard-averaging rule.
        v_expected = 37.4 + ((31.7 - 12.1 * 0.5) + 34.0) / 2
        e, v, u = IFACE.ϕ°(4.0, "B"; σ_pH = 0.2)
        # backbone(30) + round((30+30)/2) + formation-water(10)
        @test e == 70
        @test close_(v, v_expected)
        @test close_(u, 0.7194837134862498)
    end

    @testset "ϕ°(pH, seq): every ionizable residue saturates correctly at extreme pH" begin
        # Taking frac's limits at pH -> pKa-30 and pKa+30 on either branch reduces to:
        #   v(low pH) - v(high pH) == dV
        # so the correct direction is pulled from the live data rather than
        # assumed per acidic/basic group.
        for code in ('D', 'E', 'H', 'K', 'R', 'U')
            res = string(code)
            (pKa, ionized_key), _ = PMVMOD._protein_ionization[res]
            dv = PMVMOD._Protein[ionized_key][2]
            e_lo, v_lo, _ = IFACE.ϕ°(pKa - 30.0, fresh_seq(res))
            e_hi, v_hi, _ = IFACE.ϕ°(pKa + 30.0, fresh_seq(res))
            @test e_lo == e_hi          # electron count is pH-independent everywhere
            @test close_(v_lo - v_hi, dv; atol = 1e3 * DEFAULT_ATOL)
        end
    end

    @testset "ϕ°(pH, seq): extreme (non-physical) pH does not overflow or NaN" begin
        # 10.0^x is well-behaved out to +-300ish before Float64 overflows;
        # Julia's `^` saturates to Inf/0.0 rather than throwing, so pH values
        # far outside [0,14] should still saturate the sigmoid cleanly.
        e_lo, v_lo, u_lo = IFACE.ϕ°(-1.0e6, fresh_seq("D"))
        @test e_lo == 70
        @test close_(v_lo, 37.4 + 31.7)                       # fully protonated: frac -> 0
        @test close_(u_lo, sqrt(0.1^2 + 0.1^2))
        e_hi, v_hi, u_hi = IFACE.ϕ°(1.0e6, fresh_seq("D"))
        @test e_hi == 70
        # fully deprotonated: frac -> 1
        @test close_(v_hi, 37.4 + (31.7 - 12.1))
        @test close_(u_hi, sqrt(0.1^2 + (0.1^2 + 0.4^2)))
        @test all(isfinite, (v_lo, u_lo, v_hi, u_hi))
    end

    @testset "ϕ°(pH, seq): ambiguity codes B/J/Z average their two residues, at scale" begin
        # J = Leu/Ile, both non-ionizable -> pH-independent closed form.
        z, v, u = IFACE.ϕ°(7.0, "J"^1000)
        @test z == 62010
        @test close_(v, 102000.0; atol = 1e3 * DEFAULT_ATOL)
        @test close_(u, 4.743416490252559; atol = 1e3 * DEFAULT_ATOL)

        # B = Asp/Asn, Asp ionizable -> evaluated at Asp's own pKa (4.0) for
        # an exact 0.5 sigmoid midpoint.
        zb, vb, ub = IFACE.ϕ°(4.0, "B"^1500)
        @test zb == 90010
        @test close_(vb, 100837.49999999524; atol = 1e5 * DEFAULT_ATOL)
        @test close_(ub, 6.982120021884522; atol = 1e3 * DEFAULT_ATOL)

        # Z = Glu/Gln, Glu ionizable -> evaluated at Glu's own pKa (4.4).
        zz, vz, uz = IFACE.ϕ°(4.4, "Z"^800)
        @test zz == 54410
        @test close_(vz, 66960.00000000169; atol = 1e3 * DEFAULT_ATOL)
        @test close_(uz, 10.770329614269151; atol = 1e3 * DEFAULT_ATOL)
    end

    @testset "ϕ°(pH, seq): 'X'/'*' are no-ops" begin
        # Neither contributes a backbone unit, an electron, nor a volume. An
        # all-placeholder "sequence" formed no peptide bonds at all so the
        # formation-water electron count is only added when at least one real
        # residue was actually present.
        @test IFACE.ϕ°(7.0, "XXXX") == (0, 0.0, 0.0)
        @test IFACE.ϕ°(7.0, "*"^37) == (0, 0.0, 0.0)
        padded = IFACE.ϕ°(7.0, "X"^10 * "A" * "*"^10)
        bare   = IFACE.ϕ°(7.0, "A")
        @test padded == bare
    end

    @testset "ϕ°(pH, seq): very long non-ionizable chains (closed form, N=5000)" begin
        # All-glycine: every term is 0 except the shared backbone, so the
        # totals are exact linear closed forms.
        N = 5000
        z, v, u = IFACE.ϕ°(7.0, "G"^N)
        @test z == 30 * N + 10
        @test close_(v, 37.4 * N; atol = 1e5 * DEFAULT_ATOL)
        @test close_(u, sqrt(N * 0.1^2))
    end

    # …N=3000)
    @testset "ϕ°(pH, seq): very long ionizable chain at its own pKa (closed form" begin
        N = 3000
        z, v, u = IFACE.ϕ°(4.0, "D"^N)     # pH == D's pKa: exact 0.5 sigmoid
        @test z == 60 * N + 10
        per_v = 37.4 + (31.7 - 12.1 * 0.5)
        per_sqr_u = 0.1^2 + (0.1^2 + (0.4 * 0.5)^2)
        @test close_(v, per_v * N; atol = 1e5 * DEFAULT_ATOL)
        @test close_(u, sqrt(per_sqr_u * N); atol = 1e3 * DEFAULT_ATOL)
    end

    @testset "ϕ°(pH, seq): real protein (hen egg-white lysozyme, 129 aa)" begin
        @test length(LYSOZYME) == 129
        # (pH, electron count, V0 cm3/mol, uncertainty cm3/mol)
        ref = [
            (2.0, 7628, 10424.367875646007, 3.019952617978304),
            (7.4, 7628, 10318.375679646211, 3.247557761154545),
            (11.0, 7628, 10340.21595229236, 3.0275892082170173),
        ]
        for (pH, e_expected, v_expected, u_expected) in ref
            # fresh_seq: ϕ° caches by sequence only, and this loop needs a
            # different computation at each of the 3 pH values.
            e, v, u = IFACE.ϕ°(pH, fresh_seq(LYSOZYME))
            @test e == e_expected
            @test close_(v, v_expected; atol = 1e3 * DEFAULT_ATOL)
            @test close_(u, u_expected; atol = 1e3 * DEFAULT_ATOL)
        end
        # Textbook globular-protein partial specific volume is ~0.70-0.75
        # cm3/g (see e.g. Svergun/Koch SAXS reviews); lysozyme's mature-chain
        # average MW is ~14313 Da. phi()/MW landing in that band is an
        # independent, literature-anchored sanity check.
        _, v74, _ = IFACE.ϕ°(7.4, LYSOZYME)
        @test 0.60 < v74 / 14313.0 < 0.85
    end

    @testset "ϕ°(pH, seq): repeating a real protein k times scales additively" begin
        # phi and the summed variance scale exactly linearly in the residue
        # count; only the electron total has the one-time +10 offset.
        z1, v1, u1 = IFACE.ϕ°(7.4, LYSOZYME)
        k = 50
        zk, vk, uk = IFACE.ϕ°(7.4, LYSOZYME^k)
        @test zk == k * (z1 - 10) + 10
        @test close_(vk, k * v1; atol = 1e6 * DEFAULT_ATOL)
        @test close_(uk, sqrt(k) * u1; atol = 1e3 * DEFAULT_ATOL)
    end

    @testset "ϕ°(pH, seq): argument errors" begin
        @test_throws ArgumentError IFACE.ϕ°(7.0, "")
        @test_throws ArgumentError IFACE.ϕ°(7.0, "Z9")       # '9' is not a residue code
        # lowercase: codes are uppercase-only
        @test_throws ArgumentError IFACE.ϕ°(7.0, "a")
        @test_throws ArgumentError IFACE.ϕ°(7.0, "AAaAA")    # invalid char mid-sequence
        # bare space is not a residue code
        @test_throws ArgumentError IFACE.ϕ°(7.0, "B J")
    end

    @testset "ϕ°(pH, seq): memoized per (sequence, pH, σ_pH)" begin
        seq = "DDDD"
        @test !haskey(PMVMOD._ϕ°_p_cache, (seq, 1.0, 0.0))
        low_pH_result = IFACE.ϕ°(1.0, seq)   # nearly fully protonated
        @test haskey(PMVMOD._ϕ°_p_cache, (seq, 1.0, 0.0))
        # same arguments: the memoized answer
        @test IFACE.ϕ°(1.0, seq) == low_pH_result
        # nearly fully deprotonated: its own entry, not the pH=1 answer
        high_pH_result = IFACE.ϕ°(13.0, seq)
        @test high_pH_result != low_pH_result
        @test close_(low_pH_result[2], 276.35164835164835; atol = 1e3 * DEFAULT_ATOL)
        @test close_(high_pH_result[2], 228.0000000484; atol = 1e6 * DEFAULT_ATOL)
        # σ_pH is part of the key too: it changes only the uncertainty, so the
        # value is shared but the entries (and uncertainties) are separate
        with_σ = IFACE.ϕ°(7.0, seq; σ_pH = 0.5)
        without_σ = IFACE.ϕ°(7.0, seq)
        @test with_σ[2] == without_σ[2]
        @test with_σ[3] > without_σ[3]
    end

    @testset "ϕ°(pH, seq): non-String AbstractString inputs (e.g. SubString) work" begin
        padded = "**AAAA**"
        view = SubString(padded, 3, 6)     # == "AAAA"
        @test view isa SubString{String}
        @test IFACE.ϕ°(7.0, view) == IFACE.ϕ°(7.0, "AAAA")
    end

    #------------------------------------------------------------------
    #                 ϕ° -- non-protein solute partial molar volume
    #------------------------------------------------------------------

    #------------------------------------------------------------------
    #                 Polymer solute (Polymers/)
    #------------------------------------------------------------------

    @testset "Polymer: PEG, PPG, Pluronic, glucan, cyclodextrin, Triton and Brij" begin
        P = IFACE._polymer_ϕ°
        # Ayranci & Sahin 2008 (10.1016/j.jct.2008.04.007), measured at 25 °C, nominal Mn
        for (name, Mn, v) in (("PEG 200", 200, 171.9), ("PEG-400", 400, 339.0),
            ("poly(ethylene glycol) 1000", 1000, 838.1), ("PEG3350", 3350, 2789.0),
            ("PEG 10000", 10000, 8381.0))
            Z, V, σ = P(name)
            @test abs(V - v) < 2σ
            @test Z == round(Int, 24 * (Mn - 18.015268) / 44.0526 + 10)
        end
        # the measured di- to pentaethylene glycols are covered by the same line
        for (n, v) in ((2, 92.2), (3, 129.3), (4, 166.3), (5, 203.85))
            @test abs(P("PEG n=$n")[2] - v) < 2P("PEG n=$n")[3]
        end
        @test P("PEG n=22") == P("peg-n=22")
        @test P("PEG n=22")[2] ≈ 19.24 + 36.73 * 22
        @test P("PEG n=22")[1] == 24 * 22 + 10
        @test_throws ArgumentError P("PEG n=1")
        # Senkow et al. 2002 (10.1039/b204404h): L64 2560, F68 7121, L35 1678 at 25 °C
        for (nEO, nPO, v) in ((26, 30, 2560.0), (150, 30, 7121.0), (22, 16, 1678.0))
            Z, V, σ = P("Pluronic nEO=$nEO nPO=$nPO")
            @test abs(V - v) < 2σ
            @test Z == 24nEO + 32nPO + 10
        end
        @test P("poloxamer nPO=30, nEO=150") == P("Pluronic nEO=150 nPO=30")
        @test_throws ArgumentError P("Pluronic nEO=10 nPO=0")
        # propylene glycol oligomers (n = 2 to 5) and maltooligosaccharides of the tables
        for (name, v) in (("PPG n=3", 177.61), ("PPG n=5", 283.75), ("glucan n=7", 694.8))
            _, V, σ = P(name)
            @test abs(V - v) < 2σ
        end
        @test P("PPG-2000") == P("polypropylene glycol 2000")
        @test P("dextran 40") == P("dextran 40000")
        # measured dextran slope (0.630 mL/g), not the
        # maltooligosaccharide line used for glucan/pullulan
        let m = (40000 - 18.015268) / 162.1406
            @test P("dextran 40000")[2] ≈ 16.6 + 102.2m
            @test P("pullulan 40000")[2] ≈ 16.6 + 96.7m
            @test P("dextran n=250")[2] ≈ 16.6 + 102.2 * 250
        end
        # UCON 50-HB: butanol plus EO and PO increments, equal masses of EO and PO
        let (Z, V, σ) = P("UCON Mn=3930")
            n_EO = 0.5 * (3930 - 74.1216) / 44.0526
            n_PO = 0.5 * (3930 - 74.1216) / 58.0791
            @test V ≈ 86.6 + 36.92n_EO + 53.13n_PO
            @test Z == round(Int, 42 + 24n_EO + 32n_PO) && σ > 3
            @test P("ucon 3930") == (Z, V, σ)
        end
        # a viscosity grade, not a molar mass
        @test_throws ArgumentError P("UCON 50-HB-5100")
        # fewer than one EO and one PO
        @test_throws ArgumentError P("UCON 80")
        @test P("pullulan 100000")[1] ==
              round(Int, 86 * (100000 - 18.015268) / 162.1406 + 10)
        # cyclodextrins: α, β, γ = 6, 7, 8 units (601.5, 710.0, 803.0)
        for (n, v) in ((6, 601.5), (7, 710.0), (8, 803.0))
            @test abs(P("cyclodextrin n=$n")[2] - v) < 2P("cyclodextrin n=$n")[3]
        end
        # Szymczyk & Taraba 2016: Triton X-114 (7.5 EO) micelle 516.6
        _, V, σ = P("Triton nEO=7.5")
        @test abs(V - 516.6) < 1e-9 && σ > 0
        @test P("Triton nEO=9.5")[1] == 342
        # alkyl ethoxylates are calibrated on
        # 2-methoxy/ethoxy/butoxyethanol (C1E1, C2E1, C4E1)
        for (name, v) in (("C1E1", 75.2), ("C2E1", 91.2), ("C4E1", 123.0))
            @test abs(P(name)[2] - v) < 2P(name)[3]
        end
        @test P("Brij nC=12 nEO=23") == P("C12E23")
        @test P("C12E23")[1] == 658                   # C58H118O24
        @test_throws ArgumentError P("not a polymer")
    end

    @testset "Polymer: maltoside and LMNG families, and their fixed monomer grades" begin
        P = IFACE._polymer_ϕ°
        # decyl maltoside C22H42O11 and LMNG C47H88O22:
        # the 3D-RISM estimates they are anchored on
        @test P("maltoside nC=10") == (262, 373.3, 3.9)
        @test P("LMNG nC=10")[[1, 3]] == (546, 5.6) && P("LMNG nC=10")[2] ≈ 782.9
        # one CH₂ is the alkyl increment (two per
        # carbon of an LMNG chain pair), Z of C24H46O11
        @test P("alkyl maltoside nC=12")[1] == 278
        @test P("maltoside nC=12")[2] ≈ 373.3 + 2 * IFACE.ALKYL_ETHOXYLATE_V0_PER_CH2
        @test P("MNG nC=12")[2] ≈ 782.9 + 4 * IFACE.ALKYL_ETHOXYLATE_V0_PER_CH2
        # the uncertainty grows with the distance from the calculated chain length
        @test P("maltoside nC=14")[3] > P("maltoside nC=10")[3]
        @test P("maltoside nC=8")[3] ≈ P("maltoside nC=12")[3]
        @test_throws ArgumentError P("maltoside nC=0")
        @test_throws ArgumentError P("LMNG nC=0")
        # the fixed monomer grades are the same numbers, and the family reproduces them
        @test P("decyl maltoside") == P("maltoside nC=10")
        @test P("n-decyl-beta-d-maltopyranoside") == P("decyl maltoside")
        @test P("lmng")[[1, 3]] == P("LMNG nC=10")[[1, 3]] &&
              P("lmng")[2] ≈ P("LMNG nC=10")[2]
        @test P("DDM")[1] == 278 && abs(P("DDM")[2] - P("maltoside nC=12")[2]) < 0.1
        @test P("digitonin") == (660, 860.1, 8.0)
        # they live in Polymers/ now, not in NonBiological
        @test_throws ArgumentError IFACE.ϕ°("digitonin")
    end

    @testset "Polymer: fixed grades of Polymers/polymers.json through POLYMER_LOOKUP" begin
        P = IFACE._polymer_ϕ°
        @test P("tween 80") == (716, 1137.2, 3.0)
        @test P("Tween 20")[2] ≈ 1037.0
        @test P("amphipol A8-35")[2] ≈ 100.3
        @test P("dextran")[2] ≈ 102.2
        # Miklos 2010 (PVP), Ochiai 1981 (PVA) and Acosta
        # 2017 (Ficoll 400), per monomer or per kDa
        @test P("PVP") == (60, 89.4, 0.6) && P("polyvinylpyrrolidone K30") == P("pvp-40")
        @test P("PVA") == (24, 33.2, 0.5) && P("polyvinyl alcohol") == P("pva")
        @test P("Ficoll 400") == P("ficoll") && P("ficoll")[2] == 680.0
        @test P("Ficoll 70")[2] == 650.0
        @test P("brij 35")[2] ≈ 1062.7
        @test abs(P("brij 35")[2] - P("C12E23")[2]) < 0.1
        @test P("alpha-cyclodextrin")[1] == 516
        # the charged glycylglycine forms are fixed predictions (no family: a charge marker)
        @test P("glycylglycine(1+)")[2] ≈ 84.7
    end

    @testset "Polymer: peptides follow the protein scheme plus terminus titration" begin
        P = IFACE._polymer_ϕ°
        # measured zwitterion volumes of the tables
        # (Hoiland): within the +-2 short-peptide uncertainty
        for (seq, v) in (("GG", 76.3), ("GGG", 112.2), ("GGGG", 149.7), ("GGGGG", 187.1),
            ("AA", 110.6), ("AAA", 163.8), ("AAAA", 220.1), ("GAG", 132.4), ("GSG", 133.1),
            ("GV", 121.99), ("GL", 139.7), ("SS", 111.8))
            _, V, σ = P("peptide $seq", 6.0)
            @test abs(V - v) < 2.5σ
        end
        # naming routes agree
        @test P("tetraalanine", 6.0) == P("peptide AAAA", 6.0)
        @test P("glycylleucylglycine", 6.0) == P("peptide GLG", 6.0)
        @test P("glycyl-α-aspartylglycine", 6.0) == P("peptide GDG", 6.0)
        @test P("pentaglycine", 6.0) == P("peptide GGGGG", 6.0)
        # termini titrate: cation at low pH is +10.5,
        # anion at high pH is +4.8 over the zwitterion
        v_zw = P("peptide GG", 6.0)[2]
        @test P("peptide GG", 0.0)[2] - v_zw ≈ 10.5 atol = 0.15
        @test P("peptide GG", 14.0)[2] - v_zw ≈ 4.8 atol = 0.15
        # carboxyl half protonated
        @test P("peptide GG", 3.3)[2] - v_zw ≈ 5.25 atol = 0.1
        # compare with the fixed OBIGT predictions of the charged forms (within 3)
        @test abs(P("peptide GG", 0.0)[2] - 84.7) < 3
        @test abs(P("peptide GG", 14.0)[2] - 80.4) < 3
        # pH uncertainty propagates only where the termini titrate
        @test P("peptide GG", 3.3, 0.2)[3] > P("peptide GG", 3.3, 0.0)[3]
        @test P("peptide GG", 6.0, 0.2)[3] ≈ P("peptide GG", 6.0, 0.0)[3] atol = 5e-3
        @test_throws ArgumentError P("peptide G")
    end

    @testset "Polymer solute enters ρₑ and replaces a NonBiological entry's role" begin
        ρ_peg, σ_peg =
            IFACE.ρₑ(7.0, 0.0, IFACE.Solute[IFACE.Polymer(0.001, 1e-5, "PEG-3350")])
        ρ_w, _ = IFACE.ρₑ(7.0, 0.0, IFACE.Solute[])
        # 1 mM of a 3350 Da chain adds electrons
        @test ρ_peg > ρ_w && σ_peg > 0
        @test_throws ArgumentError IFACE.ρₑ(
            7.0,
            0.0,
            IFACE.Solute[IFACE.Polymer(0.001, 1e-5, "not a polymer")],
        )
        # polymers are not NonBiological solutes
        @test_throws ArgumentError IFACE.ϕ°("PEG-3350")
    end

    @testset "Polymers/polymers.{tsv,json,lookup}: JSON values are rule winners" begin
        dir = joinpath(dirname(pathof(BAYSOL)), "BulkElectronDensity", "Polymers")
        lines = readlines(joinpath(dir, "polymers.tsv"))
        rank = Dict("measured" => 0, "derived" => 1, "predicted" => 2)
        best = Dict{String,Tuple{Tuple{Int,Float64},Float64}}()
        targets = Set(lowercase(t) for t in values(IFACE.POLYMER_LOOKUP))
        names = String[]
        for l in lines[2:end]
            f = split(l, '\t'; keepempty = true)
            push!(names, lowercase(f[2]))
            f[7] == "rejected" && continue
            k = lowercase(f[2])
            r = (get(rank, f[7], 3), f[6] == "" ? Inf : parse(Float64, f[6]))
            haskey(best, k) && best[k][1] <= r && continue
            best[k] = (r, parse(Float64, f[5]))
        end
        @test sort(collect(keys(best))) == sort(collect(keys(IFACE._polymers)))
        @test all(k -> IFACE._polymers[k][2] == best[k][2], keys(best))
        @test all(n -> n in targets, names)            # every row's name is a lookup target
        @test all(a -> a == lowercase(a), keys(IFACE.POLYMER_LOOKUP))
        # no species lives in both lookups
        @test isempty(intersect(keys(IFACE.POLYMER_LOOKUP), keys(IFACE.NONBIO_LOOKUP)))
    end

    @testset "ϕ°(name): known solutes with an explicitly reported uncertainty" begin
        @test IFACE.ϕ°("sodium chloride") == (28, 16.61, 0.01)
        @test IFACE.ϕ°("potassium chloride") == (36, 26.81, 0.01)
        @test IFACE.ϕ°("tris") == (66, 90.63, 0.05)
        @test IFACE.ϕ°("hepes") == (128, 152.8, 3.1)
        @test IFACE.ϕ°("mops") == (112, 145.71, 0.4)
        # Polak 2021 (10.1016/j.jct.2021.106450) replaced Kumar 2001 (69.92 ± 0.4)
        @test IFACE.ϕ°("guanidinium chloride") == (50, 67.53, 0.13)
        @test IFACE.ϕ°("calcium chloride") == (54, 17.839, 0.03)
        # DTT, IUPAC name direct
        @test IFACE.ϕ°("1,4-disulfanylbutane-2,3-diol") == (82, 103.6, 6.4)
        # Kaczkowska 2019 (10.1016/j.molliq.2018.10.155):
        # taurine is new, the smaller uncertainties win
        @test IFACE.ϕ°("taurine") == (66, 71.13, 0.08)
        @test IFACE.ϕ°("glycine") == (40, 43.11, 0.01)
        @test IFACE.ϕ°("TMAO")[2] == 73.32
        # Held 2010 densities (ectoines) and the 3D-RISM difference estimate of NEP
        @test IFACE.ϕ°("ectoine") == (76, 102.8, 1.0)
        @test IFACE.ϕ°("hydroxyectoine")[1] == 84 && IFACE.ϕ°("homoectoine")[1] == 84
        @test IFACE.ϕ°("N-ethyl-2-pyrrolidone") == (62, 107.2, 1.5)
        # Malevich 2006 NTA salts (measured) and ions (derived on the conventional scale)
        @test IFACE.ϕ°("Na3NTA") == (130, 98.5, 0.5)
        @test IFACE.ϕ°("NTA3-")[2] == 102.1 && IFACE.ϕ°("NiNTA-")[2] == 95.4
        # Xie 1999 DTPA species: ion = salt − n·V(Na⁺), V(Na⁺) = −1.21
        @test IFACE.ϕ°("Na5DTPA")[2] ≈ 196.47
        @test IFACE.ϕ°("DTPA5-")[2] ≈ IFACE.ϕ°("Na5DTPA")[2] + 5 * 1.21 atol = 1e-9
        # De Lisi 1990: the measured micellar volume outranks the additivity-derived monomer
        @test IFACE.ϕ°("CTAB")[2] == 360.4 && IFACE.ϕ°("TTAB")[2] == 327.8
        # Wang 2008 sodium cholate (measured) does not displace the measured cholate anion
        @test IFACE.ϕ°("sodium cholate")[2] == 326.3 && IFACE.ϕ°("cholate")[2] == 318.59
    end

    # …when unreported
    @testset "ϕ°(name): uncertainty is backfilled with the live average" begin
        # nonbiological.json stores `nothing` uncertainty for a solute when no source
        # reports one; ϕ° backfills with the mean of every other solute's uncertainty.
        reported = [u for (_, _, u) in values(PMVMOD._solutes) if u !== nothing]
        avg_u = sum(reported) / length(reported)
        @test length(reported) > 0
        for name in
            ("lithium chloride", "sodium bromide", "propane-1,2,3-triol", "sodium iodide",
            "trisodium 2-hydroxypropane-1,2,3-tricarboxylate",
            "magnesium dichloride")
            e, v, u = IFACE.ϕ°(name)
            @test (e, v) == (PMVMOD._solutes[name][1], PMVMOD._solutes[name][2])
            @test close_(u, avg_u; atol = 1e3 * DEFAULT_ATOL)
        end
        # confirm those really are the `nothing`-uncertainty rows, i.e.
        # the test above is exercising the backfill path and not coincidence
        for name in
            ("lithium chloride", "sodium bromide", "propane-1,2,3-triol", "sodium iodide")
            @test PMVMOD._solutes[name][3] === nothing
        end
    end

    @testset "ϕ°(name): trisodium citrate is sussy" begin
        # NonBiological/README.md flags this row as having two disagreeing
        # published sources (57.1 vs 69.32 cm3/mol). The 2026-09 audit marked
        # 57.1 `rejected` in favour of Apelblat & Manzurola's 69.32
        # (10.1016/0378-3812(90)85049-G). The selected value is pinned here so
        # a future data revision is caught.
        e, v, u = IFACE.ϕ°("trisodium citrate")
        @test e == 130
        @test close_(v, 69.32)
    end

    # …for a mis-cased IUPAC name
    @testset "ϕ°(name): resolves through the common-name fallback even" begin
        # "Urea" is not itself a `_solutes` key (keys are lowercase IUPAC), so
        # resolution falls through to `_common2target`, which lowercases before
        # looking the name up in `NONBIO_LOOKUP`.
        @test IFACE.ϕ°("Urea") == IFACE.ϕ°("urea")
        @test IFACE.ϕ°("UREA") == IFACE.ϕ°("urea")
    end

    @testset "ϕ°(name): 3D-RISM additions resolve from trivial, older, CAS names" begin
        V(name) = IFACE.ϕ°(name)[2]
        # bare and trivial names, the buffer's older
        # IUPAC and CAS spellings, enantiomer descriptors
        for (names, v) in (
            (
                ("tes", "TES buffer",
                    "N-Tris(hydroxymethyl)methyl-2-aminoethanesulfonic acid",
                    "Ethanesulfonic acid, 2-[[2-hydroxy-1,1-bis(hydroxymethyl)" *
                    "ethyl]amino]-",
                    "2-[tris(hydroxymethyl)methylamino]ethanesulphonic acid"), 137.8),
            (
                ("capso", "CAPSO", "3-(Cyclohexylamino)-2-hydroxy-1-propanesulfonic acid",
                    "1-Propanesulfonic acid, 3-(cyclohexylamino)-2-hydroxy-", "(S)-CAPSO",
                    "dl-capso",
                    "(2R)-3-(cyclohexylamino)-2-hydroxypropane-1-sulfonic acid"), 172.4),
            (
                ("ampso", "AMPSO",
                    "N-(1,1-Dimethyl-2-hydroxyethyl)-3-amino-2-hydroxypropanesulfonic acid",
                    "(R)-AMPSO"), 157.0),
            (
                ("bis-tris propane", "BTP", "Bis Tris Propane",
                    "1,3-Bis[tris(hydroxymethyl)methylamino]propane",
                    "2,2'-(propane-1,3-diyldiimino)bis" *
                    "[2-(hydroxymethyl)propane-1,3-diol]"), 211.3),
            (
                ("tcep", "tris(2-carboxyethyl)phosphine",
                    "3,3',3''-phosphanetriyltripropionic acid",
                    "Propanoic acid, 3,3',3''-phosphinidynetris-"), 182.8),
            (("egta", "EGTA tetraanion", "egta(4-)"), 210.2),
            (("hegta3-", "EGTA(3-)"), 227.9),
            (("H2EGTA2-", "egta2-"), 234.9),
            (
                ("chapso",
                    "3-[(3-Cholamidopropyl)dimethylammonio]-2-hydroxy-1-propanesulfonate",
                    "(R)-CHAPSO"), 495.9))
            for n in names
                @test V(n) ≈ v
            end
        end
        # a PubChem typo that OPSIN rejected (1-hydroxy instead of 2-hydroxy) was not added
        @test_throws ArgumentError IFACE.ϕ°(
            "3-(cyclohexylamino)-1-hydroxypropane-1-sulfonic acid",
        )
        # detergents live in Polymers: trivial, anomeric and
        # older spellings reach the fixed monomer grades
        P = IFACE._polymer_ϕ°
        for n in ("DDM", "n-Dodecyl-β-D-maltoside", "Lauryl maltoside",
            "dodecyl-beta-d-maltoside",
            "n-dodecyl-alpha-d-maltoside",
            "dodecyl 4-O-α-D-glucopyranosyl-β-D-glucopyranoside")
            @test P(n)[2] ≈ 405.2
        end
        for n in ("MNG-3", "LMNG", "2,2-didecylpropane-1,3-bis-β-D-maltopyranoside")
            @test P(n)[2] ≈ 782.9
        end
        @test P("Digitonine")[2] ≈ 860.1
        # two aliases that named other compounds were removed: DMG
        # is dimethylglycine, and digitoxigenin is not digitogenin
        @test_throws ArgumentError P("dmg")
        @test_throws ArgumentError P("digitoxigenin glycoside")
    end

    @testset "ϕ°(name): formula and abbreviation aliases reach the intended species" begin
        # citrate, not isocitrate (the formula aliases once pointed at the isomer)
        @test IFACE.ϕ°("c6h5o7-3") == IFACE.ϕ°("citrate")
        @test IFACE.ϕ°("c6h6o7-2") == IFACE.ϕ°("hydrogen citrate")
        @test IFACE.ϕ°("c6h8o7") == IFACE.ϕ°("citric acid")
        @test IFACE.ϕ°("c6h5o7-3") != IFACE.ϕ°("isocitrate(3-)")
        @test IFACE.ϕ°("gdnhcl") == IFACE.ϕ°("guanidinium chloride")
        @test IFACE.ϕ°("glycerin") == IFACE.ϕ°("glycerol")
        @test IFACE.ϕ°("naoh") == IFACE.ϕ°("sodium hydroxide")
        @test IFACE.ϕ°("sodium sulfate decahydrate") == IFACE.ϕ°("sodium sulfate")
        @test IFACE.ϕ°("spermidine")[1] == 82            # the 3+ form, as at pH 7
        @test IFACE.ϕ°("spermine")[1] == 114
    end

    @testset "ϕ°(name): the 2026-10-22 gap-filling batch is internally consistent" begin
        V(n) = IFACE.ϕ°(n)[2]
        # additivity rows equal the sum of their ion rows
        @test V("mncl2") ≈ V("manganese(2+)") + 2 * V("chloride")
        @test V("koh") ≈ V("potassium(1+)") + V("hydroxide")
        @test V("hbr") ≈ V("bromide")                       # strong acid, V(H+) = 0
        @test V("tris-hcl") > V("tris")
        # buffer salts are the anion plus the counter-ion
        @test V("sodium hepes") ≈ V("hepes anion") + V("sodium(1+)")
        @test V("hepes anion") > V("hepes")                  # anion above the zwitterion
        # fatty acid series grows by about 15.5 per CH2
        @test 14.5 < (V("palmitate") - V("myristate")) / 2 < 16.5
        @test 14.5 < (V("stearic acid") - V("palmitic acid")) / 2 < 16.5
        # ATP chain
        @test V("atp(4-)") < V("atp disodium salt")
        @test V("atpγs(4-)") > V("atp(4-)")
        @test V("camp") < V("amp")
        # hydrates share the anhydrous value; borate and lipids exist
        @test V("trehalose dihydrate") ≈ V("trehalose")
        @test V("sodium carbonate decahydrate") ≈ V("sodium carbonate")
        @test V("borate") > 0
        @test V("dmpc") > 600
        Z(n) = IFACE.ϕ°(n)[1]
        @test Z("copper chloride") == Z("copper(2+)") + 2 * Z("chloride")
        # cationic guanidinium/amidinium RISM rows were left out on purpose
        @test_throws ArgumentError IFACE.ϕ°("benzamidinium")
        # the Gianni-Lepori tridecanoate row was rejected
        @test_throws ArgumentError IFACE.ϕ°("tridecanoate")
        # detergent monomer and poly(A) residue are Polymers
        @test IFACE._polymer_ϕ°("dpc")[2] > 300
        @test IFACE._polymer_ϕ°("poly(a)")[2] ≈ 189.13 atol = 0.5
    end

    @testset "ϕ°(name): unknown solute throws ArgumentError" begin
        # a real, just-unmapped reagent
        @test_throws ArgumentError IFACE.ϕ°("iodoacetamide")
        @test_throws ArgumentError IFACE.ϕ°("not a real solute at all")
    end

    @testset "ϕ°(name): a realistic multi-component SAXS buffer" begin
        # Not exhaustive of any real recipe, but a non-trivial mixed panel of
        # buffering agents, salts, denaturants, reductants and cryoprotectants
        # at the sizes real solution-scattering buffers actually use.
        buffer_components = [
            "urea", "glycine", "glycerol", "sucrose", "sodium chloride",
            "potassium chloride", "calcium chloride", "tris", "imidazole",
            "hepes", "mops", "guanidinium chloride", "trisodium citrate",
            "1,4-disulfanylbutane-2,3-diol",
        ]
        @test length(buffer_components) ≥ 14
        for name in buffer_components
            e, v, u = IFACE.ϕ°(name)
            @test e > 0
            @test v > 0.0
            @test u ≥ 0.0
            @test isfinite(v) && isfinite(u)
        end
    end

    #------------------------------------------------------------------
    #                _common2target (private -- reached only via ϕ°(name))
    #------------------------------------------------------------------

    @testset "_common2target: hits, case-insensitivity, and misses" begin
        # Not part of the public dispatch surface.
        @test PMVMOD._common2target("urea") == ("urea", true)
        @test PMVMOD._common2target("Urea") == ("urea", true)
        @test PMVMOD._common2target("UREA") == ("urea", true)
        @test PMVMOD._common2target("sodium chloride") == ("sodium chloride", true)
        @test PMVMOD._common2target("calcium chloride") == ("calcium dichloride", true)
        @test PMVMOD._common2target("iodoacetamide") == ("", false)
        @test PMVMOD._common2target("") == ("", false)
    end

    #------------------------------------------------------------------
    #     Integration: additive-volume buffer/solution sanity checks
    #------------------------------------------------------------------

    # …sensible
    @testset "integration: additive dilute-buffer volume balance is physically" begin
        # V(solution) ~= V0(water) + sum(n_i * V0_i) at infinite dilution. 20 mM Tris +
        # 150 mM NaCl + 1 mM DTT is a realistic, non-trivial SAXS buffer; the whole
        # perturbation on top of 1 L of pure water should be a small, positive number
        ρe_w25 = IFACE._ρₑ_w(25.0)[1]
        # Invert rho_e_w = AVOGADRO*10/(1e27*v) for v (in "1e-3 m3/mol" units
        # per the source's own comment on that line), then convert to cm3/mol:
        # 1e27*v is in A^3/mol, and 1 A^3 = 1e-24 cm3, so v0_water_cm3_per_mol
        # = (1e27*v) * 1e-24 = 1e3*v = AVOGADRO*10/(1e24*rho_e_w25).
        v0_water =
            AVOGADRO * WATER_ELECTRONS / (ANGSTROM3_PER_LITER / CM3_PER_LITER * ρe_w25)
        # textbook molar volume of water, ~18.07 cm3/mol
        @test close_(v0_water, 18.0687; atol = 1e-3)

        n_water = 1000.0 / v0_water                    # mol water per 1 L reference volume
        baseline_volume = n_water * v0_water
        @test close_(baseline_volume, 1000.0)

        _, v_tris, _ = IFACE.ϕ°("tris")
        _, v_nacl, _ = IFACE.ϕ°("sodium chloride")
        _, v_dtt, _  = IFACE.ϕ°("1,4-disulfanylbutane-2,3-diol")
        # mol of each, per 1 L
        Δv = 0.020 * v_tris + 0.150 * v_nacl + 0.001 * v_dtt

        @test Δv > 0.0
        @test Δv < 0.02 * baseline_volume    # buffer perturbs volume by well under 2%
        total_volume = baseline_volume + Δv
        @test close_(total_volume, 1004.4077; atol = 1e-2)
    end

    # …volume increment
    @testset "integration: a very dilute protein contributes a proportionally tiny" begin
        # 1 mg/mL lysozyme (a typical dilute SAXS concentration) in 1 L of the
        # buffer above: moles = mass / MW, using the same ~14313 Da MW as the
        # partial-specific-volume check above.
        _, v_lys, _ = IFACE.ϕ°(7.4, LYSOZYME)
        n_lys = 1.0 / 14313.0     # mol, for 1 g (1 mg/mL * 1000 mL) of protein
        Δv_protein = n_lys * v_lys
        # cm3 out of a ~1 L reference volume: tiny but nonzero
        @test 0.0 < Δv_protein < 1.0
    end
end
