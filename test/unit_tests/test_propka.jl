# SPDX-License-Identifier: LGPL-2.1-or-later

# Exercises src/MolecularStructure/Propka.jl: the propka3 subprocess wrapper
# and its .pka summary-table parser.
include(joinpath(@__DIR__, "testsetup.jl"))

using BAYSOL.MolecularStructure: propka_pKas, PropkaError, _parse_pka, _store_dir

# Real backbone/sidechain coordinates lifted from 1UBQ (residues ASP 21 and
# LYS 6, renumbered 1/2), so bond lengths/angles are physically valid and
# PROPKA actually recognizes both groups. ASP is placed second: PROPKA drops
# a titratable sidechain group that coincides with residue 1 (it becomes just
# the N-terminus, "N+"), so a bare two-residue fragment needs the group under
# test *not* to be first.
const _TEST_PDB = """
ATOM      1  N   LYS A   1      27.751  35.867  13.740  1.00  6.04           N
ATOM      2  CA  LYS A   1      27.691  37.315  14.143  1.00  6.12           C
ATOM      3  C   LYS A   1      28.469  37.475  15.420  1.00  6.57           C
ATOM      4  O   LYS A   1      28.213  36.753  16.411  1.00  5.76           O
ATOM      5  CB  LYS A   1      26.219  37.684  14.307  1.00  7.45           C
ATOM      6  CG  LYS A   1      25.884  39.139  14.615  1.00 11.12           C
ATOM      7  CD  LYS A   1      24.348  39.296  14.642  1.00 14.54           C
ATOM      8  CE  LYS A   1      23.865  40.723  14.749  1.00 18.84           C
ATOM      9  NZ  LYS A   1      22.375  40.720  14.907  1.00 20.55           N
ATOM     10  N   ASP A   2      29.599  18.599   9.828  1.00  7.50           N
ATOM     11  CA  ASP A   2      30.796  19.083  10.566  1.00  7.70           C
ATOM     12  C   ASP A   2      30.491  19.162  12.040  1.00  7.08           C
ATOM     13  O   ASP A   2      29.367  19.523  12.441  1.00  8.11           O
ATOM     14  CB  ASP A   2      31.155  20.515  10.048  1.00 11.00           C
ATOM     15  CG  ASP A   2      31.923  20.436   8.755  1.00 15.32           C
ATOM     16  OD1 ASP A   2      32.493  19.374   8.456  1.00 18.03           O
ATOM     17  OD2 ASP A   2      31.838  21.402   7.968  1.00 14.36           O
TER      18      ASP A   2
END
"""

@testset "Propka" begin

    @testset ".pka summary parser (no subprocess)" begin
        # A hardcoded excerpt matching the documented SUMMARY OF THIS
        # PREDICTION format, including a coupled-residue '*' and a ligand row
        # that must be skipped. Exercises the parser independently of
        # actually running propka3.
        sample = """
        SUMMARY OF THIS PREDICTION
               Group      pKa  model-pKa   ligand atom-type
              ASP  25 A     5.07       3.80
              ASP  29 A     3.11*      3.80
              LYS  30 A    10.20      10.50
              N+    1 A     7.75       8.00
              KNI  N1 B     4.60       5.00                NAR
        """
        path, io = mktemp()
        write(io, sample)
        close(io)
        recs = try
            _parse_pka(path)
        finally
            rm(path; force = true)
        end
        @test length(recs) == 4
        @test recs[1] == (resname = "ASP", resnum = 25, chain = "A", pKa = 5.07)
        @test recs[2] == (resname = "ASP", resnum = 29, chain = "A", pKa = 3.11)  # '*' stripped
        @test recs[3] == (resname = "LYS", resnum = 30, chain = "A", pKa = 10.20)
        @test recs[4] == (resname = "N+", resnum = 1, chain = "A", pKa = 7.75)
        # the KNI ligand row must not appear
        @test all(r -> r.resname != "KNI", recs)
    end

    @testset "nonexistent/malformed PDB raises PropkaError" begin
        @test_throws PropkaError propka_pKas("/no/such/file/does-not-exist.pdb")
    end

    @testset "live propka3 subprocess" begin
        dir = mktempdir()
        pdb_path = joinpath(dir, "test-TEST.pdb")
        write(pdb_path, _TEST_PDB)

        local recs
        try
            recs = propka_pKas(pdb_path)
        catch e
            rm(dir; force = true, recursive = true)
            rethrow(e)
        end
        rm(dir; force = true, recursive = true)

        # Exactly the ASP, the LYS, and the N-terminus (on LYS, residue 1)
        # should come back -- no ligand/water rows, nothing extraneous.
        @test length(recs) == 3

        asp = only(filter(r -> r.resname == "ASP", recs))
        @test asp.resnum == 2
        @test asp.chain == "A"
        @test 0 < asp.pKa < 20

        lys = only(filter(r -> r.resname == "LYS", recs))
        @test lys.resnum == 1
        @test lys.chain == "A"
        @test 0 < lys.pKa < 20

        nterm = only(filter(r -> r.resname == "N+", recs))
        @test nterm.resnum == 1
        @test nterm.chain == "A"
        @test 0 < nterm.pKa < 20

        # propka3 writes `test-TEST.pka` into whatever directory it's run from
        # -- that's the shared `_store_dir()`, never the input's own `dir` --
        # and it's left there deliberately (not version-controlled, but not
        # deleted either, so it stays available for inspection/reuse).
        @test !isfile(joinpath(dir, "test-TEST.pka"))
        @test isfile(joinpath(_store_dir(), "test-TEST.pka"))
    end

end
