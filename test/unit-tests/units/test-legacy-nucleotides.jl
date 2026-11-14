# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises the legacy residue names of nucleotides (ADE GUA CYT URI THY, in older and
# CHARMM-style files such as the SASBDB models SASDT55 and SASDG24):
# src/molecular-structure/ components.jl (`_legacyNucleotides`, `legacyNucleotidesInFile`,
# `legacyNucleotidesInModel`, the loader's selector) and their relabelling for pdb2pqr
# (src/hydrogenator/modified.jl). In the dictionary these ids are the free bases
# (ligands), so a residue under one of them is a nucleotide only if it carries the
# sugar-phosphate backbone. Synthetic files are cut from 1SDR (RNA) and 1BNA (DNA); the
# pdb2pqr run on SASDT55 needs the CondaPkg tools (like test-pdb2pqr.jl), no network.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

# Everything below lives in a module of its own, so that the helpers and constants of this
# file cannot clash with those of another file when the aggregator includes them all into
# Main.
module NtTest_legacy_nucleotides

using Test
using BAYSOL

using Printf: @sprintf

using BAYSOL.MolecularStructure: LEGACY_NUCLEOTIDE_NAMES, BACKBONE_ATOMS, BACKBONE_MIN,
    _legacyNucleotides, legacyNucleotidesInFile, legacyNucleotidesInModel,
    loadMolecule, nAtoms, MoleculeError, component, isNucleotide, nucleotideSelector,
    polymerSelector, ligandSelector,
    _modelSelector, residueNames, _storeDir
using BAYSOL.Hydrogenator: relabelModified, restoreModified!, hydrogenationChoice,
    resolveHydrogens, Propka, _hydrogensPath, _pkaPath
using BioStructures: BioStructures, PDBFormat, collectmodels

const _FIXTURES = joinpath(@__DIR__, "..", "..", "fixtures")
const _T55 = joinpath(_FIXTURES, "experiments", "SASDT55", "SASDT55_fit1_model1.pdb")
const _G24 = joinpath(_FIXTURES, "molecules", "SASDG24-legacy-rna.pdb")

# a fixed-column ATOM/HETATM record (coordinates and the rest do not matter)
function pdbline(rec, serial, atom, res, chain, num, elem; xyz = (1.0, 2.0, 3.0))
    a = length(elem) == 2 ? rpad(atom, 4) : " " * rpad(atom, 3)
    return @sprintf("%-6s%5d %s %3s %c%4d    %8.3f%8.3f%8.3f%6.2f%6.2f          %2s",
        rec, serial, a, res, chain, num, xyz..., 1.0, 10.0, lpad(elem, 2))
end
const ION = pdbline("HETATM", 900, "MG", "MG", 'A', 901, "MG")
const WATER = pdbline("HETATM", 901, "O", "HOH", 'A', 902, "O"; xyz = (4.0, 5.0, 6.0))

function _residues(id::AbstractString, chain::Char, nums)
    out = String[]
    for l in eachline(joinpath(_FIXTURES, "molecules", "$id-TEST.pdb"))
        startswith(l, "ATOM") || continue
        l[22] == chain && parse(Int, strip(l[23:26])) in nums && push!(out, l)
    end
    return out
end
rename(lines, name) = [l[1:17] * lpad(name, 3) * l[21:end] for l in lines]
hetero(lines) = ["HETATM" * l[7:end] for l in lines]
inchain(lines, c::Char) = [l[1:21] * c * l[23:end] for l in lines]
residue(lines, num) = [l for l in lines if parse(Int, strip(l[23:26])) == num]
atomsIn(lines, names) = [l for l in lines if strip(l[13:16]) in names]
nameOf(l) = strip(l[18:20])
isH(l) = strip(l[77:min(end, 78)]) in ("H", "D")
# remove the store files of the stems starting with `prefix`
function purgeStore(prefix)
    for f in readdir(_storeDir())
        startswith(f, prefix) &&
            rm(joinpath(_storeDir(), f); force = true, recursive = true)
    end
end
function wr(dir, name, lines)
    path = joinpath(dir, name)
    write(path, join(lines, "\n") * "\n")
    return path
end

# records as _legacyNucleotides takes them: (chain, number, residue name, atom name)
recs(chain, num, name, atoms) = [(chain, num, name, a) for a in atoms]
const _BACKBONE4 = collect(BACKBONE_ATOMS[2:5])           # O5' C5' C4' O4'
const _BASE_ADENINE = ["N9", "C8", "N7", "C5", "C6", "N6", "N1", "C2", "N3", "C4"]

@testset "legacy-named nucleotides" begin
    @testset "the names" begin
        @test LEGACY_NUCLEOTIDE_NAMES ==
              Dict("ADE" => "A", "GUA" => "G", "CYT" => "C", "URI" => "U", "THY" => "T")
        # the dictionary has them as free bases, not as nucleotides
        for n in keys(LEGACY_NUCLEOTIDE_NAMES)
            @test component(n).class === :other
            @test !isNucleotide(n)
        end
        @test BACKBONE_MIN == 4 && length(BACKBONE_ATOMS) == 8 && "P" in BACKBONE_ATOMS
    end

    @testset "_legacyNucleotides: the rule on atom records" begin
        full = ["P", "OP1", "O5'", "C5'", "C4'", "O4'", "C3'", "C2'", "C1'", "N9"]
        f(rs) = _legacyNucleotides(rs)
        # a P atom is enough, alone in its chain
        r = f(recs("A", "1", "ADE", full))
        @test collect(keys(r)) == [("A", "1")]
        @test r[("A", "1")] == (name = "ADE", class = :dna, base = "A")   # no O2'
        # 4 backbone atoms without P: only with another such residue in the chain
        @test isempty(f(recs("A", "1", "ADE", _BACKBONE4)))
        two = [recs("A", "1", "ADE", _BACKBONE4); recs("A", "2", "GUA", _BACKBONE4)]
        @test sort(collect(keys(f(two)))) == [("A", "1"), ("A", "2")]
        # ... in the same chain
        apart = [recs("A", "1", "ADE", _BACKBONE4); recs("B", "2", "ADE", _BACKBONE4)]
        @test isempty(f(apart))
        # 3 backbone atoms do not carry, and do not count for their neighbours
        three = [recs("A", "1", "ADE", _BACKBONE4); recs("A", "2", "ADE", _BACKBONE4[1:3])]
        @test isempty(f(three))
        # a residue with a P needs no neighbour but counts as one
        pn = [recs("A", "1", "ADE", ["P"]); recs("A", "2", "ADE", _BACKBONE4)]
        @test sort(collect(keys(f(pn)))) == [("A", "1"), ("A", "2")]
        # a free base is never a nucleotide
        @test isempty(f(recs("A", "1", "ADE", _BASE_ADENINE)))
        # insertion codes are part of the number: 1 and 1A are two residues
        ic = [recs("A", "1", "ADE", _BACKBONE4); recs("A", "1A", "ADE", _BACKBONE4)]
        @test sort(collect(keys(f(ic)))) == [("A", "1"), ("A", "1A")]
        # the old star primes are primes
        star = recs("A", "1", "ADE", ["O5*", "C5*", "C4*", "O4*"])
        @test isempty(f(star))                                  # one residue
        @test length(f([star; recs("A", "2", "ADE", ["O5*", "C5*", "C4*", "O4*"])])) == 2
        # names that are not legacy ones are ignored, whatever atoms they have
        @test isempty(f(recs("A", "1", "ALA", full)))
        @test isempty(f(recs("A", "1", "A", full)))
        # empty input
        @test isempty(f(Tuple{String,String,String,String}[]))
        @test isempty(f(()))

        # classes: THY is DNA, URI RNA, the others RNA when they have O2'
        rnaAtoms = [full; "O2'"]
        @test f(recs("A", "1", "THY", rnaAtoms))[("A", "1")].class === :dna
        @test f(recs("A", "1", "THY", full))[("A", "1")].base == "T"
        @test f(recs("A", "1", "URI", full))[("A", "1")].class === :rna
        @test f(recs("A", "1", "URI", full))[("A", "1")].base == "U"
        for (n, b) in (("ADE", "A"), ("GUA", "G"), ("CYT", "C"))
            @test f(recs("A", "1", n, rnaAtoms))[("A", "1")] ==
                  (name = n, class = :rna, base = b)
            @test f(recs("A", "1", n, full))[("A", "1")] ==
                  (name = n, class = :dna, base = b)
            # the old star spelling of the 2' oxygen is the same atom
            @test f(recs("A", "1", n, [full; "O2*"]))[("A", "1")].class === :rna
        end
        # two names for one residue key: the first record's name stays
        @test length(f([recs("A", "1", "ADE", full); recs("A", "1", "GUA", ["N9"])])) == 1
    end

    @testset "legacyNucleotidesInFile on synthetic files" begin
        dir = mktempdir()
        try
            rna = _residues("1SDR", 'A', 1:3)          # U A A, the first without P
            ade = rename(rna, "ADE")
            L = legacyNucleotidesInFile(wr(dir, "a.pdb", ade))
            @test sort(collect(keys(L))) == [("A", "1"), ("A", "2"), ("A", "3")]
            @test all(v -> v.name == "ADE" && v.class === :rna && v.base == "A", values(L))
            # HETATM records are read the same
            @test legacyNucleotidesInFile(wr(dir, "h.pdb", hetero(ade))) == L
            # a lower case name is the same name
            @test legacyNucleotidesInFile(wr(dir, "l.pdb", rename(rna, "ade"))) == L
            # DNA atoms (no O2'): DNA class
            dna = rename(_residues("1BNA", 'A', 1:3), "ADE")
            D = legacyNucleotidesInFile(wr(dir, "d.pdb", dna))
            @test length(D) == 3 && all(v -> v.class === :dna, values(D))
            thy = legacyNucleotidesInFile(wr(dir, "t.pdb", rename(rna, "THY")))
            @test all(v -> v.class === :dna && v.base == "T", values(thy))
            # blank chain id: the chain is the empty string
            B = legacyNucleotidesInFile(wr(dir, "b.pdb", inchain(ade, ' ')))
            @test sort(collect(keys(B))) == [("", "1"), ("", "2"), ("", "3")]
            # free bases, a single residue without P, a lone ligand: none
            base = hetero(rename(atomsIn(residue(rna, 2), _BASE_ADENINE), "ADE"))
            @test isempty(legacyNucleotidesInFile(wr(dir, "free.pdb", base)))
            @test isempty(legacyNucleotidesInFile(wr(dir, "none.pdb", rna)))
            @test isempty(legacyNucleotidesInFile(wr(dir, "empty.pdb", String[])))
            # short and odd lines are skipped
            odd = ["ATOM", "HETATM", "REMARK 1", ade[1][1:20], ade[1][1:26], "TER", ade...]
            @test legacyNucleotidesInFile(wr(dir, "odd.pdb", odd)) == L
            # an unreadable file is a SystemError
            @test_throws SystemError legacyNucleotidesInFile(joinpath(dir, "absent.pdb"))
            # the model reading agrees with the file reading
            for lines in (ade, hetero(ade), dna, inchain(ade, 'B'),
                [inchain(ade, 'A'); inchain(rename(rna, "URI"), 'B')])
                path = wr(dir, "m.pdb", lines)
                model = first(collectmodels(BioStructures.read(path, PDBFormat)))
                @test legacyNucleotidesInModel(model) == legacyNucleotidesInFile(path)
            end
            # many residues of two chains
            both = [inchain(ade, 'A'); inchain(rename(rna, "GUA"), 'B')]
            path = wr(dir, "two.pdb", both)
            @test length(legacyNucleotidesInFile(path)) == 6
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "the loader keeps legacy-named HETATM residues only by the rule" begin
        dir = mktempdir()
        try
            rna = _residues("1SDR", 'A', 1:3)
            heavyRna = length(rna)
            ligand = hetero(rename(atomsIn(residue(rna, 2), _BASE_ADENINE), "ADE"))
            @test length(ligand) == 10
            # HETATM nucleotide under legacy names: kept
            het = hetero(rename(rna, "ADE"))
            @test nAtoms(loadMolecule(wr(dir, "het.pdb", het))) == heavyRna
            # as ATOM records: kept as always
            @test nAtoms(loadMolecule(wr(dir, "atom.pdb", rename(rna, "ADE")))) ==
                  heavyRna
            # a free base ligand is not a nucleotide: with the polymer alone nothing is left
            # (a ligand since 2026-11-11, kept by default: its 10 heavy atoms) ...
            lig = wr(dir, "lig.pdb", ligand)
            @test_throws MoleculeError loadMolecule(lig; ligands = false)
            @test nAtoms(loadMolecule(lig)) == 10
            # ... beside a real RNA: the RNA alone, or the RNA and the ligand
            rl = wr(dir, "rl.pdb", [rna; inchain(ligand, 'B')])
            @test nAtoms(loadMolecule(rl; ligands = false)) == heavyRna
            @test nAtoms(loadMolecule(rl)) == heavyRna + 10
            # one residue of four backbone atoms, alone: not a nucleotide (a ligand by
            # default); with a mate: kept
            four = ["O5'", "C5'", "C4'", "O4'"]
            r2 = hetero(rename(atomsIn(residue(rna, 2), four), "ADE"))
            r3 = hetero(rename(atomsIn(residue(rna, 3), four), "ADE"))
            one = wr(dir, "one.pdb", r2)
            @test_throws MoleculeError loadMolecule(one; ligands = false)
            @test nAtoms(loadMolecule(one)) == 4
            @test nAtoms(loadMolecule(wr(dir, "mate.pdb", [r2; r3]))) == 8
            # a P atom: kept alone
            @test nAtoms(
                loadMolecule(wr(dir, "p.pdb", hetero(rename(residue(rna, 2), "ADE")))),
            ) ==
                  length(residue(rna, 2))
            # waters beside it are dropped as ever, an ion is a ligand and kept
            ion = replace(ION, " A " => " B ")
            wat = replace(WATER, " A " => " B ")
            iw = wr(dir, "iw.pdb", [het; ion; wat])
            @test nAtoms(loadMolecule(iw; ligands = false)) == heavyRna
            @test nAtoms(loadMolecule(iw)) == heavyRna + 1
            # the selector is the model selector: nucleotideSelector alone would drop them
            path = wr(dir, "sel.pdb", het)
            model = first(collectmodels(BioStructures.read(path, PDBFormat)))
            ats = BioStructures.collectatoms(model)
            @test count(nucleotideSelector, ats) == 0
            @test count(_modelSelector(model), ats) == heavyRna
            @test count(_modelSelector(model; ligands = false), ats) == heavyRna
            # a model without any legacy name takes the plain nucleotide selector
            plain =
                first(collectmodels(BioStructures.read(wr(dir, "pl.pdb", rna), PDBFormat)))
            @test _modelSelector(plain; ligands = false) === polymerSelector
            @test _modelSelector(plain) === ligandSelector
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "relabelling for pdb2pqr" begin
        dir = mktempdir()
        try
            # RNA atoms: ADE URI GUA CYT become A U G C; DNA atoms: DA, DT for THY
            rna = _residues("1SDR", 'A', 1:3)
            mixed = [rename(residue(rna, 1), "URI"); rename(residue(rna, 2), "ADE");
                rename(residue(rna, 3), "GUA")]
            src = wr(dir, "r.pdb", mixed)
            out = joinpath(dir, "r.out.pdb")
            r = relabelModified(src, out)
            @test r.noBase == 0
            @test Dict(k => v.name for (k, v) in r.plan) ==
                  Dict(("A", "1") => "URI", ("A", "2") => "ADE", ("A", "3") => "GUA")
            @test unique(nameOf(l) for l in readlines(out) if l[23:26] == "   1") == ["U"]
            @test unique(nameOf(l) for l in readlines(out) if l[23:26] == "   2") == ["A"]
            @test unique(nameOf(l) for l in readlines(out) if l[23:26] == "   3") == ["G"]
            restoreModified!(out, r.plan)
            @test readlines(out) == mixed
            # HETATM legacy residues become ATOM for the run and HETATM again
            het = hetero(mixed)
            src = wr(dir, "h.pdb", het)
            r = relabelModified(src, out)
            @test all(l -> startswith(l, "ATOM  "), readlines(out))
            restoreModified!(out, r.plan)
            @test readlines(out) == het
            # DNA atoms
            dna = _residues("1BNA", 'A', 1:3)        # DC DG DC
            src = wr(
                dir,
                "d.pdb",
                [rename(residue(dna, 1), "ADE"); rename(residue(dna, 2), "THY");
                    rename(residue(dna, 3), "CYT")],
            )
            r = relabelModified(src, out)
            @test [
                unique(nameOf(l) for l in readlines(out) if l[23:26] == lpad(n, 4))
                for n in 1:3
            ] == [["DA"], ["DT"], ["DC"]]
            # a free base is left alone
            ligand = hetero(rename(atomsIn(residue(rna, 2), _BASE_ADENINE), "ADE"))
            src = wr(dir, "free.pdb", [rna; inchain(ligand, 'B')])
            r = relabelModified(src, out)
            @test isempty(r.plan) && r.noBase == 0
            @test readlines(out) == readlines(src)
            # hydrogenationChoice names the rule
            @test hydrogenationChoice(
                component.(residueNames(wr(dir, "c.pdb", mixed))), wr(dir, "c.pdb", mixed),
            ).reason == "3 legacy-named nucleotide residues (ADE, GUA, URI)"
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "SASDT55 and SASDG24" begin
        L = legacyNucleotidesInFile(_T55)
        @test length(L) == 24
        @test sort(unique(v.name for v in values(L))) == ["ADE", "CYT", "GUA", "URI"]
        @test all(v -> v.class === :rna, values(L))
        @test Dict(
            n => count(v -> v.name == n, values(L)) for n in ("ADE", "CYT", "GUA", "URI")
        ) ==
              Dict("ADE" => 10, "CYT" => 1, "GUA" => 3, "URI" => 10)
        infos = component.(residueNames(_T55))
        @test hydrogenationChoice(infos, _T55) == (
            content = :mixed, ff = :parse, titration = :propka,
            reason = "24 legacy-named nucleotide residues (ADE, CYT, GUA, URI)",
        )
        # the file already carries 532 hydrogens (by atom name); the loader reads them all
        namesH = count(
            l -> startswith(l, "ATOM") && startswith(strip(l[13:16]), "H"),
            eachline(_T55),
        )
        @test namesH == 532
        @test nAtoms(loadMolecule(_T55)) == 2173

        G = legacyNucleotidesInFile(_G24)
        @test length(G) == 423
        @test sort(unique(v.name for v in values(G))) == ["ADE", "CYT", "GUA", "URI"]
        @test all(v -> v.class === :rna, values(G))
        @test nAtoms(loadMolecule(_G24)) == 12366
        @test hydrogenationChoice(component.(residueNames(_G24)), _G24).reason ==
              "423 legacy-named nucleotide residues (ADE, CYT, GUA, URI)"
    end

    # pdb2pqr (and PROPKA: the file has protein) on SASDT55
    @testset "pdb2pqr on SASDT55 keeps and completes the legacy residues" begin
        dir = mktempdir()
        path = joinpath(dir, "nt-legacy-t55.pdb")
        cp(_T55, path)
        try
            hp = resolveHydrogens(path, 7.4; titration = Propka())
            out = [
                l for l in eachline(hp) if startswith(l, "ATOM") || startswith(l, "HETATM")
            ]
            @test nAtoms(loadMolecule(hp)) == 3022
            @test count(isH, out) == 1381
            leg = filter(l -> nameOf(l) in ("ADE", "CYT", "GUA", "URI"), out)
            # names and record types are the original ones; none was left out
            @test all(l -> startswith(l, "ATOM  "), leg)
            @test length(unique(l[22] * strip(l[23:27]) for l in leg)) == 24
            per = Dict{Tuple{String,String},Int}()
            for l in leg
                k = (String(nameOf(l)), l[22] * strip(l[23:27]))
                per[k] = get(per, k, 0) + isH(l)
            end
            for (n, expect) in
                (("ADE", [11]), ("URI", [10]), ("GUA", [11, 12]), ("CYT", [12]))
                @test all(v -> v in expect, [v for (k, v) in per if k[1] == n])
            end
            @test sum(values(per)) == 10 * 11 + 10 * 10 + (11 + 11 + 12) + 12
            # the heavy atoms are those of the input (hydrogens were re-placed)
            @test count(!isH, out) == 3022 - 1381
        finally
            purgeStore("nt-legacy-")
            rm(dir; recursive = true, force = true)
        end
    end
end

end # module
