# visualize

Optional visual checks for the geometry code. They need a display (GLMakie) and are not run by the test suite.
This directory has its own environment (`Project.toml`).


| file                | what it does                                                                                                                                                               |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `plastic-vis.jl`    | scatter-plots the plastic sequence: `visPlasticPoints2d` on a spherical *surface* (2-D generator), `visPlasticPoints3d` filling a spherical *volume* (3-D generator) |
| `sasa-hydro-vis.jl` | the `Geometry.sasa` hydration-shell dummy cloud over a packed cluster, plus an `nTarget` budget table                                                                     |

Run them through `bysl vis` ([`../../dev/README.md`](../../dev/README.md); `bysl vis --list` shows the checks; name some to run
just those, or none to run all of them), or directly:

```bash
julia --project=test/visualize -e 'include("test/visualize/plastic-vis.jl"); visPlasticPoints2d(2000)'
julia --project=test/visualize -e 'include("test/visualize/plastic-vis.jl"); visPlasticPoints3d(2000)'
julia --project=test/visualize -e 'include("test/visualize/sasa-hydro-vis.jl"); visSasaHydro()'
```

`sasa-hydro-vis.jl` also has a headless path that needs no window:

```bash
julia --project=test/visualize -e 'include("test/visualize/sasa-hydro-vis.jl"); sasaHydroReport()'
```
