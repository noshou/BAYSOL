# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises the legacy residue names of nucleotides (ADE GUA CYT URI THY, in older and
# CHARMM-style files such as the SASBDB models SASDT55 and SASDG24): src/MolecularStructure/
# Components.jl (`_legacy_nucleotides`, `legacy_nucleotides_in_file`,
# `legacy_nucleotides_in_model`, the loader's selector) and their relabelling for
# pdb2pqr (src/Hydrogenator/Modified.jl). In the dictionary these ids are the free bases
# (ligands), so a residue under one of them is a nucleotide only if it carries the
# sugar-phosphate backbone. Synthetic files are cut from 1SDR (RNA) and 1BNA (DNA); the
# pdb2pqr run on SASDT55 needs the CondaPkg tools (like test_pdb2pqr.jl), no network.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

# Everything below lives in a module of its own, so that the helpers and constants of this
# file cannot clash with those of another file when the aggregator includes them all into
# Main.
module NtTest_legacy_nucleotides

using Test
using BAYSOL

using Printf: @sprintf

using BAYSOL.MolecularStructure: LEGACY_NUCLEOTIDE_NAMES, BACKBONE_ATOMS, BACKBONE_MIN,
    _legacy_nucleotides, legacy_nucleotides_in_file, legacy_nucleotides_in_model,
    load_molecule, n_atoms, MoleculeError, component, is_nucleotide, nucleotide_selector,
    polymer_selector,
    _model_selector, residue_names, _store_dir
using BAYSOL.Hydrogenator: relabel_modified, restore_modified!, hydrogenation_choice,
    resolve_hydrogens, Propka, _hydrogens_path, _pka_path
using BioStructures: BioStructures, PDBFormat, collectmodels

const _FIXTURES = joinpath(@__DIR__, "..", "..", "fixtures")
const _T55 = joinpath(_FIXTURES, "experiments", "SASDT55", "SASDT55_fit1_model1.pdb")
const _G24 = joinpath(_FIXTURES, "experiments", "SASDG24", "SASDG24_fit2_model1.pdb")

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
atoms_in(lines, names) = [l for l in lines if strip(l[13:16]) in names]
name_of(l) = strip(l[18:20])
is_h(l) = strip(l[77:min(end, 78)]) in ("H", "D")
# remove the store files of the stems starting with `prefix`
function purge_store(prefix)
    for f in readdir(_store_dir())
        startswith(f, prefix) &&
            rm(joinpath(_store_dir(), f); force = true, recursive = true)
    end
end
function wr(dir, name, lines)
    path = joinpath(dir, name)
    write(path, join(lines, "\n") * "\n")
    return path
end

# records as _legacy_nucleotides takes them: (chain, number, residue name, atom name)
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
            @test !is_nucleotide(n)
        end
        @test BACKBONE_MIN == 4 && length(BACKBONE_ATOMS) == 8 && "P" in BACKBONE_ATOMS
    end

    @testset "_legacy_nucleotides: the rule on atom records" begin
        full = ["P", "OP1", "O5'", "C5'", "C4'", "O4'", "C3'", "C2'", "C1'", "N9"]
        f(rs) = _legacy_nucleotides(rs)
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
        rna_atoms = [full; "O2'"]
        @test f(recs("A", "1", "THY", rna_atoms))[("A", "1")].class === :dna
        @test f(recs("A", "1", "THY", full))[("A", "1")].base == "T"
        @test f(recs("A", "1", "URI", full))[("A", "1")].class === :rna
        @test f(recs("A", "1", "URI", full))[("A", "1")].base == "U"
        for (n, b) in (("ADE", "A"), ("GUA", "G"), ("CYT", "C"))
            @test f(recs("A", "1", n, rna_atoms))[("A", "1")] ==
                  (name = n, class = :rna, base = b)
            @test f(recs("A", "1", n, full))[("A", "1")] ==
                  (name = n, class = :dna, base = b)
            # the old star spelling of the 2' oxygen is the same atom
            @test f(recs("A", "1", n, [full; "O2*"]))[("A", "1")].class === :rna
        end
        # two names for one residue key: the first record's name stays
        @test length(f([recs("A", "1", "ADE", full); recs("A", "1", "GUA", ["N9"])])) == 1
    end

    @testset "legacy_nucleotides_in_file on synthetic files" begin
        dir = mktempdir()
        try
            rna = _residues("1SDR", 'A', 1:3)          # U A A, the first without P
            ade = rename(rna, "ADE")
            L = legacy_nucleotides_in_file(wr(dir, "a.pdb", ade))
            @test sort(collect(keys(L))) == [("A", "1"), ("A", "2"), ("A", "3")]
            @test all(v -> v.name == "ADE" && v.class === :rna && v.base == "A", values(L))
            # HETATM records are read the same
            @test legacy_nucleotides_in_file(wr(dir, "h.pdb", hetero(ade))) == L
            # a lower case name is the same name
            @test legacy_nucleotides_in_file(wr(dir, "l.pdb", rename(rna, "ade"))) == L
            # DNA atoms (no O2'): DNA class
            dna = rename(_residues("1BNA", 'A', 1:3), "ADE")
            D = legacy_nucleotides_in_file(wr(dir, "d.pdb", dna))
            @test length(D) == 3 && all(v -> v.class === :dna, values(D))
            thy = legacy_nucleotides_in_file(wr(dir, "t.pdb", rename(rna, "THY")))
            @test all(v -> v.class === :dna && v.base == "T", values(thy))
            # blank chain id: the chain is the empty string
            B = legacy_nucleotides_in_file(wr(dir, "b.pdb", inchain(ade, ' ')))
            @test sort(collect(keys(B))) == [("", "1"), ("", "2"), ("", "3")]
            # free bases, a single residue without P, a lone ligand: none
            base = hetero(rename(atoms_in(residue(rna, 2), _BASE_ADENINE), "ADE"))
            @test isempty(legacy_nucleotides_in_file(wr(dir, "free.pdb", base)))
            @test isempty(legacy_nucleotides_in_file(wr(dir, "none.pdb", rna)))
            @test isempty(legacy_nucleotides_in_file(wr(dir, "empty.pdb", String[])))
            # short and odd lines are skipped
            odd = ["ATOM", "HETATM", "REMARK 1", ade[1][1:20], ade[1][1:26], "TER", ade...]
            @test legacy_nucleotides_in_file(wr(dir, "odd.pdb", odd)) == L
            # an unreadable file is a SystemError
            @test_throws SystemError legacy_nucleotides_in_file(joinpath(dir, "absent.pdb"))
            # the model reading agrees with the file reading
            for lines in (ade, hetero(ade), dna, inchain(ade, 'B'),
                [inchain(ade, 'A'); inchain(rename(rna, "URI"), 'B')])
                path = wr(dir, "m.pdb", lines)
                model = first(collectmodels(BioStructures.read(path, PDBFormat)))
                @test legacy_nucleotides_in_model(model) == legacy_nucleotides_in_file(path)
            end
            # many residues of two chains
            both = [inchain(ade, 'A'); inchain(rename(rna, "GUA"), 'B')]
            path = wr(dir, "two.pdb", both)
            @test length(legacy_nucleotides_in_file(path)) == 6
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "the loader keeps legacy-named HETATM residues only by the rule" begin
        dir = mktempdir()
        try
            rna = _residues("1SDR", 'A', 1:3)
            heavy_rna = length(rna)
            ligand = hetero(rename(atoms_in(residue(rna, 2), _BASE_ADENINE), "ADE"))
            @test length(ligand) == 10
            # HETATM nucleotide under legacy names: kept
            het = hetero(rename(rna, "ADE"))
            @test n_atoms(load_molecule(wr(dir, "het.pdb", het))) == heavy_rna
            # as ATOM records: kept as always
            @test n_atoms(load_molecule(wr(dir, "atom.pdb", rename(rna, "ADE")))) ==
                  heavy_rna
            # a free base ligand: dropped (HETATM, not a nucleotide) ...
            # nothing is left
            @test_throws MoleculeError load_molecule(wr(dir, "lig.pdb", ligand))
            # ... beside a real RNA: dropped, the RNA kept
            @test n_atoms(load_molecule(wr(dir, "rl.pdb", [rna; inchain(ligand, 'B')]))) ==
                  heavy_rna
            # one residue of four backbone atoms, alone: dropped; with a mate: kept
            four = ["O5'", "C5'", "C4'", "O4'"]
            r2 = hetero(rename(atoms_in(residue(rna, 2), four), "ADE"))
            r3 = hetero(rename(atoms_in(residue(rna, 3), four), "ADE"))
            @test_throws MoleculeError load_molecule(wr(dir, "one.pdb", r2))
            @test n_atoms(load_molecule(wr(dir, "mate.pdb", [r2; r3]))) == 8
            # a P atom: kept alone
            @test n_atoms(
                load_molecule(wr(dir, "p.pdb", hetero(rename(residue(rna, 2), "ADE")))),
            ) ==
                  length(residue(rna, 2))
            # waters and ions beside it are dropped as ever
            ion = replace(ION, " A " => " B ")
            wat = replace(WATER, " A " => " B ")
            @test n_atoms(load_molecule(wr(dir, "iw.pdb", [het; ion; wat]))) == heavy_rna
            # the selector is the model selector: nucleotide_selector alone would drop them
            path = wr(dir, "sel.pdb", het)
            model = first(collectmodels(BioStructures.read(path, PDBFormat)))
            ats = BioStructures.collectatoms(model)
            @test count(nucleotide_selector, ats) == 0
            @test count(_model_selector(model), ats) == heavy_rna
            # a model without any legacy name takes the plain nucleotide selector
            plain =
                first(collectmodels(BioStructures.read(wr(dir, "pl.pdb", rna), PDBFormat)))
            @test _model_selector(plain) === polymer_selector
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
            r = relabel_modified(src, out)
            @test r.no_base == 0
            @test Dict(k => v.name for (k, v) in r.plan) ==
                  Dict(("A", "1") => "URI", ("A", "2") => "ADE", ("A", "3") => "GUA")
            @test unique(name_of(l) for l in readlines(out) if l[23:26] == "   1") == ["U"]
            @test unique(name_of(l) for l in readlines(out) if l[23:26] == "   2") == ["A"]
            @test unique(name_of(l) for l in readlines(out) if l[23:26] == "   3") == ["G"]
            restore_modified!(out, r.plan)
            @test readlines(out) == mixed
            # HETATM legacy residues become ATOM for the run and HETATM again
            het = hetero(mixed)
            src = wr(dir, "h.pdb", het)
            r = relabel_modified(src, out)
            @test all(l -> startswith(l, "ATOM  "), readlines(out))
            restore_modified!(out, r.plan)
            @test readlines(out) == het
            # DNA atoms
            dna = _residues("1BNA", 'A', 1:3)        # DC DG DC
            src = wr(
                dir,
                "d.pdb",
                [rename(residue(dna, 1), "ADE"); rename(residue(dna, 2), "THY");
                    rename(residue(dna, 3), "CYT")],
            )
            r = relabel_modified(src, out)
            @test [
                unique(name_of(l) for l in readlines(out) if l[23:26] == lpad(n, 4))
                for n in 1:3
            ] == [["DA"], ["DT"], ["DC"]]
            # a free base is left alone
            ligand = hetero(rename(atoms_in(residue(rna, 2), _BASE_ADENINE), "ADE"))
            src = wr(dir, "free.pdb", [rna; inchain(ligand, 'B')])
            r = relabel_modified(src, out)
            @test isempty(r.plan) && r.no_base == 0
            @test readlines(out) == readlines(src)
            # hydrogenation_choice names the rule
            @test hydrogenation_choice(
                component.(residue_names(wr(dir, "c.pdb", mixed))), wr(dir, "c.pdb", mixed),
            ).reason == "3 legacy-named nucleotide residues (ADE, GUA, URI)"
        finally
            rm(dir; recursive = true, force = true)
        end
    end

    @testset "SASDT55 and SASDG24" begin
        L = legacy_nucleotides_in_file(_T55)
        @test length(L) == 24
        @test sort(unique(v.name for v in values(L))) == ["ADE", "CYT", "GUA", "URI"]
        @test all(v -> v.class === :rna, values(L))
        @test Dict(
            n => count(v -> v.name == n, values(L)) for n in ("ADE", "CYT", "GUA", "URI")
        ) ==
              Dict("ADE" => 10, "CYT" => 1, "GUA" => 3, "URI" => 10)
        infos = component.(residue_names(_T55))
        @test hydrogenation_choice(infos, _T55) == (
            content = :mixed, ff = :parse, titration = :propka,
            reason = "24 legacy-named nucleotide residues (ADE, CYT, GUA, URI)",
        )
        # the file already carries 532 hydrogens (by atom name); the loader reads them all
        names_h = count(
            l -> startswith(l, "ATOM") && startswith(strip(l[13:16]), "H"),
            eachline(_T55),
        )
        @test names_h == 532
        @test n_atoms(load_molecule(_T55)) == 2173

        G = legacy_nucleotides_in_file(_G24)
        @test length(G) == 423
        @test sort(unique(v.name for v in values(G))) == ["ADE", "CYT", "GUA", "URI"]
        @test all(v -> v.class === :rna, values(G))
        @test n_atoms(load_molecule(_G24)) == 12366
        @test hydrogenation_choice(component.(residue_names(_G24)), _G24).reason ==
              "423 legacy-named nucleotide residues (ADE, CYT, GUA, URI)"
    end

    # pdb2pqr (and PROPKA: the file has protein) on SASDT55
    @testset "pdb2pqr on SASDT55 keeps and completes the legacy residues" begin
        dir = mktempdir()
        path = joinpath(dir, "nt-legacy-t55.pdb")
        cp(_T55, path)
        try
            hp = resolve_hydrogens(path, 7.4; titration = Propka())
            out = [
                l for l in eachline(hp) if startswith(l, "ATOM") || startswith(l, "HETATM")
            ]
            @test n_atoms(load_molecule(hp)) == 3022
            @test count(is_h, out) == 1381
            leg = filter(l -> name_of(l) in ("ADE", "CYT", "GUA", "URI"), out)
            # names and record types are the original ones; none was left out
            @test all(l -> startswith(l, "ATOM  "), leg)
            @test length(unique(l[22] * strip(l[23:27]) for l in leg)) == 24
            per = Dict{Tuple{String,String},Int}()
            for l in leg
                k = (String(name_of(l)), l[22] * strip(l[23:27]))
                per[k] = get(per, k, 0) + is_h(l)
            end
            for (n, expect) in
                (("ADE", [11]), ("URI", [10]), ("GUA", [11, 12]), ("CYT", [12]))
                @test all(v -> v in expect, [v for (k, v) in per if k[1] == n])
            end
            @test sum(values(per)) == 10 * 11 + 10 * 10 + (11 + 11 + 12) + 12
            # the heavy atoms are those of the input (hydrogens were re-placed)
            @test count(!is_h, out) == 3022 - 1381
        finally
            purge_store("nt-legacy-")
            rm(dir; recursive = true, force = true)
        end
    end
end

end # module
