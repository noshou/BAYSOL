# SPDX-License-Identifier: LGPL-2.1-or-later

# Helpers to dump SASA witness-pass geometries as extended XYZ (readable by OVITO, ASE,
# Jmol, ...), one frame per case, so a case can be looked at and its lost area gauged atom
# by atom. Nothing runs on include: call `write_sasa_xyz` with the cases you want.
#
# Per atom: species (pseudo-element letter of `SASA_RADII`), position (Å), radius (Å),
# and the number of exposed sample directions out of SHELL_SAMPLE with the witness pass
# off (n_ref) and on (n_witness). Per frame (comment line): the case label, and the
# accessible area with the pass off/on and the area lost.
#
# The geometries test_sasa.jl uses come from fixtures/functions/geometry.jl, e.g.
#
#   julia --project=test/visualize -e '
#       include("test/visualize/sasa_witness_xyz.jl")
#       crds = witness_lattice()
#       write_sasa_xyz("lattice.xyz", [(label = "witness lattice", elms = fill("q", length(crds)), crds = crds)])
#       write_sasa_xyz("r5.xyz", filter(c -> c.r == 5.0, surface_atom_cases()))'

using BAYSOL
using BAYSOL.SASA: SASA
using BAYSOL.MolecularStructure: MolecularStructure
using BAYSOL.PlasticSequence: plastic_points
using BAYSOL.SASA: SHELL_SAMPLE, SASA_N_OCC
using Printf: @printf, @sprintf

include(joinpath(@__DIR__, "..", "fixtures", "functions", "geometry.jl"))   # SASA_RADII, lattices, cases

"Per-atom exposed-direction counts with the witness pass off and on, and the radii."
function _witness_counts(elms, crds; probe = 1.4)
    m = MolecularStructure._build("sasa-xyz", elms, crds, () -> Float64[SASA_RADII[e] for e in elms])
    xyz = MolecularStructure.coords_cartesian(m); rads = MolecularStructure.radii(m)
    rmax = MolecularStructure.r_max(m); tree = MolecularStructure.neighbour_tree(m)
    pmap = plastic_points(SHELL_SAMPLE)
    _, _, _, off = SASA._sasa_loop(tree, xyz, rads, rmax, pmap, probe, SHELL_SAMPLE, SHELL_SAMPLE)
    _, _, _, on  = SASA._sasa_loop(tree, xyz, rads, rmax, pmap, probe, SHELL_SAMPLE, SASA_N_OCC)
    return rads, off, on
end

"Append one extended-XYZ frame; returns (area off, area on) in Å²."
function _write_frame(io, label, elms, crds; probe = 1.4)
    rads, off, on = _witness_counts(elms, crds; probe = probe)
    w = [4π * (r + probe)^2 / SHELL_SAMPLE for r in rads]
    a_off = sum(off .* w); a_on = sum(on .* w)
    println(io, length(elms))
    println(io, "Properties=species:S:1:pos:R:3:radius:R:1:n_ref:I:1:n_witness:I:1 ",
            "case=\"", label, "\" probe=", probe, " n_dirs=", SHELL_SAMPLE, " n_occ=", SASA_N_OCC,
            @sprintf(" area_ref=%.3f area_witness=%.3f area_lost=%.3f", a_off, a_on, a_off - a_on))
    for (k, (e, c)) in enumerate(zip(elms, crds))
        @printf(io, "%s %.6f %.6f %.6f %.3f %d %d\n", e, c[1], c[2], c[3], rads[k], off[k], on[k])
    end
    return a_off, a_on
end

"""
    write_sasa_xyz(path, cases; probe = 1.4) -> (area_ref, area_witness)

Write `cases` to `path` as a multi-frame extended-XYZ file, one frame per case, and
return the total accessible area (Å²) over all frames with the witness pass off and on.
Each case needs `label`, `elms` (keys of `SASA_RADII`) and `crds` (one `(x, y, z)` per
atom), e.g. the named tuples of `surface_atom_cases()`. Writes nothing else and prints
nothing.
"""
function write_sasa_xyz(path::AbstractString, cases; probe::Real = 1.4)
    a = 0.0; b = 0.0
    open(path, "w") do io
        for c in cases
            x, y = _write_frame(io, c.label, c.elms, c.crds; probe = probe)
            a += x; b += y
        end
    end
    return a, b
end
