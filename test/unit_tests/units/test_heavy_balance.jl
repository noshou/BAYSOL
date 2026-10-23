# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises src/Hydrogenator/Balance.jl: the heavy atoms of a structure before and after
# pdb2pqr. The ones pdb2pqr drops (the phosphorus of a chain's 5' end, with its two
# oxygens) are put back from the input and the `H5T` it put on the 5' oxygen is removed;
# the ones it renames (a carboxylate `OC1`/`OC2` becomes `O`/`OXT`) are not losses; the ones
# it adds are only counted and warned about. First on small synthetic input/output pairs,
# then the numbers of two real runs (1EHZ and crambin, which need the CondaPkg tools like
# test_pdb2pqr.jl, no network) and the `.balance` file a run leaves beside its output.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

# Everything below lives in a module of its own, so that the helpers and constants of this
# file cannot clash with those of another file when the aggregator includes them all into
# Main.
module NtTest_heavy_balance

using Test
using BAYSOL

using Printf: @sprintf
using BAYSOL.Hydrogenator: restore_dropped_atoms!, heavy_atom_count, hydrogenation_balance,
    resolve_hydrogens, NoTitration, Propka, NUCLEIC_FORCE_FIELD, _write_balance,
    _heavy_atoms_by_residue
using BAYSOL.MolecularStructure: _store_dir

const _FIXTURES = joinpath(@__DIR__, "..", "..", "fixtures", "molecules")

# a fixed-column ATOM/HETATM record
function pdbline(rec, serial, atom, res, chain, num, elem; xyz = (1.0, 2.0, 3.0))
    a = length(elem) == 2 ? rpad(atom, 4) : " " * rpad(atom, 3)
    return @sprintf(
        "%-6s%5d %s %3s %c%4d    %8.3f%8.3f%8.3f%6.2f%6.2f          %2s",
        rec, serial, a, res, chain, num, xyz..., 1.0, 10.0, lpad(elem, 2)
    )
end
el(a) = startswith(a, r"\d?H") ? "H" : string(first(a))

# every atom name has its own place, 4 A apart, so that no two atoms of a residue are near
const _PLACES = ["P", "OP1", "OP2", "O5'", "C5'", "C4'", "O4'", "C3'", "C2'", "C1'", "N9",
    "C8", "N7", "H5T", "H5'", "N", "CA", "C", "O", "CB", "OC1", "OC2", "OXT", "HA",
    "HB1",
    "H", "1HB", "2HB", "HG", "CD", "CA2"]
place(a, num) = (4.0 * something(findfirst(==(a), _PLACES), 99), 10.0 * num, 0.0)
residue(name, chain, num, atoms; rec = "ATOM", s0 = 1) = [
    pdbline(rec, s0 + i - 1, a, name, chain, num, el(a); xyz = place(a, num))
    for (i, a) in enumerate(atoms)
]
function wr(dir, name, lines)
    path = joinpath(dir, name)
    write(path, join(lines, "\n") * "\n")
    return path
end
atom_names(path, num) = [
    strip(l[13:16]) for l in eachline(path)
    if startswith(l, "ATOM") && parse(Int, strip(l[23:26])) == num
]
const BASE = ["O5'", "C5'", "C4'", "O4'", "C3'", "C2'", "C1'", "N9", "C8"]

@testset "heavy-atom balance" begin
    dir = mktempdir()
    try
        @testset "a dropped 5' phosphorus is put back, with the H5T removed" begin
            input = [residue("G", 'A', 1, ["P", "OP1", "OP2", BASE...]);
                residue("C", 'A', 2, ["P", "OP1", "OP2", BASE...]; s0 = 100)]
            # pdb2pqr's 5TERM patch: no P, OP1, OP2 on residue 1, an H5T instead
            output = [residue("G", 'A', 1, [BASE..., "H5T", "H5'"]; s0 = 1);
                residue("C", 'A', 2, ["P", "OP1", "OP2", BASE..., "H5'"]; s0 = 100)]
            inp = wr(dir, "in.pdb", input)
            out = wr(dir, "out.pdb", output)
            r = @test_logs (
                :info,
                r"dropped 3 heavy atom\(s\) of \"in.pdb\".*\(1 H5T removed",
            ) restore_dropped_atoms!(inp, out)
            @test r == (restored = 3, added = 0, h5t_dropped = 1)
            @test sort(atom_names(out, 1)) ==
                  sort(["P", "OP1", "OP2", BASE..., "H5'"])          # H5T gone, H5' stays
            @test "H5'" in atom_names(out, 1)
            # residue 2 is untouched
            @test atom_names(out, 2) == ["P", "OP1", "OP2", BASE..., "H5'"]
            # the restored atoms have the input's coordinates and the residue's name and
            # number
            ls = [l for l in eachline(out) if strip(l[13:16]) == "P" && l[23:26] == "   1"]
            @test length(ls) == 1
            @test ls[1][18:20] == "  G" && ls[1][22] == 'A'
            @test ls[1][31:54] == input[1][31:54]
            @test strip(ls[1][77:78]) == "P"
            # a second call finds nothing to do
            @test_logs restore_dropped_atoms!(inp, out) ==
                       (restored = 0, added = 0, h5t_dropped = 0)
        end

        @testset "only the phosphorus: no H5T to remove elsewhere" begin
            input = residue("G", 'A', 1, ["P", BASE...])
            output = residue("G", 'A', 1, [BASE..., "H5'"])
            inp = wr(dir, "p1.pdb", input)
            out = wr(dir, "p1o.pdb", output)
            @test (@test_logs (:info, r"dropped 1 heavy atom\(s\)") restore_dropped_atoms!(
                inp,
                out,
            )) ==
                  (restored = 1, added = 0, h5t_dropped = 0)
            @test "P" in atom_names(out, 1)
            # a non-phosphorus atom that is lost does not touch H5T
            input = residue("G", 'A', 1, [BASE..., "N7"])
            output = residue("G", 'A', 1, [BASE..., "H5T"])
            inp = wr(dir, "n7.pdb", input)
            out = wr(dir, "n7o.pdb", output)
            @test (@test_logs (:info, r"dropped 1 heavy") restore_dropped_atoms!(
                inp,
                out,
            )) ==
                  (restored = 1, added = 0, h5t_dropped = 0)
            @test "H5T" in atom_names(out, 1) && "N7" in atom_names(out, 1)
        end

        @testset "nothing dropped: the output is not touched" begin
            res = residue("ALA", 'A', 1, ["N", "CA", "C", "O", "CB"])
            inp = wr(dir, "same.pdb", res)
            out = wr(
                dir,
                "same.out.pdb",
                [res; residue("ALA", 'A', 1, ["HA", "HB1"]; s0 = 50)],
            )
            before = read(out, String)
            @test (@test_logs restore_dropped_atoms!(inp, out)) ==
                  (restored = 0, added = 0, h5t_dropped = 0)
            @test read(out, String) == before
            # hydrogens of the input are not heavy atoms: not lost when the output has none
            inp = wr(dir, "hin.pdb", [res; residue("ALA", 'A', 1, ["HA", "1HB"]; s0 = 50)])
            @test (@test_logs restore_dropped_atoms!(inp, out)).restored == 0
        end

        @testset "a renamed carboxylate is not a loss, an added atom is only counted" begin
            # OC1/OC2 -> O/OXT, a few tenths of an A away: one atom each, paired
            input = residue("ALA", 'A', 1, ["N", "CA", "C", "OC1", "OC2"])
            # (the same places, the two oxygens a few tenths of an A off)
            output = [
                pdbline("ATOM", i, a, "ALA", 'A', 1, el(a);
                    xyz = place(
                        a in ("O", "OXT") ? "OC" * string(a == "O" ? 1 : 2) : a,
                        1,
                    ) .+ 0.3)
                for (i, a) in enumerate(["N", "CA", "C", "O", "OXT"])
            ]
            inp = wr(dir, "oc.pdb", input)
            out = wr(dir, "oc.out.pdb", output)
            before = read(out, String)
            @test (@test_logs restore_dropped_atoms!(inp, out)) ==
                  (restored = 0, added = 0, h5t_dropped = 0)
            @test read(out, String) == before
            # an atom pdb2pqr adds (the OXT of a chain end) is counted and warned about
            input = residue("ALA", 'A', 1, ["N", "CA", "C", "O"])
            output = residue("ALA", 'A', 1, ["N", "CA", "C", "O", "OXT"])
            output[5] =
                pdbline("ATOM", 5, "OXT", "ALA", 'A', 1, "O"; xyz = (50.0, 50.0, 50.0))
            inp = wr(dir, "add.pdb", input)
            out = wr(dir, "add.out.pdb", output)
            before = read(out, String)
            warn = r"pdb2pqr added 1 heavy atom\(s\) to \"add.pdb\""
            r = @test_logs (:warn, warn) restore_dropped_atoms!(inp, out)
            @test r == (restored = 0, added = 1, h5t_dropped = 0)
            @test read(out, String) == before
            # lost and added at once, far apart: both
            input = residue("ALA", 'A', 1, ["N", "CA", "C", "O", "CB"])
            out = wr(dir, "both.out.pdb", output)
            inp = wr(dir, "both.pdb", input)
            r = @test_logs (:info, r"dropped 1") (:warn, r"added 1") restore_dropped_atoms!(
                inp,
                out,
            )
            @test r == (restored = 1, added = 1, h5t_dropped = 0)
            @test "CB" in atom_names(out, 1)
        end

        @testset "residues: blank chain ids, absent residues" begin
            # the input has no chain id, pdb2pqr named it: matched on the number
            input =
                [l[1:21] * " " * l[23:end] for l in residue("G", 'A', 7, ["P", BASE...])]
            output = residue("G", 'A', 7, [BASE...])
            inp = wr(dir, "bl.pdb", input)
            out = wr(dir, "bl.out.pdb", output)
            r = @test_logs (:info, r"dropped 1") restore_dropped_atoms!(inp, out)
            @test r.restored == 1 && "P" in atom_names(out, 7)
            @test all(
                l -> l[22] == 'A',
                [l for l in eachline(out) if startswith(l, "ATOM")],
            )
            # two output residues with that number: ambiguous, left alone
            out2 =
                wr(dir, "bl2.out.pdb", [output; residue("G", 'B', 7, [BASE...]; s0 = 500)])
            @test (@test_logs restore_dropped_atoms!(inp, out2)).restored == 0
            # waters and ligands absent from the output are left alone
            input = [residue("ALA", 'A', 1, ["N", "CA", "C", "O"]);
                residue("HOH", 'A', 101, ["O"]; rec = "HETATM", s0 = 50)]
            out = wr(dir, "w.out.pdb", residue("ALA", 'A', 1, ["N", "CA", "C", "O"]))
            @test (@test_logs restore_dropped_atoms!(wr(dir, "w.pdb", input), out)) ==
                  (restored = 0, added = 0, h5t_dropped = 0)
            # alternate locations are one atom
            alt = [residue("ALA", 'A', 1, ["N", "CA"]);
                [l[1:16] * "B" * l[18:end] for l in residue("ALA", 'A', 1, ["N"]; s0 = 9)]]
            @test length(_heavy_atoms_by_residue(wr(dir, "alt.pdb", alt))[("A", "1")]) == 2
        end

        @testset "heavy_atom_count" begin
            lines = [residue("ALA", 'A', 1, ["N", "CA", "C", "O", "CB"]);
                residue("ALA", 'A', 1, ["H", "HA", "1HB", "2HB"]; s0 = 50);
                residue("HOH", 'B', 2, ["O"]; rec = "HETATM", s0 = 100)]
            @test heavy_atom_count(wr(dir, "c.pdb", lines)) == 6          # waters count
            # an element column decides when there is one
            d = [
                pdbline("ATOM", 1, "HG", "MET", 'A', 1, "H");
                pdbline("ATOM", 2, "CD", "MET", 'A', 1, "C")
            ]
            @test heavy_atom_count(wr(dir, "e.pdb", d)) == 1
            # two chains that reuse an id count twice, duplicate atoms once
            nuc = residue("G", 'A', 1, BASE)
            ter = "TER    9999      " * "  G A   1"
            @test heavy_atom_count(
                wr(dir, "t.pdb", [nuc; ter; residue("G", 'A', 1, BASE; s0 = 100)]),
            ) ==
                  2 * length(BASE)
            @test heavy_atom_count(wr(dir, "u.pdb", [nuc; nuc[1:3]])) == length(BASE)
            @test heavy_atom_count(wr(dir, "z.pdb", String[])) == 0
        end

        @testset "the .balance file" begin
            out = joinpath(dir, "hyd.pdb")
            @test hydrogenation_balance(out) === nothing
            _write_balance(out, (restored = 1, added = 2, h5t_dropped = 3))
            @test read(out * ".balance", String) == "1\t2\t3\n"
            @test hydrogenation_balance(out) == (restored = 1, added = 2, h5t_dropped = 3)
            write(out * ".balance", "1\t2\n")
            @test hydrogenation_balance(out) === nothing
            write(out * ".balance", "a\tb\tc\n")
            @test hydrogenation_balance(out) === nothing
            write(out * ".balance", "")
            @test hydrogenation_balance(out) === nothing
        end

        # ---- pdb2pqr runs: the CondaPkg tools are needed ---------------------------------
        @testset "real runs: 1EHZ restores the 5' phosphorus, crambin needs nothing" begin
            try
                path = joinpath(dir, "nt-bal-1ehz.pdb")
                cp(joinpath(_FIXTURES, "1EHZ-TEST.pdb"), path)
                hp = resolve_hydrogens(
                    path,
                    7.4;
                    ff = NUCLEIC_FORCE_FIELD,
                    titration = NoTitration(),
                )
                @test basename(hp) == "nt-bal-1ehz_pH7.4_amber_notitration.pdb"
                @test hydrogenation_balance(hp) ==
                      (restored = 1, added = 0, h5t_dropped = 1)
                @test isfile(hp * ".balance")
                # the phosphorus of residue 1 is in the output, the H5T is not
                res1 = [
                    strip(l[13:16]) for l in eachline(hp)
                    if startswith(l, "ATOM") && l[22] == 'A' && strip(l[23:27]) == "1"
                ]
                @test "P" in res1 && !("H5T" in res1)
                # a cache hit returns the same balance
                @test resolve_hydrogens(
                    path,
                    7.4;
                    ff = NUCLEIC_FORCE_FIELD,
                    titration = NoTitration(),
                ) == hp
                @test hydrogenation_balance(hp) ==
                      (restored = 1, added = 0, h5t_dropped = 1)
                @test heavy_atom_count(hp) == heavy_atom_count(path)

                path = joinpath(dir, "nt-bal-1crn.pdb")
                cp(joinpath(_FIXTURES, "1CRN-TEST.pdb"), path)
                hp = resolve_hydrogens(path, 7.4; titration = Propka())
                b = hydrogenation_balance(hp)
                # crambin has its OXT already
                @test b == (restored = 0, added = 0, h5t_dropped = 0)
                @test b.added == heavy_atom_count(hp) - heavy_atom_count(path)
            finally
                for f in readdir(_store_dir())
                    startswith(f, "nt-bal-") && rm(joinpath(_store_dir(), f); force = true)
                end
            end
        end
    finally
        rm(dir; recursive = true, force = true)
    end
end

end # module
