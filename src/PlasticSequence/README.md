# PlasticSequence

Even point sets drawn from the plastic (`R_d`) family of additive low-discrepancy sequences (Roberts, M. (2018). The Unreasonable Effectiveness of Quasirandom Sequences.). Consumers: `SASA` (surface sampling directions) and `MolecularStructure.excluded_volume` (`plastic_points(N_VOL_SHELL, Val(3), Val(:volume))`).

- The plastic ratios are module-level constants in `PlasticSequence.jl`: `PLASTIC_RATIO_2` ≈ 1.324718 (real root of x³ = x + 1) and `PLASTIC_RATIO_3` ≈ 1.220744 (real root of x⁴ = x + 1), plus the precomputed powers `PLASTIC_RATIO_2_SQR`, `PLASTIC_RATIO_3_SQR` and `PLASTIC_RATIO_3_CUBE`. They are hardcoded rather than solved for at load time, so the package no longer depends on Roots.jl.
- Vec2, Vec3: NTuple{2,Float64}/NTuple{3,Float64} point types.
- `plastic_points`(n::Int, ::Val{2}) -> Vector{Vec2}: the first n raw 2-D R₂ terms (frac(i/ρ), frac(i/ρ²)), uniform on [0, 1)².
- `plastic_points`(n::Int, ::Val{3}) -> Vector{Vec3} (same as Val{3}, Val{:surface}): those same 2-D R₂ terms read as (azimuth, height) and lifted onto the **surface** of the unit sphere via Lambert's cylindrical equal-area projection. Points are uniform in *area*, |p| == 1 .
- `plastic_points`(n::Int, ::Val{3}, ::Val{:volume}) -> Vector{Vec3}: the 3-D R₃ terms lifted to **fill** the unit ball, a 3-D region built from the R₃ generator (the extra coordinate becomes a radius, inverse-CDF-corrected for the sphere's r²dr volume element). Points are uniform in *volume*, 0 ≤ |p| < 1.
- `plastic_points`(n::Int; dim::Int=3, shape::Symbol=:surface): keyword convenience dispatching to the Val methods above; shape is only consulted when dim == 3.

Both 3-D layouts are deterministic and prefix-stable, term i never changes as n grows, so `plastic_points`(k, args...) == `plastic_points`(n, args...)[1:k] for any k ≤ n.

```julia
using BAYSOL.PlasticSequence: plastic_points

pts2d = plastic_points(500, Val(2))                 # Vector{Vec2}, [0,1)^2
surf  = plastic_points(256)                         # Vector{Vec3}, sphere surface (default)
ball  = plastic_points(256, Val(3), Val(:volume))   # Vector{Vec3}, fills the sphere volume
```
