# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/molecular-structure/checks.jl: the repairs of the text of a .pdb that its
# readers cannot take as it is (`structureIssues`, `sanitizedCopy`: a chain id reused by a
# TER-separated block, true duplicate atoms) and the detection, only logged, of dummy-atom
# and fragment models (`dummyLikeResidues`, `logDummyLike`). The logic runs on small
# synthetic files; the acceptance numbers on the real fixtures SASDAC9 (two RNA chains both
# labelled A), SASDR99 (duplicated atoms), SASDAN8 (an all-zero B-factor column, which is
# not a defect) and the ordinary multi-chain fixtures. One pdb2pqr run (SASDAC9, nucleic
# acid only, AMBER; the CondaPkg tools are needed like in test-pdb2pqr.jl), no network.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

# Everything below lives in a module of its own, so that the helpers and constants of this
# file cannot clash with those of another file when the aggregator includes them all into
# Main.
module NtTest_struct_chk

using Test
using BAYSOL

using Printf: @sprintf
using BAYSOL.MolecularStructure: structureIssues, sanitizedCopy, dummyLikeResidues,
    logDummyLike, MoleculeError, CHAIN_LETTERS, DUMMY_RESIDUE_NAMES,
    DUMMY_MAX_HEAVY_ATOMS,
    DUMMY_ZERO_FRACTION, PROTEIN_BACKBONE_ATOMS, NUCLEOBASE_ATOMS, BACKBONE_ATOMS, _WARNED,
    loadMolecule, nAtoms, elms, _storeDir, residueNames, component
using BAYSOL.Hydrogenator:
    resolveHydrogens, hydrogenationChoice, NoTitration,
    heavyAtomCount

const _FIXTURES = joinpath(@__DIR__, "..", "..", "fixtures")

# a fixed-column ATOM/HETATM record
function pdbline(
    rec, serial, atom, res, chain, num, elem;
    alt = ' ', xyz = (1.0, 2.0, 3.0), occ = 1.0, bfac = 10.0,
)
    a = length(elem) == 2 ? rpad(atom, 4) : " " * rpad(atom, 3)
    return @sprintf(
        "%-6s%5d %s%c%3s %c%4d    %8.3f%8.3f%8.3f%6.2f%6.2f          %2s",
        rec, serial, a, alt, res, chain, num, xyz..., occ, bfac, lpad(elem, 2)
    )
end
elementOf(name) = first(name) in "CNOPSH" ? string(first(name)) : "X"

# the residue `name` number `num` in `chain` with atoms `atoms`; serials from `s0`
function residue(
    name, chain, num, atoms; rec = "ATOM", s0 = 1, kwargs...,
)
    return [
        pdbline(rec, s0 + i - 1, a, name, chain, num, elementOf(a);
            xyz = (Float64(i), Float64(num), 0.0), kwargs...)
        for (i, a) in enumerate(atoms)
    ]
end
ter(chain, serial = 9999) = @sprintf("TER   %5d      %3s %c%4d", serial, "   ", chain, 1)

const NUC =
    ["P", "OP1", "OP2", "O5'", "C5'", "C4'", "O4'", "C3'", "C2'", "C1'", "N9", "C8",
        "N7", "C5", "C6", "N1", "C2", "N3", "C4"]
const PROT = ["N", "CA", "C", "O", "CB", "CG"]

function wr(dir, name, lines)
    path = joinpath(dir, name)
    write(path, join(lines, "\n") * "\n")
    return path
end
chainOf(l) = l[22]
atomLines(path) =
    [l for l in eachline(path) if startswith(l, "ATOM") || startswith(l, "HETATM")]

@testset "structure checks" begin
    dir = mktempdir()
    empty!(_WARNED)
    try
        @testset "the constants" begin
            @test DUMMY_RESIDUE_NAMES == ("UNK", "DUM", "DUMMY", "UNL")
            @test DUMMY_MAX_HEAVY_ATOMS == 2
            @test DUMMY_ZERO_FRACTION == 0.05
            @test PROTEIN_BACKBONE_ATOMS == ("N", "CA", "C")
            @test "N9" in NUCLEOBASE_ATOMS && !("P" in NUCLEOBASE_ATOMS)
            @test length(CHAIN_LETTERS) == 62 && allunique(CHAIN_LETTERS)
            @test first(CHAIN_LETTERS) == 'A' && last(CHAIN_LETTERS) == '9'
        end

        @testset "waters are removed on request, whatever their oxygen is called" begin
            prot = residue("ALA", 'A', 1, ["N", "CA", "C", "O", "CB"])
            ws = [
                residue("HOH", 'A', 601, ["O1"]; rec = "ATOM", s0 = 100);
                residue("HOH", 'A', 602, ["O"]; rec = "HETATM", s0 = 110);
                residue("WAT", 'A', 603, ["OW"]; rec = "HETATM", s0 = 120)
            ]
            aniso = "ANISOU  100  O1  HOH A 601" * " "^40
            path = wr(dir, "wat.pdb", [prot; ws[1:1]; aniso; ws[2:end]; "END"])
            out = joinpath(dir, "wat.out.pdb")
            # not asked: nothing to do
            @test sanitizedCopy(path, joinpath(dir, "wat0.out.pdb")) === nothing
            @test structureIssues(path) == (relabelled = 0, dropped = 0)
            @test sanitizedCopy(path, out; waters = true) ==
                  (relabelled = 0, dropped = 0)
            # the rest is byte-identical: the protein records and END
            @test readlines(out) == [prot; "END"]
            # a file without waters needs nothing
            clean = wr(dir, "nowat.pdb", prot)
            @test sanitizedCopy(clean, joinpath(dir, "nowat.out.pdb"); waters = true) ===
                  nothing
        end

        @testset "chains that reuse an id and residue numbers" begin
            one = [residue("A", 'A', 1, NUC); residue("C", 'A', 2, NUC; s0 = 100)]
            two =
                [residue("A", 'A', 1, NUC; s0 = 1000); residue("C", 'A', 2, NUC; s0 = 1100)]
            path = wr(dir, "two.pdb", [one; ter('A'); two; ter('A')])
            @test structureIssues(path) == (relabelled = 1, dropped = 0)
            out = joinpath(dir, "two.out.pdb")
            @test sanitizedCopy(path, out) == (relabelled = 1, dropped = 0)
            ls = readlines(out)
            @test length(ls) == length(readlines(path))
            at = atomLines(out)
            @test unique(chainOf.(at[1:length(one)])) == ['A']
            # the next unused letter
            @test unique(chainOf.(at[(length(one)+1):end])) == ['B']
            # the TER of the relabelled block is relabelled too, the first one not
            ters = [l for l in ls if startswith(l, "TER")]
            @test chainOf.(ters) == ['A', 'B']
            # nothing else changed in the lines
            for (a, b) in zip(readlines(path), ls)
                @test a[1:21] == b[1:21] && a[23:end] == b[23:end]
            end

            # a chain that only continues after a TER with other numbers is left alone
            lig = residue("ATP", 'A', 101, ["PG", "O1G"]; rec = "HETATM", s0 = 500)
            wat = residue("HOH", 'A', 102, ["O"]; rec = "HETATM", s0 = 600)
            path = wr(dir, "cont.pdb", [one; ter('A'); lig; wat])
            @test structureIssues(path) == (relabelled = 0, dropped = 0)
            @test sanitizedCopy(path, joinpath(dir, "cont.out.pdb")) === nothing
            # nothing is written
            @test !isfile(joinpath(dir, "cont.out.pdb"))

            # letters already in use are skipped
            other = residue("G", 'B', 7, NUC; s0 = 2000)
            path = wr(dir, "used.pdb", [one; ter('A'); other; ter('B'); two; ter('A')])
            out = joinpath(dir, "used.out.pdb")
            @test sanitizedCopy(path, out) == (relabelled = 1, dropped = 0)
            @test unique(chainOf.(atomLines(out))) == ['A', 'B', 'C']

            # three molecules named alike: B and C
            three = [one; ter('A'); two; ter('A'); residue("A", 'A', 1, NUC; s0 = 3000);
                residue("C", 'A', 2, NUC; s0 = 3100); ter('A')]
            path = wr(dir, "three.pdb", three)
            out = joinpath(dir, "three.out.pdb")
            @test sanitizedCopy(path, out) == (relabelled = 2, dropped = 0)
            @test unique(chainOf.(atomLines(out))) == ['A', 'B', 'C']

            # the same ids but different numbers: two chains that merely share a label
            far = [
                residue("A", 'A', 50, NUC; s0 = 1000);
                residue("C", 'A', 51, NUC; s0 = 1100)
            ]
            @test structureIssues(wr(dir, "far.pdb", [one; ter('A'); far])) ==
                  (relabelled = 0, dropped = 0)

            # blank chain ids are chains too
            b1 = [l[1:21] * " " * l[23:end] for l in residue("A", 'A', 1, NUC)]
            b2 = [l[1:21] * " " * l[23:end] for l in residue("A", 'A', 1, NUC; s0 = 1000)]
            path = wr(dir, "blank.pdb", [b1; ter(' '); b2])
            out = joinpath(dir, "blank.out.pdb")
            @test sanitizedCopy(path, out) == (relabelled = 1, dropped = 0)
            @test unique(chainOf.(atomLines(out))) == [' ', 'A']

            # the first model only
            m1 = [one; ter('A'); "ENDMDL"; two]
            @test structureIssues(wr(dir, "models.pdb", m1)) ==
                  (relabelled = 0, dropped = 0)

            # more reused ids than letters: a MoleculeError
            blocks = String[]
            for i in 1:(length(CHAIN_LETTERS)+1)
                append!(blocks, residue("A", 'A', 1, ["N9"]; s0 = i))
                push!(blocks, ter('A', 5000 + i))
            end
            path = wr(dir, "many.pdb", blocks)
            @test_throws MoleculeError structureIssues(path)
            @test_throws MoleculeError sanitizedCopy(path, joinpath(dir, "many.out.pdb"))
            err = try
                structureIssues(path)
            catch e
                e
            end
            @test occursin("chain ids available", err.msg)
            # as many as there are letters minus the one in use still fit
            ok = String[]
            for i in 1:length(CHAIN_LETTERS)
                append!(ok, residue("A", 'A', 1, ["N9"]; s0 = i))
                push!(ok, ter('A', 5000 + i))
            end
            @test structureIssues(wr(dir, "fit.pdb", ok)).relabelled ==
                  length(CHAIN_LETTERS) - 1
        end

        @testset "true duplicate atoms" begin
            base = residue("A", 'A', 1, NUC)
            dup = copy(base[1:3])
            dup = [l[1:30] * "   9.000   9.000   9.000" * l[55:end] for l in dup]  # moved
            lines = [base; dup]
            path = wr(dir, "dup.pdb", lines)
            @test structureIssues(path) == (relabelled = 0, dropped = 3)
            out = joinpath(dir, "dup.out.pdb")
            @test sanitizedCopy(path, out) == (relabelled = 0, dropped = 3)
            # the later copies are dropped, the first stays
            @test atomLines(out) == base
            # an ANISOU record after a dropped atom goes with it
            an = "ANISOU" * base[1][7:27] * "     100    200    300    10    20    30"
            path = wr(dir, "anisou.pdb", [base; dup[1]; an; dup[2]])
            out = joinpath(dir, "anisou.out.pdb")
            @test sanitizedCopy(path, out) == (relabelled = 0, dropped = 2)
            @test !any(startswith("ANISOU"), readlines(out))
            # alternate locations are not duplicates
            alts = [
                residue("A", 'A', 1, ["N9"]; alt = 'A');
                residue("A", 'A', 1, ["N9"]; alt = 'B', s0 = 2)
            ]
            @test structureIssues(wr(dir, "alts.pdb", alts)) ==
                  (relabelled = 0, dropped = 0)
            # the same atom name in another residue, or the same residue in another chain
            diff = [residue("A", 'A', 1, ["N9"]); residue("A", 'A', 2, ["N9"]; s0 = 2);
                residue("A", 'B', 1, ["N9"]; s0 = 3)]
            @test structureIssues(wr(dir, "diff.pdb", diff)) ==
                  (relabelled = 0, dropped = 0)
            # an insertion code makes another residue
            ic = [residue("A", 'A', 1, ["N9"]);
                [l[1:26] * "A" * l[28:end] for l in residue("A", 'A', 1, ["N9"]; s0 = 2)]]
            @test structureIssues(wr(dir, "ic.pdb", ic)) == (relabelled = 0, dropped = 0)
            # after a relabelling the two chains are different chains: no duplicates; a
            # duplicate inside the second one is dropped
            one = residue("A", 'A', 1, NUC)
            two = residue("A", 'A', 1, NUC; s0 = 1000)
            path = wr(dir, "both.pdb", [one; ter('A'); two; two[1:2]])
            out = joinpath(dir, "both.out.pdb")
            @test sanitizedCopy(path, out) == (relabelled = 1, dropped = 2)
            at = atomLines(out)
            @test length(at) == 2 * length(NUC)
            @test count(==('B'), chainOf.(at)) == length(NUC)
        end

        @testset "what is logged" begin
            one = residue("A", 'A', 1, NUC)
            two = residue("A", 'A', 1, NUC; s0 = 1000)
            path = wr(dir, "log.pdb", [one; ter('A'); two; two[1:2]])
            empty!(_WARNED)
            out = joinpath(dir, "log.out.pdb")
            @test_logs (:warn, r"1 chain\(s\) of \"log.pdb\" reuse a chain id.*\(A → B\)") (
                :warn, r"2 duplicate atom\(s\) of \"log.pdb\"") sanitizedCopy(path, out)
            # once per structure: the second time nothing is logged
            @test_logs sanitizedCopy(path, out)
            # a clean file logs nothing
            clean = wr(dir, "clean.pdb", one)
            @test_logs sanitizedCopy(clean, joinpath(dir, "clean.out.pdb"))
            @test_logs (:warn, r"2 chain\(s\)") begin
                path3 = wr(dir, "log3.pdb", [one; ter('A'); two; ter('A'); one])
                sanitizedCopy(path3, joinpath(dir, "log3.out.pdb"))
            end
        end

        @testset "dummy-like residues: each rule" begin
            f(lines) = dummyLikeResidues(wr(dir, "d$(rand(UInt16)).pdb", lines))
            nat(i) = residue("A", 'A', i, NUC; s0 = 100i)
            good = [nat(1); nat(2); residue("ALA", 'B', 1, PROT; s0 = 5000)]
            d = f(good)
            @test d.n == 0 && isempty(d.residues) && d.duplicates == 0 &&
                  d.zeroFraction == 0.0

            # 1. the name, in ATOM records; a HETATM UNK ligand is not a dummy residue
            # (DUMMY does not fit the three columns of a residue name)
            for name in ("UNK", "DUM", "UNL")
                d = f([good; residue(name, 'C', 1, PROT; s0 = 7000)])
                @test d.n == 1 && only(d.residues).name == name
                @test :name in only(d.residues).reasons
            end
            d = f([good; residue("UNK", 'C', 1, PROT; rec = "HETATM", s0 = 7000)])
            @test d.n == 0
            # 2. at most two heavy atoms, in an ATOM record
            few = residue("GLY", 'C', 1, ["CA", "C"]; s0 = 7000)
            d = f([good; few])
            @test d.n == 1 && only(d.residues).reasons == [:few_atoms]
            @test (only(d.residues).chain, only(d.residues).num, only(d.residues).name) ==
                  ("C", "1", "GLY")
            # three heavy atoms with a complete backbone are a (glycine) residue
            @test f([good; residue("GLY", 'C', 1, ["CA", "C", "N"]; s0 = 7000)]).n == 0
            # hydrogens do not count as heavy atoms
            hs = residue("GLY", 'C', 1, ["CA", "C", "HA2", "HA3"]; s0 = 7000)
            @test f([good; hs]).n == 1
            # a water, an ion or a component that small itself is not flagged
            @test f([good; residue("HOH", 'D', 1, ["O"]; rec = "ATOM", s0 = 7000)]).n == 0
            @test f([good; residue("MG", 'D', 2, ["MG"]; rec = "ATOM", s0 = 7100)]).n == 0
            @test f([good; residue("K+", 'D', 3, ["K"]; rec = "ATOM", s0 = 7200)]).n == 0
            # HETATM residues are not judged by their size
            @test f([good; residue("ZN", 'D', 4, ["ZN"]; rec = "HETATM", s0 = 7300)]).n == 0
            # 3. a protein residue without N, CA or C
            nobb = residue("ALA", 'C', 1, ["N", "CA", "O", "CB"]; s0 = 7000)
            d = f([good; nobb])
            @test only(d.residues).reasons == [:protein_backbone]
            @test f([good; residue("ALA", 'C', 1, ["CA", "C", "O", "CB"]; s0 = 7000)]).n ==
                  1
            @test f([good; residue("ALA", 'C', 1, ["N", "C", "O", "CB"]; s0 = 7000)]).n == 1
            @test f([good; residue("ALA", 'C', 1, ["N", "CA", "C"]; s0 = 7000)]).n == 0
            # 4. a nucleotide with fewer than four backbone atoms and no base atom
            frag = residue("A", 'C', 1, ["P", "OP1", "OP2"]; s0 = 7000)
            d = f([good; frag])
            @test only(d.residues).reasons == [:nucleotide_fragment]
            nuc(atoms) = f([good; residue("A", 'C', 1, atoms; s0 = 7000)])
            @test nuc(["P", "O5'", "C5'", "C4'"]).n == 0
            @test nuc(["P", "OP1", "O5'", "C5'"]).n == 1
            # base atoms make it a nucleotide, not a fragment
            @test f([good; residue("A", 'C', 1, ["C1'", "N9", "C8"]; s0 = 7000)]).n == 0
            # a protein residue whose size makes it a nucleotide fragment? no: DA only
            @test f([good; residue("DA", 'C', 1, ["P", "OP1", "OP2"]; s0 = 7000)]).n == 1
            # several reasons for one residue, several residues
            d = f([good; residue("UNK", 'C', 1, ["C1"]; s0 = 7000)])
            @test d.n == 1 && d.residues[1].reasons == [:name]
            d = f([good; few; residue("UNL", 'C', 2, PROT; s0 = 7100)])
            @test d.n == 2

            # structure level: duplicate atoms count once
            d = f([good; good[1:2]])
            @test d.duplicates == 2 && d.n == 1 && isempty(d.residues)
            # more than 5 % of the atoms with B = 0 AND occupancy 0
            n = length(good)
            zeros_(k) = [
                residue("ALA", 'E', i, PROT; s0 = 9000 + 10i, occ = 0.0, bfac = 0.0)
                for i in 1:k
            ]
            d = f([good; reduce(vcat, zeros_(2))])
            @test d.zeroFraction ≈ 12 / (n + 12) && d.n == 1
            @test d.residues == []
            # a few zero atoms are below the threshold
            many = [residue("ALA", 'B', i, PROT; s0 = 9000 + 10i) for i in 2:40]
            d = f(
                [
                    good;
                    reduce(vcat, many);
                    residue(
                        "ALA",
                        'E',
                        1,
                        ["N", "CA", "C"];
                        occ = 0.0,
                        bfac = 0.0,
                        s0 = 90000,
                    )
                ],
            )
            @test d.zeroFraction < DUMMY_ZERO_FRACTION && d.n == 0
        end

        @testset "the B-factor decision" begin
            f(lines) = dummyLikeResidues(wr(dir, "b$(rand(UInt16)).pdb", lines))
            mk(; occ, bfac) = [residue("A", 'A', 1, NUC; occ, bfac);
                residue("C", 'A', 2, NUC; s0 = 100, occ, bfac);
                residue("ALA", 'B', 1, PROT; s0 = 500, occ, bfac)]
            # an all-zero B column with occupancy 1.00 (MD or modelled structures): fine
            d = f(mk(occ = 1.0, bfac = 0.0))
            @test d.n == 0 && d.zeroFraction == 0.0
            # zero B and occupancy 0 on every atom (SASDR99 style): not flagged either
            d = f(mk(occ = 0.0, bfac = 0.0))
            @test d.zeroFraction == 1.0 && d.n == 0
            # occupancy 0 with a real B-factor is not "zero" either
            @test f(mk(occ = 0.0, bfac = 10.0)).zeroFraction == 0.0
            # a subset of the atoms with both zero: flagged
            sub = [
                mk(occ = 1.0, bfac = 10.0);
                residue("ALA", 'E', 1, PROT; s0 = 900, occ = 0.0, bfac = 0.0)
            ]
            d = f(sub)
            @test 0.05 < d.zeroFraction < 0.95 && d.n == 1
        end

        @testset "the warning and the flow" begin
            good = [residue("A", 'A', 1, NUC); residue("C", 'A', 2, NUC; s0 = 100)]
            bad = [good; residue("UNK", 'C', 1, PROT; s0 = 7000);
                residue("GLY", 'C', 2, ["CA", "C"]; s0 = 7100)]
            path = wr(dir, "warn.pdb", bad)
            empty!(_WARNED)
            @test_logs (
                :warn,
                Regex(
                    "\"warn.pdb\" looks like a dummy-atom or fragment model " *
                    "\\(1 few_atoms; 1 name; e.g. UNK C1, GLY C2\\).*undefined",
                ),
            ) begin
                d = logDummyLike(path)
                @test d.n == 2
            end
            # once per structure; the result is the same, nothing changes in the file
            before = read(path, String)
            d = @test_logs logDummyLike(path)
            @test d.n == 2 && read(path, String) == before
            # a clean file logs nothing
            @test_logs logDummyLike(wr(dir, "okay.pdb", good))
            # duplicates and the zero fraction appear in the text
            dups = wr(dir, "dupw.pdb", [good; good[1:2]])
            @test_logs (:warn, r"2 duplicate atoms") logDummyLike(dups)
            zeros = wr(
                dir,
                "zerow.pdb",
                [good;
                    residue("ALA", 'E', 1, PROT; s0 = 900, occ = 0.0, bfac = 0.0)],
            )
            @test_logs (:warn, r"% atoms with B = 0 and occupancy 0") logDummyLike(zeros)
            # the structure still loads: flagging does not stop anything
            @test nAtoms(loadMolecule(path)) == length(atomLines(path))
        end

        @testset "real fixtures" begin
            fx(id, name) = joinpath(_FIXTURES, "experiments", id, name)
            # the ordinary fixtures are untouched and clean
            for id in
                ("1BNA", "1CRN", "1EHZ", "246D", "3HDD", "4HHB", "1IGT", "1RNA", "1SDR")
                p = joinpath(_FIXTURES, "molecules", "$id-TEST.pdb")
                @test structureIssues(p) == (relabelled = 0, dropped = 0)
                d = dummyLikeResidues(p)
                @test d.n == 0 && d.duplicates == 0
                @test sanitizedCopy(p, joinpath(dir, "o.pdb")) === nothing
            end
            # SASDAN8: all B-factors zero, occupancy 1.00 (a modelled structure): n = 0
            @test dummyLikeResidues(fx("SASDAN8", "SASDAN8_fit1_model1.pdb")).n == 0
            # SASDR99: every atom has B = 0 and occupancy 0; model1 holds duplicates
            p = fx("SASDR99", "SASDR99_fit2_model1.pdb")
            @test structureIssues(p) == (relabelled = 0, dropped = 3787)
            d = dummyLikeResidues(p)
            @test d.zeroFraction == 1.0 && d.duplicates == 3787 && d.n == 1
            p = fx("SASDR99", "SASDR99_fit2_model1_chainAB.pdb")
            @test structureIssues(p) == (relabelled = 0, dropped = 0)
            @test dummyLikeResidues(p).n == 0
            # SASDAC9: two 186-nucleotide RNA chains both labelled A
            p = fx("SASDAC9", "SASDAC9_fit2_model1.pdb")
            @test structureIssues(p) == (relabelled = 2, dropped = 0)
            @test dummyLikeResidues(p).n == 0
            out = joinpath(dir, "ac9.out.pdb")
            empty!(_WARNED)
            @test_logs (:warn, r"2 chain\(s\).*A → C, B → D") sanitizedCopy(p, out)
            @test sort(unique(chainOf.(atomLines(out)))) == ['A', 'B', 'C', 'D']
        end

        @testset "SASDAC9 through the nucleic-acid route" begin
            src = joinpath(_FIXTURES, "experiments", "SASDAC9", "SASDAC9_fit2_model1.pdb")
            path = joinpath(dir, "nt-checks-ac9.pdb")
            cp(src, path)
            try
                choice = hydrogenationChoice(component.(residueNames(path)), path)
                @test choice ==
                      (content = :nucleic, ff = :amber, titration = :none, reason = "")
                hp = resolveHydrogens(path, 7.4; ff = choice.ff, titration = NoTitration())
                mol = loadMolecule(hp)
                # waters are not loaded; the polymer is 7912 heavy atoms of the RNA + 56 GDP
                # and 4028 hydrogens; the ligands (10 K, 10 Mg, 68 MO6 atoms: Mg(H2O)6, 12 H
                # as the fixture has them) are 88 atoms more than before
                # 2026-11-11, when nAtoms was 11996
                poly = loadMolecule(hp; ligands = false)
                @test nAtoms(poly) == 11996
                @test nAtoms(mol) == 11996 + 88
                nH = count(e -> uppercase(e) == "H", elms(poly))
                @test nH == 4028 && nAtoms(poly) - nH == 7968
                @test count(e -> uppercase(e) == "H", elms(mol)) - nH == 12
                # both chains are there (A and B reused, relabelled in the copy)
                # (8066 with the 22 waters, which are removed before pdb2pqr)
                @test heavyAtomCount(path) == 8044 == heavyAtomCount(hp)
            finally
                for f in readdir(_storeDir())
                    startswith(f, "nt-checks-") &&
                        rm(joinpath(_storeDir(), f); force = true)
                end
            end
        end
    finally
        empty!(_WARNED)
        rm(dir; recursive = true, force = true)
    end
end

end # module
