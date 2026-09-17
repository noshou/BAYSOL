# visualize

Optional visual and statistical harnesses for the forward mod


| file                | what it does                                                                                              |
| --------------------- | ----------------------------------------------------------------------------------------------------------- |
| `plastic_vis.jl`    | scatter-plots the plastic sequence on the unit sphere                                                     |
| `sasa_bench.jl`     | accuracy /`area_tol` skip-firing / speed sweeps over ~450 systems, plus summary figures                   |
| `sasa_vis.jl`       | four occlusion regimes + mesh-convergence panels, points coloured by exposed/occluded state               |
| `sasa_hydro_vis.jl` | the`SASA.shell_points` hydration-shell dummy cloud over a packed cluster, plus an `n_target` budget table |
| `electrostatics_vis.jl` | `Electrostatics.nucleic_acid_cavity_electrostatics`/`protein_cavity_electrostatics` on a sealed cavity: bead-class panel plus a continuous screened-field (χ) panel over the `CAVITY` beads, for both a phosphate-backbone scene (stands in for DNA and RNA alike) and an Asp/Lys protein scene |

```
julia --project=visualize -e 'include("visualize/sasa_vis.jl");   vis_sasa_cases()'
julia --project=visualize -e 'include("visualize/plastic_vis.jl"); vis_plastic_points(2000)'
julia --project=visualize -e 'include("visualize/sasa_hydro_vis.jl"); vis_sasa_hydro()'
julia --project=visualize -e 'include("visualize/electrostatics_vis.jl"); vis_electrostatics_na()'
julia --project=visualize -e 'include("visualize/electrostatics_vis.jl"); vis_electrostatics_protein()'
```

`sasa_hydro_vis.jl` and `electrostatics_vis.jl` also have a headless path that needs no window:

```
julia --project=visualize -e 'include("visualize/sasa_hydro_vis.jl"); sasa_hydro_report()'
julia --project=visualize -e 'include("visualize/electrostatics_vis.jl"); electrostatics_report()'
```
