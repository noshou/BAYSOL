# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises the modified amino acids (MSE, SEP, PTR, TYC, D residues, ...): the component
# predicates `isAminoAcid` and `aminoParent` (src/molecular-structure/components.jl), the
# loader that keeps their HETATM records (`polymerSelector`), and their hydrogenation
# through the standard parent (src/hydrogenator/modified.jl and content.jl): the relabel and
# restore round trip, the selenium alias (`SE` runs as `SD`), the rule for incomplete
# residues, D amino acids, and the stage `modified amino acid hydrogens` of the timing log.
# The inputs are synthetic files derived from the fixture 7RSA (ribonuclease A, 951 heavy
# atoms, 1856 atoms with hydrogens): a methionine renamed MSE, an alanine mirrored into a D
# residue, a tyrosine renamed TYC, all residues written as HETATM. The pdb2pqr runs need the
# CondaPkg tools (and PROPKA) like test-pdb2pqr.jl; no network. Files that are run through
# pdb2pqr have their own stems (`nt-amino-*`), removed at the end.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

module NtTest_modified_amino

using Test
using BAYSOL
using Random
using BAYSOL.BulkElectronDensity: NonBiological, Solute
using Printf: @sprintf
using BAYSOL.MolecularStructure: component, isAminoAcid, aminoParent, isNucleotide,
    polymerSelector, nucleotideSelector, loadMolecule, nAtoms, elms, coordsCartesian,
    radii, resloveStruct, LocalPathSource, residueNames, _storeDir, _WARNED,
    STANDARD_AMINO_ACIDS, _resolveParent, _AMINO_PARENTS, _isAminoType,
    _COMPONENT_DOWNLOAD, _COMPONENT_MEMO, _ComponentNotFound
using BAYSOL.Hydrogenator: relabelModified, restoreModified!, resolveHydrogens, Propka,
    hasModifiedAmino, modedAaHyd, AMINO_ATOM_ALIASES, STANDARD_AMINO_ATOMS,
    _runsAsParent, _aminoRunAs, hydrogenationChoice, heavyAtomCount
using BAYSOL.Runtime: force
using BioStructures:
    BioStructures, PDBFormat, collectmodels, collectatoms, resname, atomname

const SRC = joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "7RSA-TEST.pdb")
const LINES = readlines(SRC)

resOf(l) = strip(l[23:27])
nameOf(l) = strip(l[18:20])
atomOf(l) = strip(l[13:16])
isAtomLine(l) = startswith(l, "ATOM") || startswith(l, "HETATM")
isH(l) = strip(l[77:min(end, 78)]) in ("H", "D")
heavyLines(lines) = [l for l in lines if isAtomLine(l) && !isH(l)]

# a line with another record type / residue name / atom name / element
function edit(l; rec = nothing, name = nothing, atom = nothing, elem = nothing)
    rec === nothing || (l = rpad(rec, 6) * l[7:end])
    name === nothing || (l = l[1:17] * lpad(name, 3) * l[21:end])
    atom === nothing || (l = l[1:12] * atom * l[17:end])
    if elem !== nothing
        l = rpad(l, 78)
        l = l[1:76] * lpad(elem, 2) * l[79:end]
    end
    return l
end
firstResidue(name) =
    first(resOf(l) for l in LINES if startswith(l, "ATOM") && nameOf(l) == name)
const MET1 = firstResidue("MET")
const ALA1 = firstResidue("ALA")
const TYR1 = firstResidue("TYR")
const CYS1 = firstResidue("CYS")
const LYS1 = firstResidue("LYS")

# the residue `num` renamed `newname` with record `rec`; `f(line)` may change each line
function renamed(num, newname, rec; f = identity, drop = ())
    out = String[]
    for l in LINES
        if startswith(l, "ATOM") && resOf(l) == num
            atomOf(l) in drop && continue
            l = f(edit(l; rec, name = newname))
        end
        push!(out, l)
    end
    return out
end
# MET -> MSE, SD -> SE (element SE)
mse(rec) = renamed(MET1, "MSE", rec;
    f = l -> atomOf(l) == "SD" ? edit(l; atom = " SE ", elem = "SE") : l)
# CYS -> CSE, SG -> SE
cse(rec) = renamed(CYS1, "CSE", rec;
    f = l -> atomOf(l) == "SG" ? edit(l; atom = " SE ", elem = "SE") : l)
tyc(rec) = renamed(TYR1, "TYC", rec)
allhet() = [startswith(l, "ATOM") ? edit(l; rec = "HETATM") : l for l in LINES]

# a D alanine: the first ALA with its CB mirrored through the N-CA-C plane, named 2RA
function dala()
    xyz(l) = parse.(Float64, (l[31:38], l[39:46], l[47:54]))
    atoms =
        Dict(atomOf(l) => l for l in LINES if startswith(l, "ATOM") && resOf(l) == ALA1)
    N, ca, C, cb = (xyz(atoms[k]) for k in ("N", "CA", "C", "CB"))
    cross(a, b) =
        [a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1]]
    n = cross(N .- ca, C .- ca)
    n ./= sqrt(sum(abs2, n))
    d = sum((cb .- ca) .* n)
    cBm = cb .- 2d .* n
    return renamed(ALA1, "2RA", "HETATM";
        f = l ->
            atomOf(l) == "CB" ?
            l[1:30] * @sprintf("%8.3f%8.3f%8.3f", cBm...) * l[55:end] : l)
end

function wr(dir, name, lines)
    path = joinpath(dir, name)
    write(path, join(lines, "\n") * "\n")
    return path
end
function purgeStore(prefix)
    for f in readdir(_storeDir())
        startswith(f, prefix) &&
            rm(joinpath(_storeDir(), f); force = true, recursive = true)
    end
end

@testset "modified amino acids" begin
    dir = mktempdir()
    savedHook = _COMPONENT_DOWNLOAD[]
    _COMPONENT_DOWNLOAD[] = (url, dest) -> throw(_ComponentNotFound(url))
    empty!(_COMPONENT_MEMO)

    try
        @testset "isAminoAcid" begin
            # standard, modified, D, plain peptide linking, termini
            for id in
                ("ALA", "GLY", "MSE", "SEP", "TPO", "PTR", "CSO", "MLY", "HSE", "SEC",
                "2RA", "DAL", "DCY", "DTH", "TYC", "mse", " ser ")
                @test isAminoAcid(id)
            end
            for t in ("l-peptide linking", "d-peptide linking", "peptide linking",
                "l-peptide cooh carboxy terminus", "l-peptide nh3 amino terminus",
                "d-peptide nh3 amino terminus")
                @test _isAminoType(t)
            end
            @test component("TYC").type == "l-peptide cooh carboxy terminus"
            @test isAminoAcid("0YG")                 # an amino terminus type
            # no: peptide-like, UNK, waters, ligands, saccharides, nucleotides, ions
            for t in ("peptide-like", "non-polymer", "d-saccharide", "rna linking",
                "l-saccharide", "")
                @test !_isAminoType(t)
            end
            for id in ("UNK", "unk", "HOH", "WAT", "DOD", "H2O", "NAG", "GLC", "ATP", "MG",
                "ZN", "PSU", "DA", "DAD", "DGU", "FOR", "ACE", "NH2", "TTD")
                @test !isAminoAcid(id)
            end
            # a name the dictionary does not know is not one (the fake hook says "no such")
            @test !isAminoAcid("QQQQ")
            # amino acids are not nucleotides and conversely
            @test !isNucleotide("MSE") && !isAminoAcid("A")
        end

        @testset "aminoParent" begin
            for (id, p) in (("MSE", "MET"), ("SEP", "SER"), ("PTR", "TYR"), ("TYC", "TYR"),
                ("TPO", "THR"), ("CSO", "CYS"), ("MLY", "LYS"), ("HSE", "SER"),
                ("CSE", "CYS"), ("2RA", "ALA"), ("mse", "MET"))
                @test aminoParent(id) == p
            end
            # the standard names are their own, not children of anything
            @test all(aminoParent(a) === nothing for a in STANDARD_AMINO_ACIDS)
            # not amino acids, unknown, or no resolvable parent: nothing
            for id in ("HOH", "UNK", "PSU", "NAG", "QQQQ", "SEC", "DAL", "DCY", "DTH")
                @test aminoParent(id) === nothing
            end
            @test aminoParent("175") === nothing     # ALA, SER, GLY: several parents
            @test aminoParent("0YG") === nothing     # TYR, GLY
            table = force(_AMINO_PARENTS)
            @test all(p -> p in STANDARD_AMINO_ACIDS, values(table))
            @test length(table) > 1000
            # a non-standard parent is followed up to a standard one, a cycle or several
            # different parents give none (the same rule as the nucleotides')
            raw = Dict("XA" => "XB", "XB" => "SER", "XC" => "XD", "XD" => "XC",
                "XE" => "ALA, SER", "XF" => "SER, SER")
            up(id) = _resolveParent(
                raw[id], q -> get(raw, q, nothing); standard = STANDARD_AMINO_ACIDS)
            @test up("XA") == "SER" && up("XF") == "SER"
            @test up("XC") === nothing && up("XE") === nothing
            # D residues: some declare a parent (2RA, alanine), they are still D
            @test startswith(component("2RA").type, "d-")
            @test _aminoRunAs(component("2RA")) === nothing      # not run as an L parent
            @test _aminoRunAs(component("MSE")) == "MET"
            @test _aminoRunAs(component("HOH")) === nothing
        end

        @testset "polymerSelector and the loader" begin
            path = wr(dir, "sel.pdb", mse("HETATM"))
            model = first(collectmodels(BioStructures.read(path, PDBFormat)))
            ats = collectatoms(model)
            kept(r) = count(a -> resname(a) == r && polymerSelector(a), ats)
            total(r) = count(a -> resname(a) == r, ats)
            @test total("MSE") == kept("MSE") > 0
            @test count(nucleotideSelector, ats) < count(polymerSelector, ats)  # MSE only
            @test kept("ALA") == total("ALA") > 0
            # a water is dropped; an ion, a ligand, a saccharide and UNK are kept (every
            # non-water HETATM group, 2026-11-13)
            function het(name, atom, elem, n)
                l = edit(first(l for l in LINES if startswith(l, "ATOM")); rec = "HETATM",
                    name, atom, elem)
                return l[1:22] * lpad(n, 4) * l[27:end]
            end
            extra = [het("HOH", " O  ", "O", 901), het("MG", "MG  ", "MG", 902),
                het("ATP", " PG ", "P", 903), het("NAG", " C1 ", "C", 904),
                het("UNK", " CA ", "C", 905), het("ZN", "ZN  ", "ZN", 906)]
            path = wr(dir, "mix.pdb", [mse("HETATM"); extra])
            empty!(_WARNED)
            mol = @test_logs (:info,
                Regex(
                    "kept modified amino acids from the HETATM records \\(MSE: 1 residue",
                )) (:info,
                Regex(
                    "kept ligands from the HETATM records \\(ATP: 1 residue\\(s\\), " *
                    "MG: 1 residue\\(s\\), NAG: 1 residue\\(s\\), TBU: 1 residue\\(s\\), " *
                    "UNK: 1 residue\\(s\\), ZN: 1 residue",
                )) (:warn, r"without component data \(UNK: 1 residue") loadMolecule(path)
            # once per structure
            @test_logs loadMolecule(path)
            ref = loadMolecule(wr(dir, "ref.pdb", LINES))
            # MSE kept, five ligands more than the reference, the water dropped; the
            # reference has a TBU (tert-butanol, 15 atoms) of 7RSA, a ligand that is kept
            @test nAtoms(mol) == nAtoms(ref) + 5
            @test nAtoms(loadMolecule(path; ligands = false)) == nAtoms(ref) - 15
            @test count(e -> lowercase(e) == "se", elms(mol)) == 1
            # the same through resloveStruct for a .pdb (used in place) and a .cif
            @test nAtoms(loadMolecule(resloveStruct(LocalPathSource(path)))) ==
                  nAtoms(ref) + 5
            # all residues written as HETATM: all kept
            @test nAtoms(loadMolecule(wr(dir, "het.pdb", allhet()))) == nAtoms(ref)
        end

        @testset "relabel and restore: amino acids" begin
            for rec in ("HETATM", "ATOM")
                lines = mse(rec)
                src = wr(dir, "m$rec.pdb", lines)
                out = joinpath(dir, "m$rec.out.pdb")
                r = relabelModified(src, out)
                key = ("A", MET1)
                @test collect(keys(r.plan)) == [key]
                @test r.plan[key].name == "MSE" && strip(r.plan[key].record) == rec
                @test r.noParentAmino == 0 && r.noBase == 0
                @test length(r.aliases) == 1
                relabelled = readlines(out)
                met = [l for l in relabelled if resOf(l) == MET1 && isAtomLine(l)]
                @test unique(nameOf.(met)) == ["MET"]
                @test unique(l[1:6] for l in met) == ["ATOM  "]
                # the selenium runs as sulfur-delta, element S
                sd = only(l for l in met if atomOf(l) == "SD")
                @test strip(sd[77:78]) == "S"
                @test sd[31:54] ==
                      only(l for l in lines if isAtomLine(l) && atomOf(l) == "SE")[31:54]
                @test !any(l -> atomOf(l) == "SE", met)
                # restoring the (here unchanged) output gives the original lines back
                restoreModified!(out, r.plan, r.aliases)
                @test readlines(out) == lines
            end
            # the alias table
            @test AMINO_ATOM_ALIASES == Dict(("MET", "SE") => "SD", ("CYS", "SE") => "SG")
            # CYS -> CSE: SE runs as SG
            lines = cse("HETATM")
            src = wr(dir, "cse.pdb", lines)
            out = joinpath(dir, "cse.out.pdb")
            r = relabelModified(src, out)
            @test length(r.aliases) == 1 && r.noParentAmino == 0
            cys = [l for l in readlines(out) if resOf(l) == CYS1 && isAtomLine(l)]
            @test unique(nameOf.(cys)) == ["CYS"] && any(l -> atomOf(l) == "SG", cys)
            restoreModified!(out, r.plan, r.aliases)
            @test readlines(out) == lines
            # TYC: a terminal variant is run as its parent like any other
            lines = tyc("HETATM")
            src = wr(dir, "tyc.pdb", lines)
            r = relabelModified(src, joinpath(dir, "tyc.out.pdb"))
            @test collect(keys(r.plan)) == [("A", TYR1)] && isempty(r.aliases)
            tyr = [
                l for l in readlines(joinpath(dir, "tyc.out.pdb"))
                if resOf(l) == TYR1 && isAtomLine(l)
            ]
            @test unique(nameOf.(tyr)) == ["TYR"]
            # the standard names written as HETATM are left to pdb2pqr as before
            src = wr(dir, "allhet.pdb", allhet())
            r = relabelModified(src, joinpath(dir, "allhet.out.pdb"))
            @test isempty(r.plan) && r.noParentAmino == 0
            @test readlines(joinpath(dir, "allhet.out.pdb")) == readlines(src)
            # other lines and atom order are untouched
            lines = mse("HETATM")
            src = wr(dir, "order.pdb", lines)
            r = relabelModified(src, joinpath(dir, "order.out.pdb"))
            back = readlines(joinpath(dir, "order.out.pdb"))
            @test length(back) == length(lines)
            @test [atomOf(l) for l in back if isAtomLine(l)] ==
                  [l[13:16] |> strip for l in lines if isAtomLine(l)] .|>
                  (a -> a == "SE" ? "SD" : a)
        end

        @testset "the incomplete-residue rule" begin
            info = component("MSE")
            atoms = Set(["N", "CA", "C", "O", "CB", "CG", "SE", "CE"])
            @test _runsAsParent(info, atoms) == "MET"
            @test _runsAsParent(info, setdiff(atoms, ["CG"])) === nothing
            @test _runsAsParent(info, setdiff(atoms, ["SE"])) === nothing
            @test _runsAsParent(info, union(atoms, ["P", "OP1"])) == "MET"   # extras
            # SD named as in the parent counts too
            @test _runsAsParent(
                info,
                Set(["N", "CA", "C", "O", "CB", "CG", "SD", "CE"]),
            ) ==
                  "MET"
            @test _runsAsParent(
                component("HSE"),
                Set(["N", "CA", "C", "O", "CB", "CG", "OD"]),
            ) ===
                  nothing                                  # homoserine lacks SER's OG
            @test _runsAsParent(component("SEP"),
                Set(["N", "CA", "C", "O", "CB", "OG", "P", "O1P"])) == "SER"
            @test _runsAsParent(component("2RA"), Set(STANDARD_AMINO_ATOMS["ALA"])) ===
                  nothing                                  # D: never
            @test Set(keys(STANDARD_AMINO_ATOMS)) == Set(STANDARD_AMINO_ACIDS)
            # in a file: an MSE without CG is left alone and counted
            lines = renamed(MET1, "MSE", "HETATM";
                f = l -> atomOf(l) == "SD" ? edit(l; atom = " SE ", elem = "SE") : l,
                drop = ("CG",))
            src = wr(dir, "incomplete.pdb", lines)
            r = relabelModified(src, joinpath(dir, "incomplete.out.pdb"))
            @test isempty(r.plan) && isempty(r.aliases) && r.noParentAmino == 1
            @test readlines(joinpath(dir, "incomplete.out.pdb")) == lines
        end

        @testset "which residues the hydrogenation counts" begin
            @test hasModifiedAmino([component("ALA"), component("MSE")])
            @test !hasModifiedAmino([
                component("ALA"),
                component("HOH"),
                component("PSU"),
            ])
            @test !hasModifiedAmino([component("UNK")])
            @test !hasModifiedAmino([])
            c = hydrogenationChoice(
                component.(residueNames(wr(dir, "c.pdb", mse("HETATM")))),
            )
            @test c.content === :protein && c.ff === :parse && c.titration === :propka
        end

        # ---- pdb2pqr runs from here: the CondaPkg tools are needed -----------------------
        function hydrogenated(stem, lines)
            path = wr(dir, stem * ".pdb", lines)
            hp = resolveHydrogens(path, 7.0; ff = :parse, titration = Propka())
            infos = component.(residueNames(path))
            # (what the loader keeps: waters, ions and ligands are not part of the model)
            out = [
                l for l in eachline(hp)
                if
                startswith(l, "ATOM") || (isAtomLine(l) && isAminoAcid(nameOf(l)))
            ]
            return (; path, hp, infos, out, n = nAtoms(loadMolecule(hp)),
                h = count(isH, out))
        end

        ref = hydrogenated("nt-amino-ref", LINES)
        @testset "the unmodified reference" begin
            # 1856 before 2026-11-11: the 15 atoms of the TBU ligand are kept, no hydrogens
            @test ref.n == 1856 + 15 && ref.h == 905
            @test count(!isH, ref.out) == 951
        end

        @testset "MSE (HETATM) gives the structure of the MET, selenium intact" begin
            r = hydrogenated("nt-amino-mse", mse("HETATM"))
            @test (r.n, r.h) == (ref.n, ref.h)
            res = [l for l in r.out if resOf(l) == MET1]
            @test unique(nameOf.(res)) == ["MSE"]
            @test unique(l[1:6] for l in res) == ["HETATM"]
            se = only(l for l in res if atomOf(l) == "SE")
            inputSe =
                only(l for l in mse("HETATM") if resOf(l) == MET1 && atomOf(l) == "SE")
            @test se[31:54] == inputSe[31:54]               # the input's coordinates
            @test strip(se[77:78]) == "SE"
            @test !any(l -> atomOf(l) == "SD", res)
            # the other residues are those of the reference
            others(lines) = sort!([l[13:54] for l in lines if resOf(l) != MET1])
            @test others(r.out) == others(ref.out)
            # the same hydrogens as the MET of the reference
            @test count(isH, res) == count(isH, [l for l in ref.out if resOf(l) == MET1])
            # the loaded model has a selenium with its own radius, not a sulfur
            mol = loadMolecule(r.hp)
            j = findfirst(e -> lowercase(e) == "se", elms(mol))
            @test j !== nothing
            @test radii(mol)[j] != radii(loadMolecule(ref.hp))[findfirst(
                e -> lowercase(e) == "s", elms(loadMolecule(ref.hp)))]
            @test count(e -> lowercase(e) == "se", elms(mol)) == 1
            @test count(e -> lowercase(e) == "s", elms(mol)) ==
                  count(e -> lowercase(e) == "s", elms(loadMolecule(ref.hp))) - 1
            # the diagnostic of the timing log
            d = modedAaHyd(r.hp, r.infos)
            @test d.residues == 1 && d.withParent == 1 && d.noParent == 0
            @test d.placed == count(isH, res) > 0
        end

        @testset "standard names written as HETATM give the unmodified structure" begin
            r = hydrogenated("nt-amino-allhet", allhet())
            @test (r.n, r.h) == (1856 + 15, 905)
            @test !hasModifiedAmino(r.infos)
        end

        @testset "a D amino acid keeps its heavy atoms, no hydrogens are placed" begin
            lines = dala()
            r = hydrogenated("nt-amino-dala", lines)
            res = [l for l in r.out if resOf(l) == ALA1]
            @test unique(nameOf.(res)) == ["2RA"]
            @test unique(l[1:6] for l in res) == ["HETATM"]
            heavyIn = [atomOf(l) for l in lines if resOf(l) == ALA1 && !isH(l)]
            @test sort([atomOf(l) for l in res if !isH(l)]) == sort(heavyIn)
            # the other residues are as in the reference
            # the hydrogens already in the input stay (pdb2pqr leaves an unknown residue
            # alone), none is placed
            inH = count(isH, [l for l in lines if resOf(l) == ALA1 && isAtomLine(l)])
            @test count(isH, res) == inH > 0
            @test r.h ==
                  ref.h - count(isH, [l for l in ref.out if resOf(l) == ALA1]) + inH
            d = modedAaHyd(r.hp, r.infos)
            @test (d.residues, d.withParent, d.noParent, d.placed) == (1, 0, 1, inH)
        end

        @testset "a terminal variant and an incomplete residue" begin
            r = hydrogenated("nt-amino-tyc", tyc("HETATM"))
            @test (r.n, r.h) == (ref.n, ref.h)
            lines = renamed(MET1, "MSE", "HETATM";
                f = l -> atomOf(l) == "SD" ? edit(l; atom = " SE ", elem = "SE") : l,
                drop = ("CG",))
            r = hydrogenated("nt-amino-incomplete", lines)
            res = [l for l in r.out if resOf(l) == MET1]
            @test unique(nameOf.(res)) == ["MSE"]
            @test sort([atomOf(l) for l in res if !isH(l)]) ==
                  sort([atomOf(l) for l in lines if resOf(l) == MET1 && !isH(l)])
            d = modedAaHyd(r.hp, r.infos)
            @test (d.residues, d.withParent, d.noParent) == (1, 0, 1)
        end

        @testset "the timing log: stage and note" begin
            data() = (
                q = collect(range(0.02, 0.3; length = 40)),
                I = 10 .* exp.(-(collect(range(0.02, 0.3; length = 40)) .* 25) .^ 2 ./ 3) .+
                    0.05,
            )
            function seeded(stem, lines)
                path = wr(dir, stem * ".pdb", lines)
                d = data()
                Random.seed!(1)
                seed = BAYSOL.seedModel(
                    LocalPathSource(path), 9000.0, d.q, d.I, 0.05 .* d.I, 7.0, 0.1,
                    Solute[NonBiological(0.15, 0.001, "sodium chloride")],
                )
                return seed.timing
            end
            names(log) = [s.name for s in log.stages]
            note(log, n) = only(s.note for s in log.stages if s.name == n)
            wiring = ("resloveStruct", "components", "structure checks", "classify",
                "propka", "pdb2pqr", "modified amino acid hydrogens", "heavy atoms",
                "loadMolecule")
            log = seeded("nt-amino-seed", mse("HETATM"))
            @test filter(in(wiring), names(log)) == ["resloveStruct", "components",
                "structure checks", "classify", "propka", "pdb2pqr",
                "modified amino acid hydrogens", "heavy atoms", "loadMolecule"]
            # the protein-only route: no force-field suffix on the stage, PARSE in the note
            @test note(log, "classify") == "[protein: PARSE, titration propka]"
            r = hydrogenated("nt-amino-seed", mse("HETATM"))
            d = modedAaHyd(r.hp, r.infos)
            @test note(log, "modified amino acid hydrogens") ==
                  "[1 residues: 1 hydrogenated through their parent, 0 without a parent; " *
                  "$(d.placed) hydrogens placed]"
            @test d.placed > 0
            # a D residue: counted as without a parent
            log = seeded("nt-amino-seed-d", dala())
            @test occursin(
                "[1 residues: 0 hydrogenated through their parent, 1 without a parent; ",
                note(log, "modified amino acid hydrogens"))
            # none of them: no such stage
            log = seeded("nt-amino-seed-ref", LINES)
            @test !("modified amino acid hydrogens" in names(log))
            @test filter(in(wiring), names(log)) == ["resloveStruct", "components",
                "structure checks", "classify", "propka", "pdb2pqr", "heavy atoms",
                "loadMolecule"]
        end

        @testset "real fixtures" begin
            fx(id) =
                id == "SASDH39" ?
                joinpath(@__DIR__, "..", "..", "fixtures", "molecules",
                    "SASDH39-argonaute-dna.pdb") :
                joinpath(@__DIR__, "..", "..", "fixtures", "experiments", id,
                    "$(id)_fit1_model1.pdb")
            # the raw loader: the HETATM selenomethionines are in, standard names written as
            # HETATM too
            @test nAtoms(loadMolecule(fx("SASDH39"))) == 7225      # 7223 and the two Mg
            @test nAtoms(loadMolecule(fx("SASDNP7"))) == 5608      # 5575, GNP (32) and Mg
            @test nAtoms(loadMolecule(fx("SASDB48"))) == 3735
            tk5 = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDTK5",
                "SASDTK5_fit2_model1.pdb")
            # the 202 atoms of PXX are in (5092 before
            # 2026-11-11), the 7 UNK too (2026-11-13)
            @test nAtoms(loadMolecule(tk5)) == 5301
            @test nAtoms(loadMolecule(tk5; ligands = false)) == 5092
            # SASDH39: 20 selenomethionines (160 atoms), hydrogenated through MET; two Mg
            # ions are kept (14270 before 2026-11-11)
            path = joinpath(dir, "nt-amino-h39.pdb")
            cp(fx("SASDH39"), path)
            hp = resolveHydrogens(path, 7.4; ff = :parse, titration = Propka())
            infos = component.(residueNames(path))
            @test nAtoms(loadMolecule(hp)) == 14272
            d = modedAaHyd(hp, infos)
            @test (d.residues, d.withParent, d.noParent) == (20, 20, 0)
            @test d.placed == 183
            # SASDB48: the twenty standard names written as HETATM, no amino-acid stage
            path = joinpath(dir, "nt-amino-b48.pdb")
            cp(fx("SASDB48"), path)
            hp = resolveHydrogens(path, 7.4; ff = :parse, titration = Propka())
            infos = component.(residueNames(path))
            @test !hasModifiedAmino(infos)
            @test nAtoms(loadMolecule(hp)) == 7041
            @test heavyAtomCount(path) == 3735 && heavyAtomCount(hp) == 3737
        end
    finally
        _COMPONENT_DOWNLOAD[] = savedHook
        empty!(_COMPONENT_MEMO)
        purgeStore("nt-amino-")
        rm(dir; recursive = true, force = true)
    end
end

end # module
