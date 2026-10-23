# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/Hydrogenator/ChainEnds.jl: a nucleic chain that starts or ends with a
# non-nucleotide (the 5' GTP of SASDWJ4, the aminoacyl MET of the tRNA in SASDNP7) runs
# those ends under chain ids of their own, because pdb2pqr patches the 5' end only if the
# first residue is nucleic and the 3' end only if the last is, and a lone patch aborts its
# charge check. First the text work (`isolate_chain_ends`, `restore_chain_ends!`) on
# small files made of the lines of 1EHZ and 7RSA, then pdb2pqr runs (they need the
# CondaPkg tools, like test_pdb2pqr.jl; no network): the tRNA 1EHZ with a trailing MET
# (PARSE, as a mixed structure is run) and with a leading GTP (AMBER, as a nucleic acid
# alone is run). The files that are run are copied under their own names (`nt-ends-*`)
# because the hydrogenated files are cached by file stem.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

module NtTest_chain_ends

using Test
using BAYSOL

using Printf: @sprintf

using BAYSOL.Hydrogenator: resolve_hydrogens, Propka, NoTitration, NUCLEIC_FORCE_FIELD,
    isolate_chain_ends, restore_chain_ends!, relabel_modified
using BAYSOL.MolecularStructure: load_molecule, n_atoms, _store_dir, _COMPONENT_DOWNLOAD,
    _COMPONENT_MEMO, _ComponentNotFound

const _FIXTURES = joinpath(@__DIR__, "..", "..", "fixtures", "molecules")

# the ATOM/HETATM lines of chain `chain` of a fixture, residue numbers in `nums`
function _residues(file::AbstractString, chain::Char, nums)
    out = String[]
    for l in eachline(joinpath(_FIXTURES, file))
        (startswith(l, "ATOM") || startswith(l, "HETATM")) || continue
        l[22] == chain && parse(Int, strip(l[23:26])) in nums && push!(out, l)
    end
    return out
end

# the lines moved by `dx` Å along x, renamed to `name` (record `rec`), numbered `num`,
# in `chain`
function moved(lines, dx, name, rec, num, chain)
    return [
        @sprintf("%-6s", rec) * l[7:17] * lpad(name, 3) * " " * chain * lpad(num, 4) *
        l[27:30] * @sprintf("%8.3f", parse(Float64, l[31:38]) + dx) * l[39:end]
        for l in lines
    ]
end

name_of(l) = strip(l[18:20])
is_h(l) = strip(l[77:min(end, 78)]) in ("H", "D")
atoms_of(lines) = [l for l in lines if startswith(l, "ATOM") || startswith(l, "HETATM")]

function wr(dir, name, lines)
    path = joinpath(dir, name)
    write(path, join(lines, "\n") * "\n")
    return path
end

# a trailing MET (lifted from 7RSA, shifted away from the RNA) and a leading GTP (the atoms
# of a guanosine of 1EHZ, written as a ligand)
const MET = moved(_residues("7RSA-TEST.pdb", 'A', 13:13), 40.0, "MET", "ATOM", 101, "A")
const GTP = moved(_residues("1EHZ-TEST.pdb", 'A', 3:3), 40.0, "GTP", "HETATM", 0, "A")

purge_store(prefix) = foreach(readdir(_store_dir())) do f
    startswith(f, prefix) && rm(joinpath(_store_dir(), f); force = true, recursive = true)
end

@testset "chain ends that are not nucleotides" begin
    dir = mktempdir()
    saved_hook = _COMPONENT_DOWNLOAD[]
    _COMPONENT_DOWNLOAD[] = (url, dest) -> throw(_ComponentNotFound(url))
    empty!(_COMPONENT_MEMO)
    try
        rna = _residues("1EHZ-TEST.pdb", 'A', 1:76)
        @test !isempty(MET) && !isempty(GTP)

        @testset "isolate_chain_ends: text" begin
            # a nucleic chain with nothing at its ends: nothing is written
            out = joinpath(dir, "none.out.pdb")
            iso = isolate_chain_ends(wr(dir, "none.pdb", rna), out)
            @test !iso.changed && isempty(iso.back) && !isfile(out)
            # a protein alone has no nucleotides: untouched
            prot = _residues("7RSA-TEST.pdb", 'A', 1:20)
            iso = isolate_chain_ends(wr(dir, "prot.pdb", prot), out)
            @test !iso.changed && !isfile(out)

            # trailing MET: it alone moves, to an unused id
            out = joinpath(dir, "trail.out.pdb")
            iso = isolate_chain_ends(wr(dir, "trail.pdb", [rna; MET]), out)
            @test iso.changed
            @test length(iso.back) == 1 && only(values(iso.back)) == 'A'
            fresh = only(keys(iso.back))
            @test fresh != 'A'
            @test iso.trailing_amino == Set([("A", "101")])
            res = atoms_of(readlines(out))
            @test all(l -> (l[22] == fresh) == (name_of(l) == "MET"), res)
            @test length(res) == length(rna) + length(MET)

            # leading GTP: it moves, and it is not an amino acid
            out = joinpath(dir, "lead.out.pdb")
            iso = isolate_chain_ends(wr(dir, "lead.pdb", [GTP; rna]), out)
            @test iso.changed && length(iso.back) == 1 && isempty(iso.trailing_amino)
            @test all(
                l -> (l[22] == only(keys(iso.back))) == (name_of(l) == "GTP"),
                atoms_of(readlines(out)),
            )

            # both ends: two ids, and a TER between the residues changes nothing
            out = joinpath(dir, "both.out.pdb")
            ter = "TER"
            iso = isolate_chain_ends(
                wr(dir, "both.pdb", [GTP; rna; ter; MET]), out)
            @test length(iso.back) == 2 && allequal(values(iso.back))
            @test iso.trailing_amino == Set([("A", "101")])
            ids = Dict(name_of(l) => l[22] for l in atoms_of(readlines(out)))
            @test ids["GTP"] != ids["MET"] && ids["GTP"] != 'A' && ids["MET"] != 'A'
        end

        @testset "restore_chain_ends!: ids back, OXT/HXT of the aminoacyl residue off" begin
            out = joinpath(dir, "r.out.pdb")
            input = wr(dir, "r.pdb", [rna; MET])
            iso = isolate_chain_ends(input, out)
            fresh = only(keys(iso.back))
            # what pdb2pqr writes for the isolated MET: its atoms plus OXT and HXT
            extra(a, el) =
                MET[1][1:11] * rpad(" " * a, 5) * MET[1][17:30] *
                "   1.000   2.000   3.000  1.00  0.00          " * lpad(el, 2)
            lines = [readlines(out); extra("OXT", "O"); extra("HXT", "H")]
            lines = [
                (
                    startswith(l, "ATOM") && name_of(l) == "MET" ?
                    l[1:21] * fresh * l[23:end] : l
                )
                for l in lines
            ]
            write(out, join(lines, "\n") * "\n")
            restore_chain_ends!(out, iso, input)
            res = atoms_of(readlines(out))
            @test all(l -> l[22] == 'A', res)
            met = filter(l -> name_of(l) == "MET", res)
            @test length(met) == length(MET)
            @test !any(l -> strip(l[13:16]) in ("OXT", "HXT"), met)

            # an OXT the input itself has stays
            oxt = extra("OXT", "O")
            input2 = wr(dir, "r2.pdb", [rna; MET; oxt])
            out2 = joinpath(dir, "r2.out.pdb")
            iso2 = isolate_chain_ends(input2, out2)
            restore_chain_ends!(out2, iso2, input2)
            @test count(l -> strip(l[13:16]) == "OXT", atoms_of(readlines(out2))) == 1

            # nothing isolated: the output is not touched
            before = read(out2, String)
            restore_chain_ends!(out2, (; changed = false), input2)
            @test read(out2, String) == before
        end

        # ---- pdb2pqr runs from here: the CondaPkg tools are needed ---------------------
        @testset "pdb2pqr: tRNA with a trailing MET (PARSE)" begin
            path = wr(dir, "nt-ends-met.pdb", [rna; MET])
            try
                hp = resolve_hydrogens(path, 7.4; titration = Propka())
                @test isfile(hp)
                res = atoms_of(readlines(hp))
                @test all(l -> l[22] == 'A', res)
                met = filter(l -> name_of(l) == "MET", res)
                @test !isempty(met) && count(is_h, met) > 0
                @test !any(l -> strip(l[13:16]) in ("OXT", "HXT"), met)
                # every nucleotide kept, the 5' phosphorus restored
                @test length(unique(l[23:27] for l in res if name_of(l) != "MET")) == 76
            finally
                purge_store("nt-ends-")
            end
        end

        @testset "pdb2pqr: RNA with a leading GTP (AMBER)" begin
            path = wr(dir, "nt-ends-gtp.pdb", [GTP; rna])
            try
                hp = resolve_hydrogens(
                    path, 7.4; ff = NUCLEIC_FORCE_FIELD, titration = NoTitration())
                @test isfile(hp)
                res = atoms_of(readlines(hp))
                @test all(l -> l[22] == 'A', res)
                @test length(unique(l[23:27] for l in res if name_of(l) != "GTP")) == 76
                @test count(is_h, res) > 0
            finally
                purge_store("nt-ends-")
            end
        end
    finally
        _COMPONENT_DOWNLOAD[] = saved_hook
        empty!(_COMPONENT_MEMO)
        rm(dir; recursive = true, force = true)
    end
end

end # module
