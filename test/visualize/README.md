# visualize


| file                    | what it does                                                                                                                                                                                                                                                                                     |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `plastic_vis.jl`        | scatter-plots the plastic sequence: `vis_plastic_points_2D` on a spherical *surface* (2-D generator), `vis_plastic_points_3D` filling a spherical *volume* (3-D generator)                                                                                                                       |
| `sasa_hydro_vis.jl`     | the`SASA.sasa` hydration-shell dummy cloud over a packed cluster, plus an `n_target` budget table                                                                                                                                                                                        |
| `sasa_witness_xyz.jl`   | helper `write_sasa_xyz(path, cases)`: dumps the SASA witness-pass geometries you pass it (e.g. `witness_lattice()`, `surface_atom_cases()` from `test/fixtures/functions/geometry.jl`, the ones `test_sasa.jl` checks) as multi-frame extended XYZ; per atom the radius and the exposed-direction counts with the pass off (`n_ref`) and on (`n_witness`), per frame the area lost. Nothing runs on include |

```
julia --project=test/visualize -e 'include("test/visualize/plastic_vis.jl"); vis_plastic_points_2D(2000)'
julia --project=test/visualize -e 'include("test/visualize/plastic_vis.jl"); vis_plastic_points_3D(2000)'
julia --project=test/visualize -e 'include("test/visualize/sasa_hydro_vis.jl"); vis_sasa_hydro()'
julia --project=test/visualize -e 'include("test/visualize/sasa_witness_xyz.jl"); write_sasa_xyz("r5.xyz", filter(c -> c.r == 5.0, surface_atom_cases()))'
```

`sasa_hydro_vis.jl` also has a headless path that needs no window:

```
julia --project=test/visualize -e 'include("test/visualize/sasa_hydro_vis.jl"); sasa_hydro_report()'
```
