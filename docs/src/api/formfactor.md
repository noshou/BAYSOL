# FormFactor

Pure-Julia X-ray form-factor backend (`src/FormFactor/FormFactor.jl`):
`f(q, E) = f0(s) + f1(E) + i*f2(E)` from the bundled
`form_factors.sqlite3` (Waasmaier-Kirfel f0, Chantler FFAST anomalous
terms).

```@autodocs
Modules = [BayeSol.FormFactor]
```
