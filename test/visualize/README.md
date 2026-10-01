# visualize


| file                    | what it does                                                                                                                                                                                                                                                                                     |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `plastic_vis.jl`        | scatter-plots the plastic sequence: `vis_plastic_points_2D` on a spherical *surface* (2-D generator), `vis_plastic_points_3D` filling a spherical *volume* (3-D generator)                                                                                                                       |
| `sasa_bench.jl`         | accuracy /`area_tol` skip-firing / speed sweeps over ~450 systems, plus summary figures                                                                                                                                                                                                          |
| `sasa_vis.jl`           | four occlusion regimes + mesh-convergence panels, points coloured by exposed/occluded state                                                                                                                                                                                                      |
| `sasa_hydro_vis.jl`     | the`SASA.shell_points` hydration-shell dummy cloud over a packed cluster, plus an `n_target` budget table                                                                                                                                                                                        |

```
julia --project=test/visualize -e 'include("test/visualize/sasa_vis.jl");   vis_sasa_cases()'
julia --project=test/visualize -e 'include("test/visualize/plastic_vis.jl"); vis_plastic_points_2D(2000)'
julia --project=test/visualize -e 'include("test/visualize/plastic_vis.jl"); vis_plastic_points_3D(2000)'
julia --project=test/visualize -e 'include("test/visualize/sasa_hydro_vis.jl"); vis_sasa_hydro()'
```

`sasa_hydro_vis.jl` also has a headless path that needs no window:

```
julia --project=test/visualize -e 'include("test/visualize/sasa_hydro_vis.jl"); sasa_hydro_report()'
```
