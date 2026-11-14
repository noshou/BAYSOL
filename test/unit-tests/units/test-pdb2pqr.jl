# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/hydrogenator/pdb2pqr.jl: the pdb2pqr subprocess wrapper
# that adds explicit hydrogens (`resolveHydrogens`), its pKa-record-driven,
# per-chain N-/C-terminus override (`_terminusGroups`), and the generalized
# Molecule loader (`loadMolecule`). Needs real network/subprocess
# access for CondaPkg to provision `pdb2pqr` on first use, same assumption as
# the live propka3 test in test-propka.jl.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.Hydrogenator: resolveHydrogens, Pdb2pqrError, Propka, NoTitration,
    FORCE_FIELDS, _terminusGroups, propkaPkas, _hydrogensPath
using BAYSOL.MolecularStructure: loadMolecule, MoleculeError, _storeDir,
    LocalPathSource, resloveStruct,
    Molecule, nAtoms, elms, coordsCartesian

# A 7-"residue" fragment (not a real contiguous chain -- each residue's real
# coordinates are lifted from unrelated, spatially distant positions in 7RSA,
# same technique test-propka.jl uses for its own fixture), covering one of
# each residue type this task must exercise real pdb2pqr atom-naming for:
# LYS (also the free N-terminus, residue 1), GLU, ARG, ASP, HIS, TYR, and VAL
# (also the free C-terminus, last residue). Real bond lengths/angles within
# each residue (lifted straight off 7RSA-TEST.pdb, heavy atoms only), so both
# PROPKA and pdb2pqr see physically valid local geometry.
const _TEST_PDB = """
ATOM      1  N   LYS A   1      17.208  26.496  -2.120  1.00 23.56           N
ATOM      2  CA  LYS A   1      17.586  25.166  -1.492  1.00 21.72           C
ATOM      3  C   LYS A   1      18.376  25.526  -0.224  1.00 17.32           C
ATOM      4  O   LYS A   1      18.800  26.649  -0.055  1.00 16.89           O
ATOM      5  CB  LYS A   1      18.268  24.389  -2.543  1.00 27.53           C
ATOM      6  CG  LYS A   1      19.133  23.202  -2.442  1.00 33.17           C
ATOM      7  CD  LYS A   1      19.271  22.450  -3.786  1.00 37.31           C
ATOM      8  CE  LYS A   1      19.911  21.079  -3.701  1.00 39.40           C
ATOM      9  NZ  LYS A   1      19.031  19.957  -3.304  1.00 40.47           N
ATOM     10  N   GLU A   2      24.602  23.358  10.360  1.00  7.10           N
ATOM     11  CA  GLU A   2      23.875  23.417  11.595  1.00  7.85           C
ATOM     12  C   GLU A   2      23.035  22.159  11.803  1.00  8.11           C
ATOM     13  O   GLU A   2      22.986  21.565  12.880  1.00  8.42           O
ATOM     14  CB  GLU A   2      22.980  24.601  11.795  1.00 10.56           C
ATOM     15  CG  GLU A   2      23.673  25.913  11.790  1.00 14.00           C
ATOM     16  CD  GLU A   2      22.824  27.157  12.014  1.00 17.53           C
ATOM     17  OE1 GLU A   2      23.294  28.213  11.509  1.00 19.71           O
ATOM     18  OE2 GLU A   2      21.777  26.903  12.766  1.00 18.71           O
ATOM     19  N   ARG A   3      22.299  21.779  10.733  1.00  7.12           N
ATOM     20  CA  ARG A   3      21.453  20.602  10.796  1.00  7.81           C
ATOM     21  C   ARG A   3      22.214  19.305  11.033  1.00  7.06           C
ATOM     22  O   ARG A   3      21.791  18.446  11.789  1.00  7.60           O
ATOM     23  CB  ARG A   3      20.582  20.491   9.498  1.00  7.68           C
ATOM     24  CG  ARG A   3      19.641  19.279   9.461  1.00  8.35           C
ATOM     25  CD  ARG A   3      18.701  19.356   8.280  1.00  9.90           C
ATOM     26  NE  ARG A   3      19.389  19.406   7.002  1.00 11.02           N
ATOM     27  CZ  ARG A   3      19.810  18.395   6.314  1.00 13.78           C
ATOM     28  NH1 ARG A   3      19.731  17.119   6.766  1.00 15.63           N
ATOM     29  NH2 ARG A   3      20.426  18.535   5.177  1.00 15.05           N
ATOM     30  N   ASP A   4      24.329  20.459  18.115  1.00  8.07           N
ATOM     31  CA  ASP A   4      23.344  20.093  19.090  1.00  9.03           C
ATOM     32  C   ASP A   4      23.661  20.886  20.395  1.00  9.01           C
ATOM     33  O   ASP A   4      24.159  20.357  21.349  1.00 10.31           O
ATOM     34  CB  ASP A   4      23.181  18.611  19.347  1.00  9.96           C
ATOM     35  CG  ASP A   4      22.012  18.416  20.335  1.00 11.19           C
ATOM     36  OD1 ASP A   4      21.225  19.303  20.581  1.00 11.23           O
ATOM     37  OD2 ASP A   4      22.005  17.225  20.835  1.00 12.91           O
ATOM     38  N   HIS A   5      25.409  18.956  12.227  1.00  7.46           N
ATOM     39  CA  HIS A   5      26.447  18.922  13.244  1.00  8.30           C
ATOM     40  C   HIS A   5      26.154  19.594  14.545  1.00  9.12           C
ATOM     41  O   HIS A   5      26.957  19.353  15.478  1.00 11.15           O
ATOM     42  CB  HIS A   5      27.780  19.415  12.673  1.00  8.14           C
ATOM     43  CG  HIS A   5      28.264  18.701  11.439  1.00  7.84           C
ATOM     44  ND1 HIS A   5      28.652  17.372  11.529  1.00  8.55           N
ATOM     45  CD2 HIS A   5      28.363  19.107  10.149  1.00  9.41           C
ATOM     46  CE1 HIS A   5      28.956  17.017  10.277  1.00  9.03           C
ATOM     47  NE2 HIS A   5      28.813  18.031   9.434  1.00  9.11           N
ATOM     48  N   TYR A   6      21.447   7.907  21.507  1.00  8.79           N
ATOM     49  CA  TYR A   6      21.563   9.292  21.001  1.00  9.10           C
ATOM     50  C   TYR A   6      21.753   9.343  19.494  1.00  8.84           C
ATOM     51  O   TYR A   6      21.023  10.063  18.781  1.00  9.02           O
ATOM     52  CB  TYR A   6      22.660  10.039  21.790  1.00  8.97           C
ATOM     53  CG  TYR A   6      22.883  11.445  21.303  1.00  9.11           C
ATOM     54  CD1 TYR A   6      22.139  12.521  21.821  1.00  9.78           C
ATOM     55  CD2 TYR A   6      23.772  11.705  20.248  1.00  9.19           C
ATOM     56  CE1 TYR A   6      22.355  13.834  21.335  1.00  9.73           C
ATOM     57  CE2 TYR A   6      23.969  13.000  19.762  1.00  9.66           C
ATOM     58  CZ  TYR A   6      23.247  14.020  20.299  1.00  8.73           C
ATOM     59  OH  TYR A   6      23.459  15.292  19.765  1.00  9.89           O
ATOM     60  N   VAL A   7      40.342  16.340  16.587  1.00 16.09           N
ATOM     61  CA  VAL A   7      41.740  15.965  16.948  1.00 17.88           C
ATOM     62  C   VAL A   7      41.922  16.191  18.440  1.00 20.04           C
ATOM     63  O   VAL A   7      42.843  15.448  18.971  1.00 22.34           O
ATOM     64  CB  VAL A   7      42.762  16.713  16.059  1.00 17.92           C
ATOM     65  CG1 VAL A   7      42.668  16.292  14.591  1.00 17.93           C
ATOM     66  CG2 VAL A   7      42.703  18.191  16.159  1.00 18.00           C
ATOM     67  OXT VAL A   7      41.303  16.985  19.124  1.00 18.14           O
TER      68      VAL A   7
END
"""

# Real pKa values PROPKA predicts for this fragment (obtained empirically
# while writing this test, via `propkaPkas` on the fixture above): N+ ~8.00,
# C- ~3.03. These drive which of the two termini test pH values below trigger
# which flag, via `_groupProtonated`'s own Henderson-Hasselbalch rounding:
# at pH 1 (< C-'s pKa, > N+'s pKa) the acid group is
# protonated/neutral (--neutralc) and the base group is protonated/charged
# (pdb2pqr's own default, no flag); at pH 10 (> both pKas) the base group is
# deprotonated/neutral (--neutraln) and the acid group is deprotonated/
# charged (pdb2pqr's own default, no flag).

atomNames(lines, resname, resnum) = Set(
    strip(l[13:16]) for l in lines
    if length(l) ≥ 26 && startswith(l, "ATOM") &&
        strip(l[18:20]) == resname && parse(Int, strip(l[23:26])) == resnum
)

# Two chains, each a 2-residue fragment (A: LYS/VAL, B: ASP/TYR), placed far
# apart so they don't interact. Used by the "real multi-chain terminus
# conflict" test below: their C-termini's real propka pKa values (3.03 vs.
# 3.20, found empirically) straddle pH=3.1, giving a genuine per-chain
# --neutralc conflict -- exactly the case that used to make _terminus_flags
# throw, now resolved by _terminusGroups + resolveHydrogens's per-group
# pdb2pqr runs.
const _TWO_CHAIN_PDB = """
ATOM      1  N   LYS A   1      17.208  26.496  -2.120  1.00 23.56           N
ATOM      2  CA  LYS A   1      17.586  25.166  -1.492  1.00 21.72           C
ATOM      3  C   LYS A   1      18.376  25.526  -0.224  1.00 17.32           C
ATOM      4  O   LYS A   1      18.800  26.649  -0.055  1.00 16.89           O
ATOM      5  CB  LYS A   1      18.268  24.389  -2.543  1.00 27.53           C
ATOM      6  CG  LYS A   1      19.133  23.202  -2.442  1.00 33.17           C
ATOM      7  CD  LYS A   1      19.271  22.450  -3.786  1.00 37.31           C
ATOM      8  CE  LYS A   1      19.911  21.079  -3.701  1.00 39.40           C
ATOM      9  NZ  LYS A   1      19.031  19.957  -3.304  1.00 40.47           N
ATOM     10  N   VAL A   2      40.342  16.340  16.587  1.00 16.09           N
ATOM     11  CA  VAL A   2      41.740  15.965  16.948  1.00 17.88           C
ATOM     12  C   VAL A   2      41.922  16.191  18.440  1.00 20.04           C
ATOM     13  O   VAL A   2      42.843  15.448  18.971  1.00 22.34           O
ATOM     14  CB  VAL A   2      42.762  16.713  16.059  1.00 17.92           C
ATOM     15  CG1 VAL A   2      42.668  16.292  14.591  1.00 17.93           C
ATOM     16  CG2 VAL A   2      42.703  18.191  16.159  1.00 18.00           C
ATOM     17  OXT VAL A   2      41.303  16.985  19.124  1.00 18.14           O
TER      18      VAL A   2
ATOM     19  N   ASP B   1      67.208  26.496  -2.120  1.00 23.56           N
ATOM     20  CA  ASP B   1      67.586  25.166  -1.492  1.00 21.72           C
ATOM     21  C   ASP B   1      68.376  25.526  -0.224  1.00 17.32           C
ATOM     22  O   ASP B   1      68.800  26.649  -0.055  1.00 16.89           O
ATOM     23  CB  ASP B   1      68.268  24.389  -2.543  1.00 27.53           C
ATOM     24  CG  ASP B   1      69.133  23.202  -2.442  1.00 33.17           C
ATOM     25  OD1 ASP B   1      69.271  22.450  -3.786  1.00 37.31           O
ATOM     26  OD2 ASP B   1      69.911  21.079  -3.701  1.00 39.40           O
ATOM     27  N   TYR B   2      90.342  16.340  16.587  1.00 16.09           N
ATOM     28  CA  TYR B   2      91.563   9.292  21.001  1.00  9.10           C
ATOM     29  C   TYR B   2      91.753   9.343  19.494  1.00  8.84           C
ATOM     30  O   TYR B   2      91.023  10.063  18.781  1.00  9.02           O
ATOM     31  CB  TYR B   2      92.660  10.039  21.790  1.00  8.97           C
ATOM     32  CG  TYR B   2      92.883  11.445  21.303  1.00  9.11           C
ATOM     33  CD1 TYR B   2      92.139  12.521  21.821  1.00  9.78           C
ATOM     34  CD2 TYR B   2      93.772  11.705  20.248  1.00  9.19           C
ATOM     35  CE1 TYR B   2      92.355  13.834  21.335  1.00  9.73           C
ATOM     36  CE2 TYR B   2      93.969  13.000  19.762  1.00  9.66           C
ATOM     37  CZ  TYR B   2      93.247  14.020  20.299  1.00  8.73           C
ATOM     38  OH  TYR B   2      93.459  15.292  19.765  1.00  9.89           O
ATOM     39  OXT TYR B   2      91.303  16.985  19.124  1.00 18.14           O
TER      40      TYR B   2
END
"""

@testset "Pdb2pqr" begin

    dir = mktempdir()
    pdbPath = joinpath(dir, "pdb2pqr-TEST.pdb")
    write(pdbPath, _TEST_PDB)

    # Clean any stale cache entries from a prior run so caching assertions
    # below are meaningful.
    for pH in (1.0, 7.0, 10.0)
        rm(joinpath(_storeDir(), "pdb2pqr-TEST_pH$(pH)_parse_propka.pdb"); force = true)
    end

    local recs
    try
        recs = propkaPkas(pdbPath)
    catch e
        rm(dir; force = true, recursive = true)
        rethrow(e)
    end

    nterm = only(filter(r -> r.resname == "N+", recs))
    cterm = only(filter(r -> r.resname == "C-", recs))
    @test 0 < nterm.pKa < 14
    @test 0 < cterm.pKa < 14

    @testset "nonexistent input raises Pdb2pqrError" begin
        @test_throws Pdb2pqrError resolveHydrogens(
            "/no/such/file/nope.pdb",
            7.0;
            titration = Propka(recs),
        )
    end

    @testset "termini flags computed per chain from pKa records" begin
        # Single-chain fixture -> _terminusGroups always returns one group
        # covering chain "A", same flags _terminus_flags used to compute.
        # pH 1: below C-'s pKa (neutral/protonated acid -> --neutralc),
        # above N+'s pKa (protonated/charged base -> no flag).
        @test _terminusGroups(recs, 1.0, ["A"]) == Dict(["--neutralc"] => ["A"])
        # pH 10: above both pKas (deprotonated base -> --neutraln;
        # deprotonated/charged acid -> no flag).
        @test _terminusGroups(recs, 10.0, ["A"]) == Dict(["--neutraln"] => ["A"])
        # pH 7: below neither in a way that flips either from pdb2pqr's own
        # default in this fragment's case (N+ pKa ~8 -> still protonated;
        # C- pKa ~3 -> still deprotonated) -> no flags at all, one group.
        @test _terminusGroups(recs, 7.0, ["A"]) == Dict(String[] => ["A"])
    end

    @testset "_terminusGroups: conflicting chains partition instead of colliding" begin
        # Synthetic multi-chain pKa records (not run through real propka/
        # pdb2pqr -- this is a pure unit test of the partitioning logic,
        # since a real multi-chain structure with genuinely PROPKA-computed
        # conflicting termini isn't practical to construct deterministically
        # in a small synthetic fixture: real inter-chain electrostatic
        # perturbation is needed to actually split two termini of the same
        # residue type, which is what resolveHydrogens's per-group runs
        # are for). At pH 7:
        #   chain A: N+ pKa=5 (pH > pKa -> mostly deprotonated -> neutral
        #     base -> --neutraln); C- pKa=3 (pH > pKa -> mostly deprotonated
        #     -> charged acid -> no flag).
        #   chain B: N+ pKa=9 (pH < pKa -> mostly protonated -> charged base
        #     -> no flag); C- pKa=10 (pH < pKa -> mostly protonated ->
        #     neutral acid -> --neutralc).
        # This is exactly the shape of conflict that used to make
        # _terminus_flags throw (a single global run can't give chain A
        # --neutraln and chain B --neutralc at once); _terminusGroups
        # instead partitions them into two distinct flag groups.
        recs2 = [
            (resname = "N+", resnum = 1, chain = "A", pKa = 5.0),
            (resname = "N+", resnum = 1, chain = "B", pKa = 9.0),
            (resname = "C-", resnum = 99, chain = "A", pKa = 3.0),
            (resname = "C-", resnum = 99, chain = "B", pKa = 10.0),
        ]
        groups = _terminusGroups(recs2, 7.0, ["A", "B"])
        @test groups == Dict(["--neutraln"] => ["A"], ["--neutralc"] => ["B"])

        # A chain with no N+/C- record at all (e.g. no free terminus) needs
        # no override and lands in the empty-flags group alongside any
        # other such chain, without forcing a conflict.
        groups3 = _terminusGroups(recs2, 7.0, ["A", "B", "C"])
        @test groups3[String[]] == ["C"]
    end

    # …confirmed atom names
    @testset "resolveHydrogens at pH 1: neutral (protonated) C-terminus" begin
        out = resolveHydrogens(pdbPath, 1.0; titration = Propka(recs))
        @test isfile(out)
        @test dirname(out) == _storeDir()
        lines = readlines(out)

        # Confirmed real pdb2pqr atom names (see task research notes):
        @test atomNames(lines, "ASP", 4) ⊇ Set(["HD2"])
        @test atomNames(lines, "GLU", 2) ⊇ Set(["HE2"])
        # His at low pH: both ring CH hydrogens plus both titratable ones
        # (doubly-protonated imidazolium at pH well below its ~6.5 pKa).
        @test atomNames(lines, "HIS", 5) ⊇ Set(["HD1", "HD2", "HE1", "HE2"])
        @test atomNames(lines, "LYS", 1) ⊇ Set(["HZ1", "HZ2", "HZ3"])
        @test atomNames(lines, "ARG", 3) ⊇ Set(["HE", "HH11", "HH12", "HH21", "HH22"])
        @test atomNames(lines, "TYR", 6) ⊇ Set(["HH"])

        # Free N-terminus (LYS 1) charged/protonated at pH 1 (pdb2pqr's own
        # default; no --neutraln issued at this pH): three amine hydrogens.
        @test atomNames(lines, "LYS", 1) ⊇ Set(["H", "H2", "H3"])

        # Free C-terminus (VAL 7) neutral/protonated via --neutralc: gains an
        # "HO" hydrogen (confirmed empirically) not present in the pH-7 case.
        @test "HO" in atomNames(lines, "VAL", 7)
    end

    @testset "resolveHydrogens at pH 10: neutral (deprotonated) N-terminus" begin
        out = resolveHydrogens(pdbPath, 10.0; titration = Propka(recs))
        @test isfile(out)
        lines = readlines(out)

        # --neutraln issued automatically: only two amine hydrogens (H, H2),
        # not the three ("H","H2","H3") a charged N-terminus carries.
        ntermNames = atomNames(lines, "LYS", 1)
        @test "H" in ntermNames && "H2" in ntermNames
        @test !("H3" in ntermNames)

        # C-terminus stays at pdb2pqr's own default (charged/deprotonated,
        # no --neutralc at this pH): no "HO".
        @test !("HO" in atomNames(lines, "VAL", 7))
    end

    @testset "caching: repeat call for the same (stem, pH) does not re-run pdb2pqr" begin
        out1 = resolveHydrogens(pdbPath, 7.0; titration = Propka(recs))
        @test isfile(out1)
        mtime1 = mtime(out1)

        sleep(1.1)   # coarse mtime resolution on some filesystems
        out2 = resolveHydrogens(pdbPath, 7.0; titration = Propka(recs))
        @test out2 == out1
        @test mtime(out2) == mtime1   # untouched: cache hit, no re-run
    end

    @testset "loadMolecule: more atoms than heavy-only, no non-finite coords" begin
        out = resolveHydrogens(pdbPath, 7.0; titration = Propka(recs))
        mol = loadMolecule(out)
        @test mol isa Molecule

        n = nAtoms(mol)
        nHeavy = count(l -> startswith(l, "ATOM"), split(_TEST_PDB, '\n'))
        @test n > nHeavy   # hydrogens were actually added
        @test any(e -> lowercase(e) == "h", elms(mol))   # hydrogens present

        cc = coordsCartesian(mol)
        @test size(cc) == (3, n)
        @test all(isfinite, cc)
    end

    @testset "loadMolecule: nonexistent input raises MoleculeError" begin
        @test_throws MoleculeError loadMolecule("/no/such/file/nope.pdb")
    end

    rm(dir; force = true, recursive = true)
    for pH in (1.0, 7.0, 10.0)
        rm(joinpath(_storeDir(), "pdb2pqr-TEST_pH$(pH)_parse_propka.pdb"); force = true)
    end
    rm(joinpath(_storeDir(), "pdb2pqr-TEST.pka"); force = true)

    # -------------------------------------------------------------------
    # Real end-to-end multi-chain conflict: two chains whose C-termini
    # genuinely round to different protonation states under real propka,
    # exercising resolveHydrogens's per-group pdb2pqr + merge path (not
    # just _terminusGroups's partitioning logic in isolation above).
    # Found empirically: two isolated 2-residue chains (A: LYS/VAL,
    # B: ASP/TYR) give C- pKa 3.03 (chain A) vs. 3.20 (chain B) under real
    # propka -- close enough that pH=3.1 sits between them, so chain A's
    # C-terminus rounds charged (pH > 3.03) while chain B's rounds neutral
    # (pH < 3.20). This used to be exactly the case _terminus_flags threw
    # on; resolveHydrogens must now succeed and hydrogenate each chain's
    # terminus correctly. (_TWO_CHAIN_PDB is defined at file scope above,
    # next to _TEST_PDB.)

    dir2 = mktempdir()
    pdbPath2 = joinpath(dir2, "pdb2pqr-TWOCHAIN.pdb")
    write(pdbPath2, _TWO_CHAIN_PDB)
    rm(joinpath(_storeDir(), "pdb2pqr-TWOCHAIN_pH3.1_parse_propka.pdb"); force = true)

    local recs2
    try
        recs2 = propkaPkas(pdbPath2)
    catch e
        rm(dir2; force = true, recursive = true)
        rethrow(e)
    end

    # …per-chain
    @testset "resolveHydrogens: real multi-chain terminus conflict resolves" begin
        aCminus = only(r for r in recs2 if r.resname == "C-" && r.chain == "A")
        bCminus = only(r for r in recs2 if r.resname == "C-" && r.chain == "B")
        # Sanity check the empirically-found split still holds for this
        # fixture/propka version; if it drifts, this test's premise (a real
        # conflict at pH=3.1) no longer holds and needs a new pH/fixture.
        @test aCminus.pKa < 3.1 < bCminus.pKa

        groups = _terminusGroups(recs2, 3.1, ["A", "B"])
        @test length(groups) == 2   # genuine per-chain conflict, not collapsed to one run

        out = resolveHydrogens(pdbPath2, 3.1; titration = Propka(recs2))
        @test isfile(out)
        lines = readlines(out)

        # Chain A's C-terminus (VAL 2) rounds charged/deprotonated at
        # pH=3.1 (pH > its own pKa 3.03) -- no --neutralc, no "HO".
        @test !("HO" in atomNames(lines, "VAL", 2))
        # Chain B's C-terminus (TYR 2) rounds neutral/protonated (pH < its
        # own pKa 3.20) -- --neutralc applied, gains "HO".
        @test "HO" in atomNames(lines, "TYR", 2)

        # Both chains' free N-termini (pKa 8.0 for both, well above pH=3.1
        # -> protonated/charged, pdb2pqr's own default, no --neutraln
        # needed for either) still got hydrogenated normally.
        @test atomNames(lines, "LYS", 1) ⊇ Set(["H", "H2", "H3"])
        @test atomNames(lines, "ASP", 1) ⊇ Set(["H", "H2", "H3"])
    end

    rm(dir2; force = true, recursive = true)
    rm(joinpath(_storeDir(), "pdb2pqr-TWOCHAIN_pH3.1_parse_propka.pdb"); force = true)
    rm(joinpath(_storeDir(), "pdb2pqr-TWOCHAIN.pka"); force = true)

end

@testset "Pdb2pqr: waters with an oxygen named O1 (old crystal files)" begin
    # pdb2pqr's water optimisation raises "Unable to find oxygen atom in HOH" for an
    # oxygen not named O/OW; the hydrogenation step removes the waters first
    dir = mktempdir()
    try
        rec(n, name, res, num, xyz, el) = string(
            "ATOM  ", lpad(n, 5), " ", rpad(name, 4), " ", res, " A", lpad(num, 4),
            "    ",
            xyz, "  1.00 20.00          ", lpad(el, 2),
        )
        ala = [
            rec(1, " N  ", "ALA", 1, " 17.208  26.496  -2.120", "N"),
            rec(2, " CA ", "ALA", 1, " 17.586  25.166  -1.492", "C"),
            rec(3, " C  ", "ALA", 1, " 18.376  25.526  -0.224", "C"),
            rec(4, " O  ", "ALA", 1, " 18.800  26.649  -0.055", "O"),
            rec(5, " CB ", "ALA", 1, " 18.268  24.389  -2.543", "C"),
        ]
        wat = rec(6, " O1 ", "HOH", 602, " 25.000  25.000  -1.000", "O")
        path = joinpath(dir, "pdb2pqr-WAT.pdb")
        write(path, join([ala; wat; "END"], "\n") * "\n")
        rm(_hydrogensPath(path, 7.0, :parse, NoTitration()); force = true)
        out = resolveHydrogens(path, 7.0; titration = NoTitration())
        lines = readlines(out)
        @test isfile(out)
        @test !any(l -> occursin("HOH", l), lines)
        @test any(
            l -> startswith(l, "ATOM") && l[18:20] == "ALA" && l[13:16] == " HA ",
            lines,
        )
    finally
        rm(dir; recursive = true, force = true)
    end
end

@testset "Hydrogenator: force field and titration method are choices" begin

    @testset "an unknown force field raises Pdb2pqrError before any run" begin
        f = joinpath(mktempdir(), "ff-TEST.pdb")
        write(f, _TEST_PDB)
        @test_throws Pdb2pqrError resolveHydrogens(f, 7.0; ff = :gromos)
    end

    @testset "the cache key separates force field and titration method" begin
        paths = [
            _hydrogensPath("x.pdb", 7.0, ff, t)
            for ff in (:parse, :amber), t in (Propka(), NoTitration())
        ]
        @test allunique(paths)
        @test all(p -> dirname(p) == _storeDir(), paths)
        @test endswith(
            _hydrogensPath("x.pdb", 7.0, :amber, NoTitration()),
            "x_pH7.0_amber_notitration.pdb",
        )
        # the knob PROPKA is not implied: pKas are optional, the default needs none
        @test Propka().pKas === nothing
        @test :amber in FORCE_FIELDS && :parse in FORCE_FIELDS
    end

    @testset "AMBER without titration hydrogenates a B-DNA duplex (no PROPKA)" begin
        fix = joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "1BNA-TEST.pdb")
        path = resloveStruct(LocalPathSource(fix))
        out = _hydrogensPath(path, 7.0, :amber, NoTitration())
        rm(out; force = true)
        try
            hpath = resolveHydrogens(path, 7.0; ff = :amber)
            @test hpath == out
            @test isfile(hpath)
            heavy = nAtoms(loadMolecule(path))
            @test nAtoms(loadMolecule(hpath)) > heavy
            # no PROPKA run happened for this structure
            @test !isfile(joinpath(_storeDir(), "1BNA-TEST.pka"))
        finally
            rm(out; force = true)
        end
    end
end
