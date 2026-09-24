# SPDX-License-Identifier: LGPL-2.1-or-later

# Broad end-to-end integration test proving the whole pipeline built across
# this package composes correctly on real data: structure -> real PROPKA ->
# Ionization -> screened electrostatics -> (separately) real PDB2PQR
# hydrogenation -> the full seed_fitting/run_fitting NUTS chain. Every stage
# below calls the existing lower-level functions directly (LocalPathSource,
# resolve_structure, load_molecule, propka_pKas, Ionization,
# protein_cavity_electrostatics, resolve_hydrogens, forward_cache,
# seed_fitting, run_fitting) rather than any single convenience orchestrator,
# so this is genuinely exercising composition, not one already-tested wrapper
# function.
#
# Needs real network/subprocess access: CondaPkg-provisioned propka3 and
# pdb2pqr, same assumption as test_propka.jl/test_pdb2pqr.jl/
# test_structuresource.jl already make.

include(joinpath(@__DIR__, "testsetup.jl"))

using BayeSol.MolecularStructure: LocalPathSource, resolve_structure, load_molecule, propka_pKas, PropkaError,
    Ionization, resolve_hydrogens, PDB2PQRError, _store_dir,
    Molecule, Residues, n_atoms, elms, coords_cartesian
using BayeSol.Solvation: protein_cavity_electrostatics
using BayeSol.Fitting: Solute, Protein, NonBiological, seed_fitting, run_fitting, PROFILE
using BayeSol.Scattering: forward, forward_cache, ForwardCache
using Random

include(joinpath(@__DIR__, "..", "fixtures", "functions", "floatcompare.jl"))   # close_

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
# URLSource branches and for PROPKA's/PDB2PQR's own `.pka`/hydrogenated-`.pdb`
# outputs below, which this file explicitly manages/cleans).
const _FIXTURE_PATH = joinpath(@__DIR__, "..", "fixtures", "molecules", "1CRN-TEST.pdb")

# Crambin's sequence, read directly off 1CRN-TEST.pdb's own ATOM records (not
# from memory): `grep "^ATOM" 1CRN-TEST.pdb | awk '{print $6, $4}' | uniq`
# gives, for chain A residues 1-46 in order:
# THR THR CYS CYS PRO SER ILE VAL ALA ARG SER ASN PHE ASN VAL CYS ARG LEU PRO
# GLY THR PRO GLU ALA ILE CYS ALA THR TYR THR GLY CYS ILE ILE ILE PRO GLY ALA
# THR CYS PRO GLY ASP TYR ALA ASN
# which 3-letter -> 1-letter translates to the sequence below (getting this
# wrong would make the `dns`/ρₑ prior below nonsensical, per this task's own
# instructions, so it is derived from the fixture itself, not recalled).
const CRAMBIN_SEQ = "TTCCPSIVARSNFNVCRLPGTPEAICATYTGCIIIPGATCPGDYAN"

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
# bulk water, δρ1/c1 near CRYSOL's defaults).
const INTEG_ξ_TRUE = (0.334, 1.05, -0.05, 0.02, 1.01)
const INTEG_M_TRUE, INTEG_C_TRUE = 1.7, 0.3

function integ_synth_data(fw::ForwardCache)
    y = forward(fw, 1.0, 0.0, INTEG_ξ_TRUE[1],
        (INTEG_ξ_TRUE[2], INTEG_ξ_TRUE[3], INTEG_ξ_TRUE[4]), INTEG_ξ_TRUE[5])
    I_true = INTEG_M_TRUE .* y .+ INTEG_C_TRUE
    σ_exp = max.(abs.(I_true) .* 0.01, 1.0e-6)
    Random.seed!(0xC2A11234)
    I_exp = I_true .+ randn(length(I_true)) .* σ_exp
    return I_exp, σ_exp
end

"""
Every sample must obey ξ's structural domain (dns, δρ1, c1 > 0), same
physical-domain check test_sampler.jl's own `check_physical_domain` performs.
"""
function integ_check_physical_domain(samples)
    for ξ in samples
        @test length(ξ) == 5
        @test all(isfinite, ξ)
        @test ξ[1] > 0
        @test ξ[2] > 0
        @test ξ[5] > 0
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
    mol, residues = load_molecule(resolved_path)

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
    #   Test 1: structure -> fresh PROPKA -> Ionization(pH) -> electrostatics
    #------------------------------------------------------------------
    @testset "structure -> fresh PROPKA -> Ionization(pH) -> electrostatics" begin
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

        ion_7 = Ionization(residues, pKa_records, 7.0, 0.1)
        ion_5 = Ionization(residues, pKa_records, 5.0, 0.2)
        n = length(residues.resname)
        @test length(ion_7.charge) == n && length(ion_5.charge) == n

        touched = findall(i ->
            ion_7.charge[i] != 0.0 || ion_7.σ_charge[i] != 0.0 ||
            ion_5.charge[i] != 0.0 || ion_5.σ_charge[i] != 0.0, 1:n)
        # crambin (ASP/GLU/ARG/TYR present, per the sequence above) really
        # does have PROPKA-recognized ionizable groups -- a real, non-trivial
        # regression check on top of the plain non-empty-records check above.
        @test !isempty(touched)

        # At least one touched atom's (charge, σ_charge) must genuinely
        # differ between the two (pH, σ_pH) settings -- confirms the whole
        # chain from real PROPKA pKa's through Henderson-Hasselbalch is
        # actually pH-sensitive end-to-end, not just unit-testable with
        # synthetic pKa's.
        differs = any(touched) do i
            !close_(ion_7.charge[i], ion_5.charge[i]; atol = 1.0e-6) ||
            !close_(ion_7.σ_charge[i], ion_5.σ_charge[i]; atol = 1.0e-6)
        end
        @test differs

        μ_χ, σ_χ = protein_cavity_electrostatics(mol, residues, ion_7)
        @test isfinite(μ_χ)
        @test isfinite(σ_χ)
        @test σ_χ >= 0.0
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

        mol_h, residues_h = load_molecule(hyd_path)
        @test mol_h isa Molecule
        @test residues_h isa Residues

        n_h = n_atoms(mol_h)
        @test n_h > n_atoms(mol)   # hydrogens genuinely added
        @test any(e -> lowercase(e) == "h", elms(mol_h))

        cc_h = coords_cartesian(mol_h)
        @test size(cc_h) == (3, n_h)
        @test all(isfinite, cc_h)

        @test length(residues_h.resname)  == n_h
        @test length(residues_h.atomname) == n_h
        @test length(residues_h.resnum)   == n_h
        @test length(residues_h.chain)    == n_h

        # Key "do these two independently-built pieces agree on the
        # underlying structure" check: every *heavy* atom present in the
        # hydrogen-included structure must carry the same resname at the
        # same (chain, resnum, atomname) as the original heavy-atom-only.
        els_h = elms(mol_h)
        heavy_h_idx = findall(e -> lowercase(e) != "h", els_h)
        @test length(heavy_h_idx) == n_atoms(mol)   # same heavy-atom count

        orig_key(i) = (residues.chain[i], residues.resnum[i], residues.atomname[i])
        orig_map = Dict(orig_key(i) => residues.resname[i] for i in 1:n_atoms(mol))

        @test length(orig_map) == n_atoms(mol)   # keys are genuinely unique

        for i in heavy_h_idx
            key = (residues_h.chain[i], residues_h.resnum[i], residues_h.atomname[i])
            @test haskey(orig_map, key)
            @test orig_map[key] == residues_h.resname[i]
        end
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

        solutes = Solute[
            Protein(2.0e-4, 5.0e-6, CRAMBIN_SEQ),
            NonBiological(0.15, 0.001, "sodium chloride"),
        ]
        pH, σ_pH = 7.0, 0.1

        ionization = Ionization(residues, pKa_records, pH, σ_pH)
        μ_χ, σ_χ = protein_cavity_electrostatics(mol, residues, ionization)

        Random.seed!(0)   # reproducibility, not survival -- see run_fitting's z-space docstring
        seed = seed_fitting(fw, I_exp, σ_exp, pH, σ_pH, solutes; μ_χ = μ_χ, σ_χ = σ_χ)
        @test seed isa BayeSol.Fitting.Seed
        @test seed.fw === fw
        @test seed.ex == (I_exp, σ_exp)
        @test seed.ξ₀[1] > 0 && seed.ξ₀[2] > 0 && seed.ξ₀[5] > 0

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

    # Clean up this file's own store entries so a repeat run genuinely
    # re-exercises "fresh" PROPKA/pdb2pqr, rather than leaving state that
    # would make the freshness checks above silently pass on a stale cache
    # next time.
    rm(pka_path; force = true)
    rm(joinpath(_store_dir(), "1CRN-TEST_pH7.0.pdb"); force = true)

end
