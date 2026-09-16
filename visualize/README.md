# visualize

Optional visual and statistical harnesses for the forward mod


| file                | what it does                                                                                              |
| --------------------- | ----------------------------------------------------------------------------------------------------------- |
| `plastic_vis.jl`    | scatter-plots the plastic sequence on the unit sphere                                                     |
| `sasa_bench.jl`     | accuracy /`area_tol` skip-firing / speed sweeps over ~450 systems, plus summary figures                   |
| `sasa_vis.jl`       | four occlusion regimes + mesh-convergence panels, points coloured by exposed/occluded state               |
| `sasa_hydro_vis.jl` | the`SASA.shell_points` hydration-shell dummy cloud over a packed cluster, plus an `n_target` budget table |
| `hydrophobicity_vis.jl` | `Hydrophobicity.cavity_hydrophilicity` on a sealed c/o shell: bead-class panel plus a continuous hydrophilicity (χ) panel over the `CAVITY` beads |

```
julia --project=visualize -e 'include("visualize/sasa_vis.jl");   vis_sasa_cases()'
julia --project=visualize -e 'include("visualize/plastic_vis.jl"); vis_plastic_points(2000)'
julia --project=visualize -e 'include("visualize/sasa_hydro_vis.jl"); vis_sasa_hydro()'
julia --project=visualize -e 'include("visualize/hydrophobicity_vis.jl"); vis_hydrophobicity()'
```

`sasa_hydro_vis.jl` also has a headless path that needs no window:

```
julia --project=visualize -e 'include("visualize/sasa_hydro_vis.jl"); sasa_hydro_report()'
```

`hydrophobicity_vis.jl` likewise:

```
julia --project=visualize -e 'include("visualize/hydrophobicity_vis.jl"); hydrophobicity_report()'
```
