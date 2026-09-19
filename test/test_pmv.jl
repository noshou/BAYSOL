# SPDX-License-Identifier: LGPL-2.1-or-later

# Exercises src/Interfaces/PartialMolarVolumes/PMV.jl: bulk water electron
# density (Kell-equation density -> e/A^-3, `ρₑ_w`) and protein/non-protein
# partial molar volumes at infinite dilution (`ϕ°`), including the
# pH-dependent titration formula, ambiguity-code (B/J/Z) averaging, the
# uncertainty backfill for solutes with no reported error, and the
# `Interfaces` dispatch surface (`common2iupac`, backend markers).
#
# Data provenance for every hardcoded number below: `ρₑ_w` reference values
# are a re-derivation of the published Kell (1975) density equation plus the same
# ideal mass-density -> electron-density conversion PMV.jl uses. Protein
# values are hand-derived closed forms from `Protein.json`/
# `ionization.json` (Lee et al. 2008, DOI 10.1016/j.bpc.2008.02.009) as they
# stood when this file was written.

const IFACE = BayeSol.Interfaces
using BayeSol.Interfaces.PartialMolarVolumes:
    PartialMolarVolumes, PMVSrcTables, COMMON_TO_IUPAC
using BayeSol.Constants: AVOGADRO

"Fully-qualified handle onto the submodule, for the private caches/tables below."
const PMVMOD = BayeSol.Interfaces.PartialMolarVolumes

include(joinpath(@__DIR__, "fixtures", "floatcompare.jl"))   # close_
include(joinpath(@__DIR__, "fixtures", "sequences.jl"))      # LYSOZYME, ...

# fresh_seq(base): a sequence that computes identically to `base` (padded
# with inert 'X' no-ops) but is guaranteed never to have
# been queried before anywhere in this file.
let _fresh_n = Ref(0)
    global fresh_seq(base::AbstractString) = (_fresh_n[] += 1; base * "X"^_fresh_n[])
end

@testset "PartialMolarVolumes" begin

    @testset "backend marker & Interfaces dispatch agreement" begin
        @test PMVSrcTables() isa IFACE.PartialMolarVolumeSource
        @test IFACE.ρₑ_w(25.0) == IFACE.ρₑ_w(PMVSrcTables(), 25.0)
        @test IFACE.ϕ°(7.0, "GGGG") == IFACE.ϕ°(PMVSrcTables(), 7.0, "GGGG")
        @test IFACE.ϕ°("urea") == IFACE.ϕ°(PMVSrcTables(), "urea")
        dispatch_seq = fresh_seq("D")
        @test IFACE.ϕ°(4.0, dispatch_seq; σ_pH = 0.3) == IFACE.ϕ°(PMVSrcTables(), 4.0, dispatch_seq; σ_pH = 0.3)
    end

    #------------------------------------------------------------------
    #                    ρₑ_w -- bulk water electron density
    #------------------------------------------------------------------

    @testset "ρₑ_w: Kell-equation electron density at reference temperatures" begin
        # (t degC, rho_e expected e.A^-3, uncertainty expected e.A^-3)
        # rho_e(25) ~ 0.3333 e/A^-3 is the textbook bulk-water constant 
        ref = [
            (0.0,   0.3342261867461997,  6.685596639472697e-6),
            (3.984, 0.33427047092945,    6.685596639472695e-6),   # density maximum, see below
            (4.0,   0.3342704701746428,  6.685596639472696e-6),
            (20.0,  0.333679509587399,   6.685596639472695e-6),
            (25.0,  0.3332920001104711,  6.685596639472696e-6),
            (37.0,  0.3320497365290211,  6.685596639472695e-6),   # body temperature
            (100.0, 0.3203616422488662,  6.685596639472695e-6),
            (150.0, 0.30647748126647417, 6.6855966394726945e-6),
        ]
        for (t, ρe_expected, u_expected) in ref
            ρe, u = IFACE.ρₑ_w(t)
            @test close_(ρe, ρe_expected; atol = 1e-12)
            @test close_(u, u_expected; atol = 1e-15)
        end
    end

    @testset "ρₑ_w: relative uncertainty is a temperature-independent constant" begin
        # unc(t) = rho_e(t) * 0.02/rho(t), and rho_e(t) is proportional
        # to rho(t) (same conversion factor at every t), so the ratio
        # rho_e/rho is a fixed constant and unc(t) must come out identical at
        # every temperature.
        u_ref = IFACE.ρₑ_w(0.0)[2]
        for t in (1.0, 22.5, 49.9, 88.0, 133.3, 150.0)
            @test close_(IFACE.ρₑ_w(t)[2], u_ref; atol = 1e-19)
        end
    end

    @testset "ρₑ_w: density maximum near 3.98 C" begin
        ρe_0  = IFACE.ρₑ_w(0.0)[1]
        ρe_4  = IFACE.ρₑ_w(3.984)[1]
        ρe_10 = IFACE.ρₑ_w(10.0)[1]
        @test ρe_4 > ρe_0
        @test ρe_4 > ρe_10
        # monotonically decreasing above the maximum, matching the real
        # density curve out to the boiling point and beyond (the equation is
        # only nominally valid to 150 C at 1 atm, but is still smooth there).
        prev = ρe_4
        for t in 5.0:5.0:150.0
            cur = IFACE.ρₑ_w(t)[1]
            @test cur < prev
            prev = cur
        end
    end

    @testset "ρₑ_w: domain is [0, 150] C inclusive, exclusive outside" begin
        @test IFACE.ρₑ_w(0.0)[1] isa Float64      # lower boundary allowed
        @test IFACE.ρₑ_w(150.0)[1] isa Float64    # upper boundary allowed
        @test_throws DomainError IFACE.ρₑ_w(-1.0e-9)
        @test_throws DomainError IFACE.ρₑ_w(150.0 + 1.0e-9)
        @test_throws DomainError IFACE.ρₑ_w(-50.0)
        @test_throws DomainError IFACE.ρₑ_w(1000.0)
    end

    @testset "ρₑ_w: memoization returns the exact cached value" begin
        a = IFACE.ρₑ_w(63.219)
        b = IFACE.ρₑ_w(63.219)
        @test a === b
        @test haskey(PMVMOD._ρₑ_w_cache, round(Int64, 63.219 * 1000))
    end

    @testset "ρₑ_w: the cache key is quantized to 1e-3 C" begin
        # key = round(Int64, t*1000), so two temperatures within 0.0005 C of
        # each other collide on the same cache slot. Whichever is queried
        # first "wins".
        t_a, t_b = 111.111, 111.1114              # both round(*1000) to 111111
        @test round(Int64, t_a * 1000) == round(Int64, t_b * 1000)
        first  = IFACE.ρₑ_w(t_a)
        second = IFACE.ρₑ_w(t_b)                  # served from t_a's cache slot
        @test second === first
        @test !close_(second[1], 0.3175976147955338; atol = 1e-12)  # t_b's *true* value
        @test close_(second[1], 0.317597717642839; atol = 1e-12)    # t_a's value, reused
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

    @testset "ϕ°(pH, seq; σ_pH): pH-measurement uncertainty propagates via the delta method" begin
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
            @test close_(u, u_expected; atol = 1e-9)
        end
    end

    @testset "ϕ°(pH, seq; σ_pH): non-ionizable residues are agnostic to σ_pH" begin
        # sigma_pH only ever reaches `_titrated`'s delta-method term; the
        # non-ionizable branch of `_residue_var` never sees it at all.
        baseline = IFACE.ϕ°(7.0, "GAVLIPFWMCYSTNQ")
        loud     = IFACE.ϕ°(7.0, "GAVLIPFWMCYSTNQX"; σ_pH = 1.0e6)   # padded: fresh cache slot
        @test loud[1] == baseline[1]                    # X adds no electrons either
        @test close_(loud[2], baseline[2])
        @test close_(loud[3], baseline[3])
    end

    @testset "ϕ°(pH, seq; σ_pH): saturates away from the sigmoid's steep region" begin
        # Far from pKa, frac*(1-frac) -> 0, so dpmv/dpH -> 0 and even a huge
        # sigma_pH contributes essentially nothing. pH uncertainty only
        # matters when the residue is genuinely near its titration point.
        pKa = 4.0
        quiet = IFACE.ϕ°(pKa - 30.0, fresh_seq("D"); σ_pH = 5.0)
        hush  = IFACE.ϕ°(pKa - 30.0, fresh_seq("D"); σ_pH = 0.0)
        @test close_(quiet[2], hush[2]; atol = 1e-6)
        @test close_(quiet[3], hush[3]; atol = 1e-6)
    end

    @testset "ϕ°(pH, seq; σ_pH): wildcard averaging applies σ_pH only to the ionizable half" begin
        # B = Asp/Asn at Asp's own pKa (4.0): Asn contributes no pH-derivative
        # term at all, so sigma_pH's effect is exactly the D-branch's
        # contribution above, divided by 4 by the wildcard-averaging rule.
        v_expected = 37.4 + ((31.7 - 12.1 * 0.5) + 34.0) / 2
        e, v, u = IFACE.ϕ°(4.0, "B"; σ_pH = 0.2)
        @test e == 70                     # backbone(30) + round((30+30)/2) + formation-water(10)
        @test close_(v, v_expected)
        @test close_(u, 0.7194837134862498; atol = 1e-9)
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
            @test close_(v_lo - v_hi, dv; atol = 1e-6)
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
        @test close_(v_hi, 37.4 + (31.7 - 12.1))              # fully deprotonated: frac -> 1
        @test close_(u_hi, sqrt(0.1^2 + (0.1^2 + 0.4^2)))
        @test all(isfinite, (v_lo, u_lo, v_hi, u_hi))
    end

    @testset "ϕ°(pH, seq): ambiguity codes B/J/Z average their two residues, at scale" begin
        # J = Leu/Ile, both non-ionizable -> pH-independent closed form.
        z, v, u = IFACE.ϕ°(7.0, "J"^1000)
        @test z == 62010
        @test close_(v, 102000.0; atol = 1e-6)
        @test close_(u, 4.743416490252559; atol = 1e-6)

        # B = Asp/Asn, Asp ionizable -> evaluated at Asp's own pKa (4.0) for
        # an exact 0.5 sigmoid midpoint.
        zb, vb, ub = IFACE.ϕ°(4.0, "B"^1500)
        @test zb == 90010
        @test close_(vb, 100837.49999999524; atol = 1e-4)
        @test close_(ub, 6.982120021884522; atol = 1e-6)

        # Z = Glu/Gln, Glu ionizable -> evaluated at Glu's own pKa (4.4).
        zz, vz, uz = IFACE.ϕ°(4.4, "Z"^800)
        @test zz == 54410
        @test close_(vz, 66960.00000000169; atol = 1e-6)
        @test close_(uz, 10.770329614269151; atol = 1e-6)
    end

    @testset "ϕ°(pH, seq): 'X'/'*' are no-ops" begin
        # Neither contributes a backbone unit, an electron, nor a volume. An
        # all-placeholder "sequence" formed no peptide bonds at all so the 
        # formation-water electron count is only added when at least one real 
        # residue was actually present.
        @test IFACE.ϕ°(7.0, "XXXX") == (0, 0.0, 0.0)
        @test IFACE.ϕ°(7.0, "*"^37) == (0, 0.0, 0.0)
        padded  = IFACE.ϕ°(7.0, "X"^10 * "A" * "*"^10)
        bare    = IFACE.ϕ°(7.0, "A")
        @test padded == bare
    end

    @testset "ϕ°(pH, seq): very long non-ionizable chains (closed form, N=5000)" begin
        # All-glycine: every term is 0 except the shared backbone, so the
        # totals are exact linear closed forms.
        N = 5000
        z, v, u = IFACE.ϕ°(7.0, "G"^N)
        @test z == 30 * N + 10
        @test close_(v, 37.4 * N; atol = 1e-4)
        @test close_(u, sqrt(N * 0.1^2); atol = 1e-9)
    end

    @testset "ϕ°(pH, seq): very long ionizable chain at its own pKa (closed form, N=3000)" begin
        N = 3000
        z, v, u = IFACE.ϕ°(4.0, "D"^N)     # pH == D's pKa: exact 0.5 sigmoid
        @test z == 60 * N + 10
        per_v = 37.4 + (31.7 - 12.1 * 0.5)
        per_sqr_u = 0.1^2 + (0.1^2 + (0.4 * 0.5)^2)
        @test close_(v, per_v * N; atol = 1e-4)
        @test close_(u, sqrt(per_sqr_u * N); atol = 1e-6)
    end

    @testset "ϕ°(pH, seq): real protein (hen egg-white lysozyme, 129 aa)" begin
        @test length(LYSOZYME) == 129
        # (pH, electron count, V0 cm3/mol, uncertainty cm3/mol)
        ref = [
            (2.0,  7628, 10424.367875646007, 3.019952617978304),
            (7.4,  7628, 10318.375679646211, 3.247557761154545),
            (11.0, 7628, 10340.21595229236,  3.0275892082170173),
        ]
        for (pH, e_expected, v_expected, u_expected) in ref
            # fresh_seq: ϕ° caches by sequence only, and this loop needs a
            # different computation at each of the 3 pH values.
            e, v, u = IFACE.ϕ°(pH, fresh_seq(LYSOZYME))
            @test e == e_expected
            @test close_(v, v_expected; atol = 1e-6)
            @test close_(u, u_expected; atol = 1e-6)
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
        @test close_(vk, k * v1; atol = 1e-3)
        @test close_(uk, sqrt(k) * u1; atol = 1e-6)
    end

    @testset "ϕ°(pH, seq): argument errors" begin
        @test_throws ArgumentError IFACE.ϕ°(7.0, "")
        @test_throws ArgumentError IFACE.ϕ°(7.0, "Z9")       # '9' is not a residue code
        @test_throws ArgumentError IFACE.ϕ°(7.0, "a")        # lowercase: codes are uppercase-only
        @test_throws ArgumentError IFACE.ϕ°(7.0, "AAaAA")    # invalid char mid-sequence
        @test_throws ArgumentError IFACE.ϕ°(7.0, "B J")      # bare space is not a residue code
    end

    @testset "ϕ°(pH, seq): caches by sequence only" begin
        seq = "DDDD"                       # unused by any other testset in this file
        @test !haskey(PMVMOD._ϕ°_p_cache, seq)
        low_pH_result  = IFACE.ϕ°(1.0, seq)   # nearly fully protonated
        high_pH_result = IFACE.ϕ°(13.0, seq)  # nearly fully deprotonated -- ignored!
        @test high_pH_result == low_pH_result
        @test close_(low_pH_result[2], 276.35164835164835; atol = 1e-6)   # the pH=1 answer...
        @test !close_(high_pH_result[2], 228.0000000484; atol = 1e-3)     # ...NOT the pH=13 one
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

    @testset "ϕ°(name): known solutes with an explicitly reported uncertainty" begin
        @test IFACE.ϕ°("sodium chloride")      == (28,  16.61,  0.01)
        @test IFACE.ϕ°("potassium chloride")   == (36,  26.81,  0.01)
        @test IFACE.ϕ°("tris")                 == (66,  90.63,  0.05)
        @test IFACE.ϕ°("hepes")                == (128, 152.8,  3.1)
        @test IFACE.ϕ°("mops")                 == (112, 145.71, 0.4)
        @test IFACE.ϕ°("guanidinium chloride") == (50,  69.92,  0.4)
        @test IFACE.ϕ°("calcium chloride")     == (54,  17.839, 0.03)
        @test IFACE.ϕ°("1,4-disulfanylbutane-2,3-diol") == (82, 103.6, 6.4)   # DTT, IUPAC name direct
    end

    @testset "ϕ°(name): uncertainty is backfilled with the live average when unreported" begin
        # nonbiological.json stores `nothing` uncertainty for a solute when no
        # source reports one; ϕ° backfills with the mean of every other solute's uncertainty.
        reported = [u for (_, _, u) in values(PMVMOD._solutes) if u !== nothing]
        avg_u = sum(reported) / length(reported)
        @test length(reported) > 0
        for name in ("urea", "glycine", "propane-1,2,3-triol", "sucrose",
                    "trisodium 2-hydroxypropane-1,2,3-tricarboxylate",
                    "magnesium dichloride")
            e, v, u = IFACE.ϕ°(name)
            @test (e, v) == (PMVMOD._solutes[name][1], PMVMOD._solutes[name][2])
            @test close_(u, avg_u; atol = 1e-6)
        end
        # confirm those really are the `nothing`-uncertainty rows, i.e.
        # the test above is exercising the backfill path and not coincidence
        for name in ("urea", "glycine", "propane-1,2,3-triol", "sucrose")
            @test PMVMOD._solutes[name][3] === nothing
        end
    end

    @testset "ϕ°(name): trisodium citrate is sussy" begin
        # NonBiological/README.md flags this row as having two disagreeing
        # published sources (57.1 vs 69.32 cm3/mol); the currently-selected
        # value is pinned here so a future data revision is caught..
        e, v, u = IFACE.ϕ°("trisodium citrate")
        @test e == 130
        @test close_(v, 57.1)
    end

    @testset "ϕ°(name): resolves through the common-name fallback even for a mis-cased IUPAC name" begin
        # "Urea" is not itself a `_solutes` key (keys are lowercase IUPAC), so
        # resolution falls through to `common2iupac`, which lowercases before
        # looking the name up in COMMON_TO_IUPAC.
        @test IFACE.ϕ°("Urea") == IFACE.ϕ°("urea")
        @test IFACE.ϕ°("UREA") == IFACE.ϕ°("urea")
    end

    @testset "ϕ°(name): unknown solute throws ArgumentError" begin
        @test_throws ArgumentError IFACE.ϕ°("edta")                       # a real, just-unmapped reagent
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
        @test length(buffer_components) >= 14
        for name in buffer_components
            e, v, u = IFACE.ϕ°(name)
            @test e > 0
            @test v > 0.0
            @test u >= 0.0
            @test isfinite(v) && isfinite(u)
        end
    end

    #------------------------------------------------------------------
    #                _common2iupac (private -- reached only via ϕ°(name))
    #------------------------------------------------------------------

    @testset "_common2iupac: hits, case-insensitivity, and misses" begin
        # Not part of the public Interfaces surface.
        @test PMVMOD._common2iupac("urea") == ("urea", true)
        @test PMVMOD._common2iupac("Urea") == ("urea", true)
        @test PMVMOD._common2iupac("UREA") == ("urea", true)
        @test PMVMOD._common2iupac("sodium chloride") == ("sodium chloride", true)
        @test PMVMOD._common2iupac("calcium chloride") == ("calcium dichloride", true)
        @test PMVMOD._common2iupac("edta") == ("", false)
        @test PMVMOD._common2iupac("") == ("", false)
    end

    #------------------------------------------------------------------
    #     Integration: additive-volume buffer/solution sanity checks
    #------------------------------------------------------------------

    @testset "integration: additive dilute-buffer volume balance is physically sensible" begin
        # V(solution) ~= V0(water) + sum(n_i * V0_i)  at infinite dilution. 
        # 20 mM Tris + 150 mM NaCl + 1 mM DTT is a realistic, non-trivial SAXS buffer; 
        # the whole perturbation on top of 1 L of pure water should be a small, positive number
        ρe_w25 = IFACE.ρₑ_w(25.0)[1]
        # Invert rho_e_w = AVOGADRO*10/(1e27*v) for v (in "1e-3 m3/mol" units
        # per PMV.jl's own comment on that line), then convert to cm3/mol:
        # 1e27*v is in A^3/mol, and 1 A^3 = 1e-24 cm3, so v0_water_cm3_per_mol
        # = (1e27*v) * 1e-24 = 1e3*v = AVOGADRO*10/(1e24*rho_e_w25).
        v0_water = AVOGADRO * 10 / (1e24 * ρe_w25)
        @test close_(v0_water, 18.0687; atol = 1e-3)  # textbook molar volume of water, ~18.07 cm3/mol

        n_water = 1000.0 / v0_water                    # mol water per 1 L reference volume
        baseline_volume = n_water * v0_water
        @test close_(baseline_volume, 1000.0; atol = 1e-9)

        _, v_tris, _ = IFACE.ϕ°("tris")
        _, v_nacl, _ = IFACE.ϕ°("sodium chloride")
        _, v_dtt,  _ = IFACE.ϕ°("1,4-disulfanylbutane-2,3-diol")
        Δv = 0.020 * v_tris + 0.150 * v_nacl + 0.001 * v_dtt   # mol of each, per 1 L

        @test Δv > 0.0
        @test Δv < 0.02 * baseline_volume    # buffer perturbs volume by well under 2%
        total_volume = baseline_volume + Δv
        @test close_(total_volume, 1004.4077; atol = 1e-2)
    end

    @testset "integration: a very dilute protein contributes a proportionally tiny volume increment" begin
        # 1 mg/mL lysozyme (a typical dilute SAXS concentration) in 1 L of the
        # buffer above: moles = mass / MW, using the same ~14313 Da MW as the
        # partial-specific-volume check above.
        _, v_lys, _ = IFACE.ϕ°(7.4, LYSOZYME)
        n_lys = 1.0 / 14313.0     # mol, for 1 g (1 mg/mL * 1000 mL) of protein
        Δv_protein = n_lys * v_lys
        @test 0.0 < Δv_protein < 1.0   # cm3 out of a ~1 L reference volume: tiny but nonzero
    end
end
