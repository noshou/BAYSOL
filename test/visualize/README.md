# visualize

Optional visual checks for the geometry code. They need a display (GLMakie) and are not run by the test suite.
This directory has its own environment (`Project.toml`).

| file | what it does |
|---|---|
| `plastic_vis.jl` | scatter-plots the plastic sequence: `vis_plastic_points_2D` on a spherical *surface* (2-D generator), `vis_plastic_points_3D` filling a spherical *volume* (3-D generator) |
| `sasa_hydro_vis.jl` | the `SASA.sasa` hydration-shell dummy cloud over a packed cluster, plus an `n_target` budget table |
| `xyz/` | static snapshots of the SASA witness pass, for viewing in OVITO, ASE or Jmol (below) |

Run them through [`../run/vis.tcl`](../run/README.md) (`tclsh test/run/vis.tcl --list` shows the checks; name some to run
just those, or none to run all of them), or directly:

```bash
julia --project=test/visualize -e 'include("test/visualize/plastic_vis.jl"); vis_plastic_points_2D(2000)'
julia --project=test/visualize -e 'include("test/visualize/plastic_vis.jl"); vis_plastic_points_3D(2000)'
julia --project=test/visualize -e 'include("test/visualize/sasa_hydro_vis.jl"); vis_sasa_hydro()'
```

`sasa_hydro_vis.jl` also has a headless path that needs no window:

```bash
julia --project=test/visualize -e 'include("test/visualize/sasa_hydro_vis.jl"); sasa_hydro_report()'
```

## Static `.xyz` snapshots (`xyz/`)

These files are frozen data: nothing in the repository generates or reads them. They were written once (commit
`dc36a4b`) from the SASA witness pass to look at how much accessible area the pass loses, atom by atom. Each is
extended XYZ, one frame per case. Per atom: species (a pseudo-element letter standing for a radius), position (Å),
radius (Å), and the number of exposed sample directions out of 256 with the witness pass off (`n_ref`) and on
(`n_witness`). Per frame, the comment line holds the case label, the probe radius (1.4 Å), `n_dirs`, `n_occ` and the
accessible area with the pass off and on (`area_ref`, `area_witness`) and the area lost (`area_lost`).

| file | contents |
|---|---|
| `sasa_lattice.xyz` | one jittered 5×5×5 lattice plus an isolated atom (radius 1.5 Å) |
| `sasa_surface_r2.00.xyz`, `sasa_surface_r3.48.xyz`, `sasa_surface_r5.00.xyz` | one large atom of radius r (2.00, 3.48 or 5.00 Å) on the top face of a jittered 6×6×6 lattice of radius-1.5 Å atoms, one frame per height (24 values around the depth where its expanded sphere first emerges from the lattice surface) and lateral offset (4 values): from no exposure, through a sliver, to a few percent |

The geometries come from `test/utils/geometry.jl`, which `test_sasa.jl` also uses. The snapshots reflect the SASA
code as of that commit and will not follow later changes to it.
