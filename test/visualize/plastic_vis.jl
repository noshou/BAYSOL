# SPDX-License-Identifier: LGPL-2.1-or-later

# Optional visual check for PlasticSequence. Kept out of the module so the
# geometry core depends only on Roots; GLMakie lives in
# test/visualize/Project.toml.
#
# `_2D` is the 2-D `R₂` generator, lifted onto a spherical **surface**
# (`Val(3), Val(:surface)`, `PlasticSequence`'s default): a 2-D manifold, so
# 2 low-discrepancy coordinates parametrize it fully.
#
# `_3D` is the 3-D `R₃` generator, lifted to fill a spherical **volume**
# (`Val(3), Val(:volume)`): a genuinely 3-D region, needing a 3rd (radial)
# coordinate the surface case has no use for.
#
# Run with:
#   julia --project=test/visualize -e 'include("test/visualize/plastic_vis.jl"); vis_plastic_points_2D(2000)'
#   julia --project=test/visualize -e 'include("test/visualize/plastic_vis.jl"); vis_plastic_points_3D(2000)'

using BAYSOL.Geometry: PlasticSequence
using .PlasticSequence: plastic_points
using GLMakie

"""
    vis_plastic_points_2D(n) -> Nothing

Scatter-plot the first `n` plastic-sequence points on a spherical **surface**
(the 2-D `R₂` generator, `Val(3), Val(:surface)`), blocking until the window
is closed. Every point satisfies `|p| == 1`.
"""
function vis_plastic_points_2D(n)
    pts = plastic_points(Int(n), Val(3), Val(:surface))
    x = [p[1] for p in pts]
    y = [p[2] for p in pts]
    z = [p[3] for p in pts]

    fig = Figure()
    ax = Axis3(fig[1, 1], title = "Plastic sequence on a spherical surface (2-D generator)", aspect = :data)
    scatter!(ax, x, y, z, color = z, colormap = :viridis, markersize = 6)
    wait(display(fig))
end

"""
    vis_plastic_points_3D(n) -> Nothing

Scatter-plot the first `n` plastic-sequence points filling a spherical
**volume** (the 3-D `R₃` generator, `Val(3), Val(:volume)`), blocking until
the window is closed. Every point satisfies `0 ≤ |p| < 1`; colour encodes
distance from the centre so the volume-uniform (not surface-clustered)
fill is visible.
"""
function vis_plastic_points_3D(n)
    pts = plastic_points(Int(n), Val(3), Val(:volume))
    x = [p[1] for p in pts]
    y = [p[2] for p in pts]
    z = [p[3] for p in pts]
    r = [sqrt(p[1]^2 + p[2]^2 + p[3]^2) for p in pts]

    fig = Figure()
    ax = Axis3(fig[1, 1], title = "Plastic sequence filling a spherical volume", aspect = :data)
    scatter!(ax, x, y, z, color = r, colormap = :viridis, markersize = 6)
    wait(display(fig))
end
