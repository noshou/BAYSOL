# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises the modified amino acids (MSE, SEP, PTR, TYC, D residues, ...): the component
# predicates `is_amino_acid` and `amino_parent` (src/MolecularStructure/Components.jl), the
# loader that keeps their HETATM records (`polymer_selector`), and their hydrogenation
# through the standard parent (src/Hydrogenator/Modified.jl and Content.jl): the relabel and
# restore round trip, the selenium alias (`SE` runs as `SD`), the rule for incomplete
# residues, D amino acids, and the stage `modified amino acid hydrogens` of the timing log.
# The inputs are synthetic files derived from the fixture 7RSA (ribonuclease A, 951 heavy
# atoms, 1856 atoms with hydrogens): a methionine renamed MSE, an alanine mirrored into a D
# residue, a tyrosine renamed TYC, all residues written as HETATM. The pdb2pqr runs need the
# CondaPkg tools (and PROPKA) like test_pdb2pqr.jl; no network. Files that are run through
# pdb2pqr have their own stems (`nt-amino-*`), removed at the end.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

module NtTest_modified_amino

using Test
using BAYSOL
using Random
using BAYSOL.BulkElectronDensity: NonBiological, Solute
using Printf: @sprintf
using BAYSOL.MolecularStructure: component, is_amino_acid, amino_parent, is_nucleotide,
    polymer_selector, nucleotide_selector, load_molecule, n_atoms, elms, coords_cartesian,
    radii, resolve_structure, LocalPathSource, residue_names, _store_dir, _WARNED,
    STANDARD_AMINO_ACIDS, _resolve_parent, _AMINO_PARENTS, _is_amino_type,
    _COMPONENT_DOWNLOAD, _COMPONENT_MEMO, _ComponentNotFound
using BAYSOL.Hydrogenator: relabel_modified, restore_modified!, resolve_hydrogens, Propka,
    has_modified_amino, modified_amino_hydrogens, AMINO_ATOM_ALIASES, STANDARD_AMINO_ATOMS,
    _runs_as_parent, _amino_run_as, hydrogenation_choice, heavy_atom_count
using BAYSOL.Runtime: force
using BioStructures:
    BioStructures, PDBFormat, collectmodels, collectatoms, resname, atomname

const SRC = joinpath(@__DIR__, "..", "..", "fixtures", "molecules", "7RSA-TEST.pdb")
const LINES = readlines(SRC)

res_of(l) = strip(l[23:27])
name_of(l) = strip(l[18:20])
atom_of(l) = strip(l[13:16])
is_atom_line(l) = startswith(l, "ATOM") || startswith(l, "HETATM")
is_h(l) = strip(l[77:min(end, 78)]) in ("H", "D")
heavy_lines(lines) = [l for l in lines if is_atom_line(l) && !is_h(l)]

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
first_residue(name) =
    first(res_of(l) for l in LINES if startswith(l, "ATOM") && name_of(l) == name)
const MET1 = first_residue("MET")
const ALA1 = first_residue("ALA")
const TYR1 = first_residue("TYR")
const CYS1 = first_residue("CYS")
const LYS1 = first_residue("LYS")

# the residue `num` renamed `newname` with record `rec`; `f(line)` may change each line
function renamed(num, newname, rec; f = identity, drop = ())
    out = String[]
    for l in LINES
        if startswith(l, "ATOM") && res_of(l) == num
            atom_of(l) in drop && continue
            l = f(edit(l; rec, name = newname))
        end
        push!(out, l)
    end
    return out
end
# MET -> MSE, SD -> SE (element SE)
mse(rec) = renamed(MET1, "MSE", rec;
    f = l -> atom_of(l) == "SD" ? edit(l; atom = " SE ", elem = "SE") : l)
# CYS -> CSE, SG -> SE
cse(rec) = renamed(CYS1, "CSE", rec;
    f = l -> atom_of(l) == "SG" ? edit(l; atom = " SE ", elem = "SE") : l)
tyc(rec) = renamed(TYR1, "TYC", rec)
allhet() = [startswith(l, "ATOM") ? edit(l; rec = "HETATM") : l for l in LINES]

# a D alanine: the first ALA with its CB mirrored through the N-CA-C plane, named 2RA
function dala()
    xyz(l) = parse.(Float64, (l[31:38], l[39:46], l[47:54]))
    atoms =
        Dict(atom_of(l) => l for l in LINES if startswith(l, "ATOM") && res_of(l) == ALA1)
    N, CA, C, CB = (xyz(atoms[k]) for k in ("N", "CA", "C", "CB"))
    cross(a, b) =
        [a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1]]
    n = cross(N .- CA, C .- CA)
    n ./= sqrt(sum(abs2, n))
    d = sum((CB .- CA) .* n)
    CBm = CB .- 2d .* n
    return renamed(ALA1, "2RA", "HETATM";
        f = l ->
            atom_of(l) == "CB" ?
            l[1:30] * @sprintf("%8.3f%8.3f%8.3f", CBm...) * l[55:end] : l)
end

function wr(dir, name, lines)
    path = joinpath(dir, name)
    write(path, join(lines, "\n") * "\n")
    return path
end
function purge_store(prefix)
    for f in readdir(_store_dir())
        startswith(f, prefix) &&
            rm(joinpath(_store_dir(), f); force = true, recursive = true)
    end
end

@testset "modified amino acids" begin
    dir = mktempdir()
    saved_hook = _COMPONENT_DOWNLOAD[]
    _COMPONENT_DOWNLOAD[] = (url, dest) -> throw(_ComponentNotFound(url))
    empty!(_COMPONENT_MEMO)

    try
        @testset "is_amino_acid" begin
            # standard, modified, D, plain peptide linking, termini
            for id in
                ("ALA", "GLY", "MSE", "SEP", "TPO", "PTR", "CSO", "MLY", "HSE", "SEC",
                "2RA", "DAL", "DCY", "DTH", "TYC", "mse", " ser ")
                @test is_amino_acid(id)
            end
            for t in ("l-peptide linking", "d-peptide linking", "peptide linking",
                "l-peptide cooh carboxy terminus", "l-peptide nh3 amino terminus",
                "d-peptide nh3 amino terminus")
                @test _is_amino_type(t)
            end
            @test component("TYC").type == "l-peptide cooh carboxy terminus"
            @test is_amino_acid("0YG")                 # an amino terminus type
            # no: peptide-like, UNK, waters, ligands, saccharides, nucleotides, ions
            for t in ("peptide-like", "non-polymer", "d-saccharide", "rna linking",
                "l-saccharide", "")
                @test !_is_amino_type(t)
            end
            for id in ("UNK", "unk", "HOH", "WAT", "DOD", "H2O", "NAG", "GLC", "ATP", "MG",
                "ZN", "PSU", "DA", "DAD", "DGU", "FOR", "ACE", "NH2", "TTD")
                @test !is_amino_acid(id)
            end
            # a name the dictionary does not know is not one (the fake hook says "no such")
            @test !is_amino_acid("QQQQ")
            # amino acids are not nucleotides and conversely
            @test !is_nucleotide("MSE") && !is_amino_acid("A")
        end

        @testset "amino_parent" begin
            for (id, p) in (("MSE", "MET"), ("SEP", "SER"), ("PTR", "TYR"), ("TYC", "TYR"),
                ("TPO", "THR"), ("CSO", "CYS"), ("MLY", "LYS"), ("HSE", "SER"),
                ("CSE", "CYS"), ("2RA", "ALA"), ("mse", "MET"))
                @test amino_parent(id) == p
            end
            # the standard names are their own, not children of anything
            @test all(amino_parent(a) === nothing for a in STANDARD_AMINO_ACIDS)
            # not amino acids, unknown, or no resolvable parent: nothing
            for id in ("HOH", "UNK", "PSU", "NAG", "QQQQ", "SEC", "DAL", "DCY", "DTH")
                @test amino_parent(id) === nothing
            end
            @test amino_parent("175") === nothing     # ALA, SER, GLY: several parents
            @test amino_parent("0YG") === nothing     # TYR, GLY
            table = force(_AMINO_PARENTS)
            @test all(p -> p in STANDARD_AMINO_ACIDS, values(table))
            @test length(table) > 1000
            # a non-standard parent is followed up to a standard one, a cycle or several
            # different parents give none (the same rule as the nucleotides')
            raw = Dict("XA" => "XB", "XB" => "SER", "XC" => "XD", "XD" => "XC",
                "XE" => "ALA, SER", "XF" => "SER, SER")
            up(id) = _resolve_parent(
                raw[id], q -> get(raw, q, nothing); standard = STANDARD_AMINO_ACIDS)
            @test up("XA") == "SER" && up("XF") == "SER"
            @test up("XC") === nothing && up("XE") === nothing
            # D residues: some declare a parent (2RA, alanine), they are still D
            @test startswith(component("2RA").type, "d-")
            @test _amino_run_as(component("2RA")) === nothing      # not run as an L parent
            @test _amino_run_as(component("MSE")) == "MET"
            @test _amino_run_as(component("HOH")) === nothing
        end

        @testset "polymer_selector and the loader" begin
            path = wr(dir, "sel.pdb", mse("HETATM"))
            model = first(collectmodels(BioStructures.read(path, PDBFormat)))
            ats = collectatoms(model)
            kept(r) = count(a -> resname(a) == r && polymer_selector(a), ats)
            total(r) = count(a -> resname(a) == r, ats)
            @test total("MSE") == kept("MSE") > 0
            @test count(nucleotide_selector, ats) < count(polymer_selector, ats)  # MSE only
            @test kept("ALA") == total("ALA") > 0
            # waters, ions, a ligand, a saccharide and UNK are dropped
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
                )) load_molecule(path)
            # once per structure
            @test_logs load_molecule(path)
            ref = load_molecule(wr(dir, "ref.pdb", LINES))
            @test n_atoms(mol) == n_atoms(ref)           # MSE kept, six extras dropped
            @test count(e -> lowercase(e) == "se", elms(mol)) == 1
            # the same through resolve_structure for a .pdb (used in place) and a .cif
            @test n_atoms(load_molecule(resolve_structure(LocalPathSource(path)))) ==
                  n_atoms(ref)
            # all residues written as HETATM: all kept
            @test n_atoms(load_molecule(wr(dir, "het.pdb", allhet()))) == n_atoms(ref)
        end

        @testset "relabel and restore: amino acids" begin
            for rec in ("HETATM", "ATOM")
                lines = mse(rec)
                src = wr(dir, "m$rec.pdb", lines)
                out = joinpath(dir, "m$rec.out.pdb")
                r = relabel_modified(src, out)
                key = ("A", MET1)
                @test collect(keys(r.plan)) == [key]
                @test r.plan[key].name == "MSE" && strip(r.plan[key].record) == rec
                @test r.no_parent_amino == 0 && r.no_base == 0
                @test length(r.aliases) == 1
                relabelled = readlines(out)
                met = [l for l in relabelled if res_of(l) == MET1 && is_atom_line(l)]
                @test unique(name_of.(met)) == ["MET"]
                @test unique(l[1:6] for l in met) == ["ATOM  "]
                # the selenium runs as sulfur-delta, element S
                sd = only(l for l in met if atom_of(l) == "SD")
                @test strip(sd[77:78]) == "S"
                @test sd[31:54] ==
                      only(l for l in lines if is_atom_line(l) && atom_of(l) == "SE")[31:54]
                @test !any(l -> atom_of(l) == "SE", met)
                # restoring the (here unchanged) output gives the original lines back
                restore_modified!(out, r.plan, r.aliases)
                @test readlines(out) == lines
            end
            # the alias table
            @test AMINO_ATOM_ALIASES == Dict(("MET", "SE") => "SD", ("CYS", "SE") => "SG")
            # CYS -> CSE: SE runs as SG
            lines = cse("HETATM")
            src = wr(dir, "cse.pdb", lines)
            out = joinpath(dir, "cse.out.pdb")
            r = relabel_modified(src, out)
            @test length(r.aliases) == 1 && r.no_parent_amino == 0
            cys = [l for l in readlines(out) if res_of(l) == CYS1 && is_atom_line(l)]
            @test unique(name_of.(cys)) == ["CYS"] && any(l -> atom_of(l) == "SG", cys)
            restore_modified!(out, r.plan, r.aliases)
            @test readlines(out) == lines
            # TYC: a terminal variant is run as its parent like any other
            lines = tyc("HETATM")
            src = wr(dir, "tyc.pdb", lines)
            r = relabel_modified(src, joinpath(dir, "tyc.out.pdb"))
            @test collect(keys(r.plan)) == [("A", TYR1)] && isempty(r.aliases)
            tyr = [
                l for l in readlines(joinpath(dir, "tyc.out.pdb"))
                if res_of(l) == TYR1 && is_atom_line(l)
            ]
            @test unique(name_of.(tyr)) == ["TYR"]
            # the standard names written as HETATM are left to pdb2pqr as before
            src = wr(dir, "allhet.pdb", allhet())
            r = relabel_modified(src, joinpath(dir, "allhet.out.pdb"))
            @test isempty(r.plan) && r.no_parent_amino == 0
            @test readlines(joinpath(dir, "allhet.out.pdb")) == readlines(src)
            # other lines and atom order are untouched
            lines = mse("HETATM")
            src = wr(dir, "order.pdb", lines)
            r = relabel_modified(src, joinpath(dir, "order.out.pdb"))
            back = readlines(joinpath(dir, "order.out.pdb"))
            @test length(back) == length(lines)
            @test [atom_of(l) for l in back if is_atom_line(l)] ==
                  [l[13:16] |> strip for l in lines if is_atom_line(l)] .|>
                  (a -> a == "SE" ? "SD" : a)
        end

        @testset "the incomplete-residue rule" begin
            info = component("MSE")
            atoms = Set(["N", "CA", "C", "O", "CB", "CG", "SE", "CE"])
            @test _runs_as_parent(info, atoms) == "MET"
            @test _runs_as_parent(info, setdiff(atoms, ["CG"])) === nothing
            @test _runs_as_parent(info, setdiff(atoms, ["SE"])) === nothing
            @test _runs_as_parent(info, union(atoms, ["P", "OP1"])) == "MET"   # extras
            # SD named as in the parent counts too
            @test _runs_as_parent(
                info,
                Set(["N", "CA", "C", "O", "CB", "CG", "SD", "CE"]),
            ) ==
                  "MET"
            @test _runs_as_parent(
                component("HSE"),
                Set(["N", "CA", "C", "O", "CB", "CG", "OD"]),
            ) ===
                  nothing                                  # homoserine lacks SER's OG
            @test _runs_as_parent(component("SEP"),
                Set(["N", "CA", "C", "O", "CB", "OG", "P", "O1P"])) == "SER"
            @test _runs_as_parent(component("2RA"), Set(STANDARD_AMINO_ATOMS["ALA"])) ===
                  nothing                                  # D: never
            @test Set(keys(STANDARD_AMINO_ATOMS)) == Set(STANDARD_AMINO_ACIDS)
            # in a file: an MSE without CG is left alone and counted
            lines = renamed(MET1, "MSE", "HETATM";
                f = l -> atom_of(l) == "SD" ? edit(l; atom = " SE ", elem = "SE") : l,
                drop = ("CG",))
            src = wr(dir, "incomplete.pdb", lines)
            r = relabel_modified(src, joinpath(dir, "incomplete.out.pdb"))
            @test isempty(r.plan) && isempty(r.aliases) && r.no_parent_amino == 1
            @test readlines(joinpath(dir, "incomplete.out.pdb")) == lines
        end

        @testset "which residues the hydrogenation counts" begin
            @test has_modified_amino([component("ALA"), component("MSE")])
            @test !has_modified_amino([
                component("ALA"),
                component("HOH"),
                component("PSU"),
            ])
            @test !has_modified_amino([component("UNK")])
            @test !has_modified_amino([])
            c = hydrogenation_choice(
                component.(residue_names(wr(dir, "c.pdb", mse("HETATM")))),
            )
            @test c.content === :protein && c.ff === :parse && c.titration === :propka
        end

        # ---- pdb2pqr runs from here: the CondaPkg tools are needed -----------------------
        function hydrogenated(stem, lines)
            path = wr(dir, stem * ".pdb", lines)
            hp = resolve_hydrogens(path, 7.0; ff = :parse, titration = Propka())
            infos = component.(residue_names(path))
            # (what the loader keeps: waters, ions and ligands are not part of the model)
            out = [
                l for l in eachline(hp)
                if
                startswith(l, "ATOM") || (is_atom_line(l) && is_amino_acid(name_of(l)))
            ]
            return (; path, hp, infos, out, n = n_atoms(load_molecule(hp)),
                h = count(is_h, out))
        end

        ref = hydrogenated("nt-amino-ref", LINES)
        @testset "the unmodified reference" begin
            @test ref.n == 1856 && ref.h == 905
            @test count(!is_h, ref.out) == 951
        end

        @testset "MSE (HETATM) gives the structure of the MET, selenium intact" begin
            r = hydrogenated("nt-amino-mse", mse("HETATM"))
            @test (r.n, r.h) == (ref.n, ref.h)
            res = [l for l in r.out if res_of(l) == MET1]
            @test unique(name_of.(res)) == ["MSE"]
            @test unique(l[1:6] for l in res) == ["HETATM"]
            se = only(l for l in res if atom_of(l) == "SE")
            input_se =
                only(l for l in mse("HETATM") if res_of(l) == MET1 && atom_of(l) == "SE")
            @test se[31:54] == input_se[31:54]               # the input's coordinates
            @test strip(se[77:78]) == "SE"
            @test !any(l -> atom_of(l) == "SD", res)
            # the other residues are those of the reference
            others(lines) = sort!([l[13:54] for l in lines if res_of(l) != MET1])
            @test others(r.out) == others(ref.out)
            # the same hydrogens as the MET of the reference
            @test count(is_h, res) == count(is_h, [l for l in ref.out if res_of(l) == MET1])
            # the loaded model has a selenium with its own radius, not a sulfur
            mol = load_molecule(r.hp)
            j = findfirst(e -> lowercase(e) == "se", elms(mol))
            @test j !== nothing
            @test radii(mol)[j] != radii(load_molecule(ref.hp))[findfirst(
                e -> lowercase(e) == "s", elms(load_molecule(ref.hp)))]
            @test count(e -> lowercase(e) == "se", elms(mol)) == 1
            @test count(e -> lowercase(e) == "s", elms(mol)) ==
                  count(e -> lowercase(e) == "s", elms(load_molecule(ref.hp))) - 1
            # the diagnostic of the timing log
            d = modified_amino_hydrogens(r.hp, r.infos)
            @test d.residues == 1 && d.with_parent == 1 && d.no_parent == 0
            @test d.placed == count(is_h, res) > 0
        end

        @testset "standard names written as HETATM give the unmodified structure" begin
            r = hydrogenated("nt-amino-allhet", allhet())
            @test (r.n, r.h) == (1856, 905)
            @test !has_modified_amino(r.infos)
        end

        @testset "a D amino acid keeps its heavy atoms, no hydrogens are placed" begin
            lines = dala()
            r = hydrogenated("nt-amino-dala", lines)
            res = [l for l in r.out if res_of(l) == ALA1]
            @test unique(name_of.(res)) == ["2RA"]
            @test unique(l[1:6] for l in res) == ["HETATM"]
            heavy_in = [atom_of(l) for l in lines if res_of(l) == ALA1 && !is_h(l)]
            @test sort([atom_of(l) for l in res if !is_h(l)]) == sort(heavy_in)
            # the other residues are as in the reference
            # the hydrogens already in the input stay (pdb2pqr leaves an unknown residue
            # alone), none is placed
            in_h = count(is_h, [l for l in lines if res_of(l) == ALA1 && is_atom_line(l)])
            @test count(is_h, res) == in_h > 0
            @test r.h ==
                  ref.h - count(is_h, [l for l in ref.out if res_of(l) == ALA1]) + in_h
            d = modified_amino_hydrogens(r.hp, r.infos)
            @test (d.residues, d.with_parent, d.no_parent, d.placed) == (1, 0, 1, in_h)
        end

        @testset "a terminal variant and an incomplete residue" begin
            r = hydrogenated("nt-amino-tyc", tyc("HETATM"))
            @test (r.n, r.h) == (ref.n, ref.h)
            lines = renamed(MET1, "MSE", "HETATM";
                f = l -> atom_of(l) == "SD" ? edit(l; atom = " SE ", elem = "SE") : l,
                drop = ("CG",))
            r = hydrogenated("nt-amino-incomplete", lines)
            res = [l for l in r.out if res_of(l) == MET1]
            @test unique(name_of.(res)) == ["MSE"]
            @test sort([atom_of(l) for l in res if !is_h(l)]) ==
                  sort([atom_of(l) for l in lines if res_of(l) == MET1 && !is_h(l)])
            d = modified_amino_hydrogens(r.hp, r.infos)
            @test (d.residues, d.with_parent, d.no_parent) == (1, 0, 1)
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
                seed = BAYSOL.seed_model(
                    LocalPathSource(path), 9000.0, d.q, d.I, 0.05 .* d.I, 7.0, 0.1,
                    Solute[NonBiological(0.15, 0.001, "sodium chloride")],
                )
                return seed.timing
            end
            names(log) = [s.name for s in log.stages]
            note(log, n) = only(s.note for s in log.stages if s.name == n)
            wiring = ("resolve_structure", "components", "structure checks", "classify",
                "propka", "pdb2pqr", "modified amino acid hydrogens", "heavy atoms",
                "load_molecule")
            log = seeded("nt-amino-seed", mse("HETATM"))
            @test filter(in(wiring), names(log)) == ["resolve_structure", "components",
                "structure checks", "classify", "propka", "pdb2pqr",
                "modified amino acid hydrogens", "heavy atoms", "load_molecule"]
            # the protein-only route: no force-field suffix on the stage, PARSE in the note
            @test note(log, "classify") == "[protein: PARSE, titration propka]"
            r = hydrogenated("nt-amino-seed", mse("HETATM"))
            d = modified_amino_hydrogens(r.hp, r.infos)
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
            @test filter(in(wiring), names(log)) == ["resolve_structure", "components",
                "structure checks", "classify", "propka", "pdb2pqr", "heavy atoms",
                "load_molecule"]
        end

        @testset "real fixtures" begin
            fx(id) = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", id,
                "$(id)_fit1_model1.pdb")
            # the raw loader: the HETATM selenomethionines are in, standard names written as
            # HETATM too
            @test n_atoms(load_molecule(fx("SASDH39"))) == 7223
            @test n_atoms(load_molecule(fx("SASDNP7"))) == 5575
            @test n_atoms(load_molecule(fx("SASDB48"))) == 3735
            tk5 = joinpath(@__DIR__, "..", "..", "fixtures", "experiments", "SASDTK5",
                "SASDTK5_fit2_model1.pdb")
            @test n_atoms(load_molecule(tk5)) == 5092
            # SASDH39: 20 selenomethionines (160 atoms), hydrogenated through MET
            path = joinpath(dir, "nt-amino-h39.pdb")
            cp(fx("SASDH39"), path)
            hp = resolve_hydrogens(path, 7.4; ff = :parse, titration = Propka())
            infos = component.(residue_names(path))
            @test n_atoms(load_molecule(hp)) == 14270
            d = modified_amino_hydrogens(hp, infos)
            @test (d.residues, d.with_parent, d.no_parent) == (20, 20, 0)
            @test d.placed == 183
            # SASDB48: the twenty standard names written as HETATM, no amino-acid stage
            path = joinpath(dir, "nt-amino-b48.pdb")
            cp(fx("SASDB48"), path)
            hp = resolve_hydrogens(path, 7.4; ff = :parse, titration = Propka())
            infos = component.(residue_names(path))
            @test !has_modified_amino(infos)
            @test n_atoms(load_molecule(hp)) == 7041
            @test heavy_atom_count(path) == 3735 && heavy_atom_count(hp) == 3737
        end
    finally
        _COMPONENT_DOWNLOAD[] = saved_hook
        empty!(_COMPONENT_MEMO)
        purge_store("nt-amino-")
        rm(dir; recursive = true, force = true)
    end
end

end # module
