# SPDX-License-Identifier: LGPL-2.1-or-later

# Optional visual check for PlasticMap. Kept out of the module so the geometry
# core depends only on Roots; GLMakie lives in test/visualize/Project.toml.
#
# Run with:
#   julia --project=test/visualize -e 'include("test/visualize/plastic_vis.jl"); vis_plastic_points(2000)'

using BayeSol.Solvation.SASA: PlasticMap
using .PlasticMap: plastic_points
using GLMakie

"""
    vis_plastic_points(n) -> Nothing

Scatter-plot the first `n` plastic-sequence points on the unit sphere, blocking
until the window is closed.
"""
function vis_plastic_points(n)
    pts = plastic_points(Int(n))
    x = [p[1] for p in pts]
    y = [p[2] for p in pts]
    z = [p[3] for p in pts]

    fig = Figure()
    ax = Axis3(fig[1, 1], title = "Plastic sequence on the unit sphere", aspect = :data)
    scatter!(ax, x, y, z, color = z, colormap = :viridis, markersize = 6)
    wait(display(fig))
end
