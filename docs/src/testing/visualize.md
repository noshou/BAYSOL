# visualize

Optional visual checks for the geometry code. They need a display (GLMakie) and are not run by the test suite.
This directory has its own environment (`Project.toml`).

| file | what it does |
|---|---|
| `plastic_vis.jl` | scatter-plots the plastic sequence: `vis_plastic_points_2D` on a spherical *surface* (2-D generator), `vis_plastic_points_3D` filling a spherical *volume* (3-D generator) |
| `sasa_hydro_vis.jl` | the `Geometry.sasa` hydration-shell dummy cloud over a packed cluster, plus an `n_target` budget table |

Run them through [`../../dev/vis.tcl`](dev.md) (`tclsh dev/vis.tcl --list` shows the checks; name some to run
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
