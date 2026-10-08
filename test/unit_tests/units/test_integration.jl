# SPDX-License-Identifier: LGPL-2.1-or-later

# Broad end-to-end integration test proving the whole pipeline built across
# this package composes correctly on real data: structure -> real PROPKA ->
# (separately) real Pdb2pqr hydrogenation -> the full seed_fitting/run_fitting
# NUTS chain. Every stage below calls the existing lower-level functions
# directly (LocalPathSource, resolve_structure, load_molecule, propka_pKas,
# resolve_hydrogens, forward_cache,
# seed_fitting, run_fitting) rather than any single convenience orchestrator,
# so this is genuinely exercising composition, not one already-tested wrapper
# function.
#
# Needs real network/subprocess access: CondaPkg-provisioned propka3 and
# pdb2pqr, same assumption as test_propka.jl/test_pdb2pqr.jl/
# test_structuresource.jl already make.

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.MolecularStructure: LocalPathSource, resolve_structure, load_molecule, propka_pKas, PropkaError,
    resolve_hydrogens, Pdb2pqrError, _store_dir,
    Molecule, n_atoms, elms, coords_cartesian
using BAYSOL.Fitting: Solute, NonBiological, seed_fitting, run_fitting, PROFILE, Ξ
using ForwardDiff
using BAYSOL.Fitting: φ_max, DRO_BOUNDS
using BAYSOL.PhysicalConstants: DRO_UNIT
using StaticArrays: SVector
using BAYSOL.Scattering: forward_cache, ForwardCache
using Random

include(joinpath(@__DIR__, "..", "..", "utils", "floatcompare.jl"))   # close_

# ---------------------------------------------------------------------------
#                    fixture: the smallest real -TEST structure
# ---------------------------------------------------------------------------

# 1CRN-TEST.pdb (crambin, 46 residues, 327 heavy atoms, single chain "A") is
# the smallest fixture in test/fixtures/molecules/ -- picked to keep the
# real NUTS run below fast. It's already legacy .pdb, so LocalPathSource
# resolves it via pure passthrough (no local store write for the resolve
# step itself; the `_store_dir()`-based collision policy documented in
# StructureSource.jl's module docstring and MolecularStructure.jl's
# `_store_dir()` docstring only bites for the .cif-conversion/PDBIDSource/
# URLSource branches and for PROPKA's/Pdb2pqr's own `.pka`/hydrogenated-`.pdb`
# outputs below, which this file explicitly manages/cleans).
const _FIXTURE_PATH = joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "1CRN-TEST.pdb")

const _STANDARD_GROUPS = Set(["ASP", "GLU", "CYS", "TYR", "HIS", "LYS", "ARG", "N+", "C-"])

# Small q-grid/lMax/energy, matching test_sampler.jl's own small-scale wiring
# convention -- chosen to keep the real forward_cache + NUTS run on a
# 327-atom real structure fast, not to be physically comprehensive.
const INTEG_Q      = collect(range(0.0, 0.25; length = 8))
const INTEG_E      = 9000.0
const INTEG_LMAX   = 4
const INTEG_CHUNK  = UInt64(8)

# Ground truth used to generate synthetic "experimental" data, same pattern
# as test_sampler.jl's `synth_data` (physically plausible values: dns near
# bulk water, δρ₁ near CRYSOL's default, cavity water near bulk density).
# ξ = (ρₑ, δρ₁, δρ₂, δρ₃).
const INTEG_ξ_TRUE = (CRYSOL_SOLVENT_DENSITY, 1.05, -0.05, -0.55)
const INTEG_M_TRUE, INTEG_C_TRUE = 1.7, 0.3

function integ_synth_data(fw::ForwardCache)
    y = reference_intensity(fw, 1.0, 0.0, INTEG_ξ_TRUE[1], INTEG_ξ_TRUE[2:4])
    I_true = INTEG_M_TRUE .* y .+ INTEG_C_TRUE
    σ_exp = max.(abs.(I_true) .* 0.01, 1.0e-6)
    Random.seed!(0xC2A11234)
    I_exp = I_true .+ randn(length(I_true)) .* σ_exp
    return I_exp, σ_exp
end

"""
Every sample must obey ξ's structural domain (ρₑ > 0, δρ₁, δρ₂ ∈ [-10, 2],
δρ₃ ∈ [-ρₑ/DRO_UNIT, (φ_max - 1)ρₑ/DRO_UNIT], to ~1%), same
physical-domain check test_sampler.jl's own `check_physical_domain` performs.
"""
function integ_check_physical_domain(samples)
    for ξ in samples
        @test length(ξ) == 4
        @test all(isfinite, ξ)
        @test ξ[1] > 0
        @test DRO_BOUNDS[1] ≤ ξ[2] ≤ DRO_BOUNDS[2]
        @test DRO_BOUNDS[1] ≤ ξ[3] ≤ DRO_BOUNDS[2]
        @test -1.01 * ξ[1] / DRO_UNIT ≤ ξ[4] ≤ 1.01 * (φ_max - 1) * ξ[1] / DRO_UNIT
    end
end

@testset "Integration" begin

    # -----------------------------------------------------------------
    # shared setup: resolve the fixture, load the heavy-atom pair, and
    # run a genuinely fresh PROPKA pass once, reused by every test below
    # (mirrors this package's own real usage: one PROPKA run per structure).
    # -----------------------------------------------------------------
    @test isfile(_FIXTURE_PATH)
    resolved_path = resolve_structure(LocalPathSource(_FIXTURE_PATH))
    mol = load_molecule(resolved_path)

    # Force a fresh propka3 run: propka_pKas trusts a matching `.pka`
    # filename's presence outright with no re-verification (see
    # MolecularStructure._store_dir()'s docstring and Propka.jl's caching
    # behaviour), so a leftover file from a previous session/test would make
    # this "genuinely fresh" run silently a no-op cache hit instead.
    pka_path = joinpath(_store_dir(), "1CRN-TEST.pka")
    rm(pka_path; force = true)
    @test !isfile(pka_path)

    local pKa_records
    t_propka = @elapsed begin
        pKa_records = propka_pKas(_FIXTURE_PATH)
    end
    @info "propka3 (fresh) on 1CRN-TEST.pdb took $(round(t_propka; digits = 2))s"

    #------------------------------------------------------------------
    #   Test 1: structure -> fresh PROPKA
    #------------------------------------------------------------------
    @testset "structure -> fresh PROPKA" begin
        @test mol isa Molecule
        @test n_atoms(mol) == 327
        @test isfile(pka_path)   # propka3 really ran and produced real output

        @test !isempty(pKa_records)
        for r in pKa_records
            @test r.resname in _STANDARD_GROUPS
            if r.resname == "CYS"
                # Crambin has 6 CYS, all disulfide-bonded (3 S-S bridges);
                # PROPKA's real, documented convention for a disulfide-bonded
                # (non-titratable) CYS is the sentinel pKa 99.99, confirmed
                # by actually running propka3 on this fixture -- not a
                # plausible titratable-group value, so it's checked
                # separately rather than folded into the `0 < pKa < 20`
                # bound below.
                @test r.pKa == 99.99 || (0 < r.pKa < 20)
            else
                @test 0 < r.pKa < 20
            end
        end
    end

    #------------------------------------------------------------------
    #   Test 2: real resolve_hydrogens + load_molecule compose
    #------------------------------------------------------------------
    @testset "resolve_hydrogens + load_molecule compose" begin
        hyd_ph = 7.0
        hyd_out_path = joinpath(_store_dir(), "1CRN-TEST_pH$(hyd_ph).pdb")
        rm(hyd_out_path; force = true)   # force a fresh pdb2pqr run too

        t_pdb2pqr = @elapsed begin
            hyd_path = resolve_hydrogens(resolved_path, pKa_records, hyd_ph)
        end
        @info "pdb2pqr (fresh) on 1CRN-TEST.pdb took $(round(t_pdb2pqr; digits = 2))s"
        @test isfile(hyd_path)

        mol_h = load_molecule(hyd_path)
        @test mol_h isa Molecule

        n_h = n_atoms(mol_h)
        @test n_h > n_atoms(mol)   # hydrogens genuinely added
        @test any(e -> lowercase(e) == "h", elms(mol_h))

        cc_h = coords_cartesian(mol_h)
        @test size(cc_h) == (3, n_h)
        @test all(isfinite, cc_h)

        els_h = elms(mol_h)
        heavy_h_idx = findall(e -> lowercase(e) != "h", els_h)
        @test length(heavy_h_idx) == n_atoms(mol)   # same heavy-atom count
    end

    #------------------------------------------------------------------
    #   Test 3: full chain into a real (short) NUTS run
    #------------------------------------------------------------------
    @testset "forward_cache -> synthetic data -> seed_fitting -> run_fitting (real NUTS)" begin
        t_fw = @elapsed begin
            fw = forward_cache(mol, INTEG_Q, INTEG_LMAX, INTEG_E; chunk = INTEG_CHUNK)
        end
        @info "forward_cache on 1CRN-TEST (327 atoms) took $(round(t_fw; digits = 2))s"

        I_exp, σ_exp = integ_synth_data(fw)

        # buffer only: the measured protein is never a solute (see Fitting.Solute)
        solutes = Solute[NonBiological(0.15, 0.001, "sodium chloride")]
        pH, σ_pH = 7.0, 0.1

        Random.seed!(0)   # reproducibility, not survival -- see run_fitting's z-space docstring
        seed = seed_fitting(fw, I_exp, σ_exp, pH, σ_pH, solutes)
        @test seed isa BAYSOL.Fitting.Seed
        @test seed.fw === fw
        @test seed.wls.I_obs == I_exp
        ξ₀ = Ξ(seed.θ₀, seed.pr)
        @test ξ₀[1] > 0 && ξ₀[2] > 0

        n_samples, n_adapt = 20, 10
        local fit
        t_nuts = @elapsed begin
            fit = run_fitting(seed, n_samples, n_adapt; l = PROFILE())
        end
        samples, stats = fit.samples, fit.stats
        @info "run_fitting ($n_samples samples, $n_adapt adapt) took $(round(t_nuts; digits = 2))s"

        @test length(samples) == n_samples
        @test length(stats) == n_samples
        integ_check_physical_domain(samples)
    end

    #------------------------------------------------------------------
    #   Test 4: the MAP search's f-stop on a real structure
    #------------------------------------------------------------------
    @testset "MAP search on crambin: the f-stop finds the gradient-only mode with fewer evaluations" begin
        fw = forward_cache(mol, INTEG_Q, INTEG_LMAX, INTEG_E; chunk = INTEG_CHUNK)
        seed = seed_fitting(fw, integ_synth_data(fw)..., 7.0, 0.1, Solute[NonBiological(0.15, 0.001, "sodium chloride")])
        Random.seed!(3)
        sp_f = BAYSOL.Fitting._sampling_space(seed, PROFILE())
        Random.seed!(3)                                                  # the same starting points
        sp_g = BAYSOL.Fitting._sampling_space(seed, PROFILE(); f_abstol = 0.0, successive_f_tol = 1)
        nlp(sp, z) = BAYSOL.Fitting._neglogπ(z, sp.μ, sp.σ, seed, PROFILE(), BAYSOL.Fitting.EXCL_VOL_CORR_TOL)
        @test abs(nlp(sp_f, sp_f.ẑ) - nlp(sp_g, sp_g.ẑ)) < 1e-4          # same optimum, to 1e-4 nats
        @test sp_f.n_evals < sp_g.n_evals
        @test sp_f.n_ok == sp_g.n_ok && abs(sp_f.n_modes - sp_g.n_modes) ≤ 1
    end

    #------------------------------------------------------------------
    #   Test 5: the analytic profile-likelihood gradient on a real structure
    #------------------------------------------------------------------
    @testset "analytic ∂ℓ/∂ξ equals ForwardDiff through profiled_corrs (crambin, data that constrain ξ)" begin
        FITM = BAYSOL.Fitting
        q = collect(range(0.02, 0.30; length = 80))
        fw = forward_cache(mol, q, 8, INTEG_E; chunk = INTEG_CHUNK)
        y = reference_intensity(fw, INTEG_M_TRUE, INTEG_C_TRUE, INTEG_ξ_TRUE[1], INTEG_ξ_TRUE[2:4])
        σ = 0.01 .* abs.(y)
        Random.seed!(5)
        seed = seed_fitting(fw, y .+ σ .* randn(length(y)), σ, 7.0, 0.1, Solute[NonBiological(0.15, 0.001, "sodium chloride")])
        wls, tab = seed.wls, seed.c1tab
        steep = 0
        for x in (SVector(0.40, 1.0, 0.0, -1.0), SVector(0.30, 1.5, 0.5, -2.0), SVector(0.336, 1.05, -0.05, -0.55),
                  SVector(0.336, 0.2, 1.0, -2.5), SVector(0.34, 1.05, 0.6, 1.0))
            c1 = FITM.profiled_corrs(wls, x, fw; tables = tab, tol = 1e-10)[3]
            # (a) the formula: at one and the same c1 it is the ForwardDiff gradient of the fixed-c1 profile likelihood
            f_fix(z) = FITM.wls_prof_ll(FITM.wls_fit(BAYSOL.Scattering.model_intensity(
                BAYSOL.Scattering.intensity_terms(fw, z[1], (z[2], z[3], z[4]))...,
                BAYSOL.Scattering.excluded_volume_factor(tab.qvals, tab.r_m, c1)), wls))
            g_fix = ForwardDiff.gradient(f_fix, Vector(x))
            ll, g = FITM._profile_ll_grad(wls, x, fw, tab, 1e-10; c1 = c1)
            @test isapprox(ll, f_fix(Vector(x)); rtol = 1e-10)
            @test isapprox(g, g_fix; rtol = 1e-7, atol = 1e-10 * maximum(abs, g_fix))
            # (b) end to end: the search's own c1 differs from profiled_corrs' by rounding, and the gradient depends on
            #     c1 to first order, so the two agree only to that sensitivity
            f_ad(z) = FITM.wls_prof_ll(FITM.profiled_corrs(wls, SVector{4}(z...), fw; tables = tab, tol = 1e-10)[2])
            g_ad = ForwardDiff.gradient(f_ad, Vector(x))
            _, g2 = FITM._profile_ll_grad(wls, x, fw, tab, 1e-10)
            @test isapprox(g2, g_ad; rtol = 0.05, atol = 0.02 * maximum(abs, g_ad))
            steep += maximum(abs, g_ad) > 0.1
        end
        @test steep ≥ 3                                  # the comparison is not between noise-level gradients
    end

    # Clean up this file's own store entries so a repeat run genuinely
    # re-exercises "fresh" PROPKA/pdb2pqr, rather than leaving state that
    # would make the freshness checks above silently pass on a stale cache
    # next time.
    rm(pka_path; force = true)
    rm(joinpath(_store_dir(), "1CRN-TEST_pH7.0.pdb"); force = true)

end
