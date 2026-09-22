# SPDX-License-Identifier: LGPL-2.1-or-later

# Exercises src/MolecularStructure/StructureSource.jl: resolving a local path,
# a bare RCSB PDB ID, or a URL into a canonical, cached .pdb, and loading that
# into a Molecule/Residues pair. The PDB-ID and URL branches need real network
# access (RCSB / files.rcsb.org), same assumption as the live propka3 test in
# test_propka.jl.
include(joinpath(@__DIR__, "testsetup.jl"))

using BayeSol.MolecularStructure: StructureSource, LocalPathSource, PDBIDSource, URLSource,
                    StructureSourceError, resolve_structure, load_molecule,
                    Molecule, Residues, n_atoms, elms, coords_cartesian, _store_dir
using BioStructures: BioStructures, MMCIFFormat, writepdb, standardselector, heavyatomselector

include(joinpath(@__DIR__, "..", "fixtures", "functions", "floatcompare.jl"))   # close_

# Real, curated PDB structures checked into test/fixtures/molecules/, spanning
# a genuine size range and mixing .pdb/.cif so both LocalPathSource branches
# get exercised on real data (see test/fixtures/README.md for the full table).
# Filenames carry a "-TEST" suffix (not the bare RCSB ID) so LocalPathSource's
# filename-stem cache key can never plausibly collide with a real user's own
# local file under the fail-loud collision policy.
# Every (chain, resname, resnum, atomname) spot-check value below was read off
# the actual downloaded file with BioStructures directly (not from memory),
# then cross-checked against the well-known sequence of each protein.
const _FIXTURE_DIR = joinpath(@__DIR__, "..", "fixtures", "molecules")

# id => (filename, tier, n_heavy_atoms, Dict(chain => (first_resnum, first_resname, last_resnum, last_resname)))
const _FIXTURES = Dict(
    "1CRN" => ("1CRN-TEST.pdb", :small,  327,
        Dict("A" => (1, "THR", 46, "ASN"))),
    "1UBQ" => ("1UBQ-TEST.cif", :small,  602,
        Dict("A" => (1, "MET", 76, "GLY"))),
    "6PTI" => ("6PTI-TEST.pdb", :small,  445,
        Dict("A" => (1, "ARG", 57, "GLY"))),
    "1ZNI" => ("1ZNI-TEST.cif", :small,  806,
        Dict("A" => (1, "GLY", 21, "ASN"), "B" => (1, "PHE", 30, "ALA"),
             "C" => (1, "GLY", 21, "ASN"), "D" => (1, "PHE", 30, "ALA"))),
    "6LYZ" => ("6LYZ-TEST.cif", :medium, 1001,
        Dict("A" => (1, "LYS", 129, "LEU"))),
    "7RSA" => ("7RSA-TEST.pdb", :medium, 951,
        Dict("A" => (1, "LYS", 124, "VAL"))),
    "1MBN" => ("1MBN-TEST.cif", :medium, 1216,
        Dict("A" => (1, "VAL", 153, "GLY"))),
    "4HHB" => ("4HHB-TEST.pdb", :large,  4384,
        Dict("A" => (1, "VAL", 141, "ARG"), "B" => (1, "VAL", 146, "HIS"),
             "C" => (1, "VAL", 141, "ARG"), "D" => (1, "VAL", 146, "HIS"))),
    "1FBI" => ("1FBI-TEST.cif", :large,  8521,
        Dict("H" => (1, "GLN", 221, "PRO"), "L" => (1, "ASP", 214, "CYS"),
             "P" => (1, "ASP", 214, "CYS"), "Q" => (1, "GLN", 221, "PRO"),
             "X" => (1, "LYS", 129, "LEU"), "Y" => (1, "LYS", 129, "LEU"))),
    "1IGT" => ("1IGT-TEST.pdb", :large,  10214,
        Dict("A" => (1, "ASP", 214, "CYS"), "B" => (1, "GLU", 474, "ARG"),
             "C" => (1, "ASP", 214, "CYS"), "D" => (1, "GLU", 474, "ARG"))),
)

# A tiny single-chain mmCIF fixture: one GLY residue (4 heavy atoms + 1 H) in
# chain "A", plus a HETATM water in chain "B" -- both the H and the water must
# be dropped by the standardselector/heavyatomselector filtering.
const _TEST_CIF = """
data_TESTSM
loop_
_atom_site.group_PDB
_atom_site.id
_atom_site.type_symbol
_atom_site.label_atom_id
_atom_site.label_comp_id
_atom_site.label_asym_id
_atom_site.label_seq_id
_atom_site.Cartn_x
_atom_site.Cartn_y
_atom_site.Cartn_z
_atom_site.occupancy
_atom_site.B_iso_or_equiv
_atom_site.auth_seq_id
_atom_site.auth_asym_id
_atom_site.pdbx_PDB_model_num
ATOM 1 N N GLY A 1 1.000 2.000 3.000 1.00 10.00 1 A 1
ATOM 2 C CA GLY A 1 4.000 5.000 6.000 1.00 10.00 1 A 1
ATOM 3 C C GLY A 1 7.000 8.000 9.000 1.00 10.00 1 A 1
ATOM 4 O O GLY A 1 10.000 11.000 12.000 1.00 10.00 1 A 1
ATOM 5 H H GLY A 1 13.000 14.000 15.000 1.00 10.00 1 A 1
HETATM 6 O O HOH B 1 20.000 20.000 20.000 1.00 10.00 100 B 1
"""

# A variant of the above with different coordinates on the CA atom, used to
# exercise the fail-loud collision path: same cache key ("fixture"), genuinely
# different content.
const _TEST_CIF_COLLIDING = """
data_TESTSM2
loop_
_atom_site.group_PDB
_atom_site.id
_atom_site.type_symbol
_atom_site.label_atom_id
_atom_site.label_comp_id
_atom_site.label_asym_id
_atom_site.label_seq_id
_atom_site.Cartn_x
_atom_site.Cartn_y
_atom_site.Cartn_z
_atom_site.occupancy
_atom_site.B_iso_or_equiv
_atom_site.auth_seq_id
_atom_site.auth_asym_id
_atom_site.pdbx_PDB_model_num
ATOM 1 N N GLY A 1 1.000 2.000 3.000 1.00 10.00 1 A 1
ATOM 2 C CA GLY A 1 99.000 99.000 99.000 1.00 10.00 1 A 1
ATOM 3 C C GLY A 1 7.000 8.000 9.000 1.00 10.00 1 A 1
ATOM 4 O O GLY A 1 10.000 11.000 12.000 1.00 10.00 1 A 1
"""

# A synthetic mmCIF with a 2-character chain ID, only for exercising
# writepdb's documented "cannot write non-single-character chain ID" limit.
const _TEST_MULTICHAIN_CIF = """
data_TESTMC
loop_
_atom_site.group_PDB
_atom_site.id
_atom_site.type_symbol
_atom_site.label_atom_id
_atom_site.label_comp_id
_atom_site.label_asym_id
_atom_site.label_seq_id
_atom_site.Cartn_x
_atom_site.Cartn_y
_atom_site.Cartn_z
_atom_site.occupancy
_atom_site.B_iso_or_equiv
_atom_site.auth_seq_id
_atom_site.auth_asym_id
_atom_site.pdbx_PDB_model_num
ATOM 1 N N GLY AA 1 0.000 0.000 0.000 1.00 10.00 1 AA 1
ATOM 2 C CA GLY AA 1 1.000 0.000 0.000 1.00 10.00 1 AA 1
"""

const _TEST_PDB_ID = "1CRN"   # small, real, single-chain, well-known

@testset "StructureSource" begin

    @testset "local .pdb passthrough: same path, no cache write" begin
        dir = mktempdir()
        pdb_path = joinpath(dir, "passthrough-TEST.pdb")
        write(pdb_path, """
        ATOM      1  N   GLY A   1       1.000   2.000   3.000  1.00 10.00           N
        END
        """)
        before = isfile(joinpath(_store_dir(), "passthrough-TEST.pdb"))
        resolved = resolve_structure(LocalPathSource(pdb_path))
        @test resolved == abspath(pdb_path)
        @test !isfile(joinpath(_store_dir(), "passthrough-TEST.pdb"))  # nothing cached
        @test before == false
        rm(dir; recursive = true, force = true)
    end

    @testset "local .cif conversion produces a correct canonical .pdb" begin
        dir = mktempdir()
        cif_path = joinpath(dir, "fixture-TEST.cif")
        write(cif_path, _TEST_CIF)
        cache_path = joinpath(_store_dir(), "fixture-TEST.pdb")
        rm(cache_path; force = true)

        resolved = resolve_structure(LocalPathSource(cif_path))
        @test isfile(resolved)
        @test dirname(resolved) == _store_dir()
        # Keyed by the file's own basename stem, not a content hash.
        @test basename(resolved) == "fixture-TEST.pdb"

        struc = BioStructures.read(resolved, BioStructures.PDBFormat)
        atoms = BioStructures.collectatoms(struc[1], standardselector, heavyatomselector)
        # H and the HOH/chain-B HETATM must be filtered out
        @test length(atoms) == 4
        names = [BioStructures.atomname(a) for a in atoms]
        @test Set(names) == Set(["N", "CA", "C", "O"])

        ca = only(filter(a -> BioStructures.atomname(a) == "CA", atoms))
        c = BioStructures.coords(ca)
        @test c[1] ≈ 4.0 && c[2] ≈ 5.0 && c[3] ≈ 6.0
        @test BioStructures.resname(ca) == "GLY"
        @test BioStructures.resnumber(ca) == 1
        @test BioStructures.chainid(ca) == "A"

        rm(dir; recursive = true, force = true)
        rm(resolved; force = true)
    end

    @testset "local .cif conversion: identical repeat call returns the same file, no rewrite" begin
        dir = mktempdir()
        cif_path = joinpath(dir, "repeat-TEST.cif")
        write(cif_path, _TEST_CIF)
        cache_path = joinpath(_store_dir(), "repeat-TEST.pdb")
        rm(cache_path; force = true)

        resolved1 = resolve_structure(LocalPathSource(cif_path))
        @test resolved1 == cache_path
        mtime1 = mtime(cache_path)

        sleep(1.1)   # coarse mtime resolution on some filesystems
        resolved2 = resolve_structure(LocalPathSource(cif_path))
        @test resolved2 == cache_path
        @test mtime(cache_path) == mtime1   # untouched: identical content, no rewrite

        rm(dir; recursive = true, force = true)
        rm(cache_path; force = true)
    end

    @testset "local .cif conversion: colliding content under the same name raises StructureSourceError" begin
        dir = mktempdir()
        cif_path = joinpath(dir, "collide-TEST.cif")
        cache_path = joinpath(_store_dir(), "collide-TEST.pdb")
        rm(cache_path; force = true)

        write(cif_path, _TEST_CIF)
        resolve_structure(LocalPathSource(cif_path))   # seed the cache
        @test isfile(cache_path)

        write(cif_path, _TEST_CIF_COLLIDING)
        err = try
            resolve_structure(LocalPathSource(cif_path))
            nothing
        catch e
            e
        end
        @test err isa StructureSourceError
        @test occursin("collide-TEST", sprint(showerror, err))

        rm(dir; recursive = true, force = true)
        rm(cache_path; force = true)
    end

    @testset "bad local inputs raise StructureSourceError" begin
        @test_throws StructureSourceError resolve_structure(
            LocalPathSource("/no/such/path/does-not-exist.pdb"))

        dir = mktempdir()
        bad_ext = joinpath(dir, "structure.xyz")
        write(bad_ext, "not a real structure file")
        @test_throws StructureSourceError resolve_structure(LocalPathSource(bad_ext))
        rm(dir; recursive = true, force = true)
    end

    @testset "multi-character chain ID surfaces as a wrapped StructureSourceError" begin
        dir = mktempdir()
        cif_path = joinpath(dir, "multichain_fixture-TEST.cif")
        write(cif_path, _TEST_MULTICHAIN_CIF)

        err = try
            resolve_structure(LocalPathSource(cif_path))
            nothing
        catch e
            e
        end
        @test err isa StructureSourceError
        @test occursin("multichain_fixture-TEST", sprint(showerror, err)) ||
              occursin("chain", lowercase(sprint(showerror, err)))

        rm(dir; recursive = true, force = true)
        rm(joinpath(_store_dir(), "multichain_fixture-TEST.pdb"); force = true)
    end

    @testset "bad PDB ID raises StructureSourceError" begin
        @test_throws StructureSourceError resolve_structure(PDBIDSource("ZZZZ"))
    end

    @testset "URLSource constructor requires a non-empty id" begin
        @test_throws StructureSourceError URLSource("https://example.invalid/nope.pdb", "")
    end

    @testset "bad URL raises StructureSourceError" begin
        @test_throws StructureSourceError resolve_structure(
            URLSource("https://this-host-should-not-resolve.invalid/nope.pdb", "bad-url-TEST"))
    end

    @testset "live PDB-ID fetch: caches, second call does not re-fetch" begin
        cache_path = joinpath(_store_dir(), _TEST_PDB_ID * ".pdb")
        rm(cache_path; force = true)   # start clean regardless of prior runs

        resolved1 = resolve_structure(PDBIDSource(_TEST_PDB_ID))
        @test resolved1 == cache_path
        @test isfile(cache_path)
        mtime1 = mtime(cache_path)

        sleep(1.1)   # coarse mtime resolution on some filesystems
        resolved2 = resolve_structure(PDBIDSource(lowercase(_TEST_PDB_ID)))
        @test resolved2 == cache_path
        @test mtime(cache_path) == mtime1   # untouched: no re-fetch/re-write

        struc = BioStructures.read(cache_path, BioStructures.PDBFormat)
        atoms = BioStructures.collectatoms(struc[1], standardselector, heavyatomselector)
        @test length(atoms) > 0
        @test all(a -> BioStructures.element(a) != "H", atoms)   # no hydrogens
    end

    @testset "load_molecule end-to-end on the fetched PDB ID" begin
        path = resolve_structure(PDBIDSource(_TEST_PDB_ID))
        mol, res = load_molecule(path)
        @test mol isa Molecule
        @test res isa Residues

        n = n_atoms(mol)
        @test n > 0
        @test length(elms(mol)) == n
        @test size(coords_cartesian(mol)) == (3, n)
        @test length(res.resname) == n
        @test length(res.atomname) == n
        @test length(res.resnum) == n
        @test length(res.chain) == n

        # 1CRN is a single-chain, 46-residue peptide (crambin); chain should
        # be uniformly "A" and residue numbers should span 1:46.
        @test all(==("A"), res.chain)
        @test minimum(res.resnum) == 1
        @test maximum(res.resnum) == 46
        @test !any(isempty, res.resname)
        @test !any(e -> lowercase(e) == "h", elms(mol))   # heavy atoms only
    end

    @testset "live URL fetch: identical content on repeat call returns the same file" begin
        url = "https://files.rcsb.org/download/1CRN.pdb"
        id = "1CRN-url-TEST"
        cache_path = joinpath(_store_dir(), id * ".pdb")
        rm(cache_path; force = true)

        resolved1 = resolve_structure(URLSource(url, id))
        @test resolved1 == cache_path
        @test isfile(cache_path)

        struc = BioStructures.read(cache_path, BioStructures.PDBFormat)
        atoms = BioStructures.collectatoms(struc[1], standardselector, heavyatomselector)
        @test length(atoms) > 0

        # A second call always re-fetches (no fetch-avoidance fast path
        # anymore), but identical downloaded content must resolve to the
        # same file rather than erroring or duplicating it.
        resolved2 = resolve_structure(URLSource(url, id))
        @test resolved2 == cache_path
        @test read(resolved2) == read(resolved1)

        rm(cache_path; force = true)
    end

    @testset "live URL fetch: colliding content under the same id raises StructureSourceError" begin
        real_url = "https://files.rcsb.org/download/1CRN.pdb"
        other_url = "https://files.rcsb.org/download/1UBQ.pdb"
        id = "collide-url-TEST"
        cache_path = joinpath(_store_dir(), id * ".pdb")
        rm(cache_path; force = true)

        resolve_structure(URLSource(real_url, id))   # seed the cache
        @test isfile(cache_path)

        err = try
            resolve_structure(URLSource(other_url, id))
            nothing
        catch e
            e
        end
        @test err isa StructureSourceError
        @test occursin(id, sprint(showerror, err))

        rm(cache_path; force = true)
    end

    @testset "LocalPathSource resolution over curated real fixtures ($id, $(meta[2]), $(meta[1]))" for
            (id, meta) in sort(collect(_FIXTURES))
        fname, tier, expected_n, expected_chains = meta
        path = joinpath(_FIXTURE_DIR, fname)
        @test isfile(path)

        is_cif = lowercase(splitext(fname)[2]) in (".cif", ".mmcif")
        resolved = resolve_structure(LocalPathSource(path))
        try
            if is_cif
                # .cif branch converts into the shared cache.
                @test dirname(resolved) == _store_dir()
                @test isfile(resolved)
            else
                # .pdb branch is pure passthrough: no cache write.
                @test resolved == abspath(path)
            end

            # Spot-check atom identity/geometry straight off the resolved
            # canonical .pdb via BioStructures, independent of load_molecule.
            struc = BioStructures.read(resolved, BioStructures.PDBFormat)
            atoms = BioStructures.collectatoms(struc[1], standardselector, heavyatomselector)
            @test length(atoms) == expected_n
            @test all(a -> BioStructures.element(a) != "H", atoms)   # no hydrogens
            for (chain, (fr_num, fr_name, la_num, la_name)) in expected_chains
                chain_atoms = filter(a -> BioStructures.chainid(a) == chain, atoms)
                @test !isempty(chain_atoms)
                nums = [BioStructures.resnumber(a) for a in chain_atoms]
                first_a = chain_atoms[argmin(nums)]
                last_a  = chain_atoms[argmax(nums)]
                @test BioStructures.resnumber(first_a) == fr_num
                @test BioStructures.resname(first_a) == fr_name
                @test BioStructures.resnumber(last_a) == la_num
                @test BioStructures.resname(last_a) == la_name
            end

            # load_molecule end-to-end: internally consistent, no garbage coords.
            # load_molecule no longer applies heavyatomselector (it's a generic
            # loader, not a heavy-atom-only one -- see PDB2PQR.jl/Mols.jl), so
            # its atom count is checked against an independent standardselector
            # -only oracle rather than the heavy-atom expected_n directly: a
            # .cif-sourced fixture is always heavy-only after canonicalization
            # (so the two counts coincide), but a raw .pdb-passthrough fixture
            # may already carry its own embedded hydrogens on disk (true of
            # e.g. 7RSA-TEST.pdb, 1IGT-TEST.pdb), which resolve_structure's
            # pure-passthrough branch never strips.
            standard_only_n = length(BioStructures.collectatoms(struc[1], standardselector))
            mol, res = load_molecule(resolved)
            n = n_atoms(mol)
            @test n == standard_only_n
            is_cif && @test n == expected_n
            @test length(res.resname) == n && length(res.atomname) == n
            @test length(res.resnum) == n && length(res.chain) == n
            cc = coords_cartesian(mol)
            @test size(cc) == (3, n)
            @test all(isfinite, cc)
            @test Set(res.chain) == Set(keys(expected_chains))
        finally
            # Clean up any cache entry the .cif branch wrote, both to keep
            # the shared _cache/ scratch dir tidy and -- more importantly --
            # to avoid a same-named cache key lingering for a repeat run.
            is_cif && rm(resolved; force = true)
        end
    end

    @testset "cross-consistency: local fixture vs live PDBIDSource fetch ($id)" for
            id in ["1UBQ", "6LYZ", "4HHB"]
        fname, _, _, _ = _FIXTURES[id]
        fixture_path = joinpath(_FIXTURE_DIR, fname)

        # Resolve the local fixture under its own "<ID>-TEST" filename (e.g.
        # "1UBQ-TEST.cif") -- distinct from PDBIDSource's uppercase-ID cache
        # key ("1UBQ.pdb"), so the two paths below resolve to genuinely
        # different cache files even though both concern the same protein.
        local_resolved = resolve_structure(LocalPathSource(fixture_path))
        mol_local, res_local = load_molecule(local_resolved)

        # Force a genuine fresh network fetch for the PDB-ID path.
        net_cache = joinpath(_store_dir(), uppercase(id) * ".pdb")
        rm(net_cache; force = true)
        net_resolved = resolve_structure(PDBIDSource(id))
        mol_net, res_net = load_molecule(net_resolved)

        is_cif = lowercase(splitext(fname)[2]) in (".cif", ".mmcif")
        if is_cif
            @test local_resolved != net_cache   # distinct cache keys ("-TEST" suffix vs bare ID)
        end

        @test n_atoms(mol_local) == n_atoms(mol_net)
        @test res_local.resname == res_net.resname
        @test res_local.resnum  == res_net.resnum
        @test res_local.chain   == res_net.chain
        @test res_local.atomname == res_net.atomname
        @test elms(mol_local) == elms(mol_net)

        cc_local = coords_cartesian(mol_local)
        cc_net   = coords_cartesian(mol_net)
        @test size(cc_local) == size(cc_net)
        @test all(close_(cc_local[i], cc_net[i]; atol = 1.0e-3) for i in eachindex(cc_local))

        is_cif && rm(local_resolved; force = true)
    end

    # No real fixture with a genuine multi-character author chain ID (the
    # field StructureSource/BioStructures actually keys `chainid` on --
    # `_atom_site.auth_asym_id`, confirmed by reading BioStructures.jl's
    # mmcif.jl) was found within the size range this task allows. RCSB only
    # assigns multi-letter *author* chain IDs once an entry has run past the
    # single-letter alphabet (tens of chains) -- checked directly against
    # several real multi-chain mmCIF files while curating fixtures above,
    # including an 18-chain, ~2700-residue viral spike trimer (6VXX, not
    # added as a fixture), whose auth_asym_id chains were still all single
    # characters (only its internal label_asym_id went multi-character, a
    # field this codebase does not use for chain identity). Multi-character
    # auth_asym_id realistically only shows up in assemblies (ribosomes,
    # capsids) far past the "large-ish" ceiling this task sets, so per the
    # task's own instruction we did not force one in; the multi-char-chain
    # failure path remains covered by the existing synthetic
    # `_TEST_MULTICHAIN_CIF` fixture above.

end
