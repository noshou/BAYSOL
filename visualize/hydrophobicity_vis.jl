# SPDX-License-Identifier: LGPL-2.1-or-later
# Visual check for `Hydrophobicity.cavity_hydrophilicity`: a packed
# carbon/oxygen cluster with one small buried vacancy drives
# `SASA.shell_points` to produce `CAVITY`-class beads lining that vacancy's
# inner wall, and every one of those beads gets a nearest-atom ASP
# assignment. Packed (not hollow) on purpose: a cavity is an *enclosed
# interior* void by definition, and the vacancy sitting inside real packed
# structure is what makes that look like an actual buried protein pocket
# instead of the whole inside of an empty shell.
#
# Run with:
#   julia --project=visualize -e 'include("visualize/hydrophobicity_vis.jl"); vis_hydrophobicity()'
#
# Numbers only, no window (works headless):
#   julia --project=visualize -e 'include("visualize/hydrophobicity_vis.jl"); hydrophobicity_report()'

using ScatterNet
using ScatterNet.Interfaces: Interfaces, RadiiSource
using ScatterNet.Molecule.Molecules: Molecules, Molecule
using ScatterNet.Molecule.SASA: SASA
using ScatterNet.Molecule.Hydrophobicity: Hydrophobicity, ASP, cavity_hydrophilicity
using Printf: @printf, @sprintf
using GLMakie

const _ASP_SCALE = Hydrophobicity._ASP_SCALE

# --------------------------------------------------------------------------
# radii source
# --------------------------------------------------------------------------

"""
Test-only [`RadiiSource`](@ref) mapping element labels to hand-picked radii,
so the sealed shell scene has exact, reproducible geometry instead of
whatever the atomic-radii database happens to hold. Mirrors
`sasa_hydro_vis.jl`'s `HydroRadii`, renamed to avoid a name clash if both
files are `include`d in the same session.
"""
struct HydrophobicityRadii <: RadiiSource
    table::Dict{String,Float64}
end

"""
    lookup(src::HydrophobicityRadii, ions) -> Vector{Tuple{String,Union{Float64,Nothing}}}

Resolve each label against `src.table`, `nothing` for anything absent.
"""
function Interfaces.lookup(src::HydrophobicityRadii, ions)
    out = Vector{Tuple{String,Union{Float64,Nothing}}}(undef, length(ions))
    for (i, ion) in enumerate(ions)
        s = String(ion)
        out[i] = (s, get(src.table, s, nothing))
    end
    return out
end

# --------------------------------------------------------------------------
# the scene: a packed cluster with one buried internal vacancy
# --------------------------------------------------------------------------

"`0:n-1` grid over 3 axes, as a flat vector of `(i,j,k)`."
_fcc_grid(n::Int) = vec([(i, j, k) for i in 0:n-1, j in 0:n-1, k in 0:n-1])

"""
    fcc_lattice(n, a) -> Vector{NTuple{3,Float64}}

Face-centred-cubic lattice sites over an `n x n x n` block of conventional
cells of side `a` (4 atoms/cell). Same construction as `sasa_hydro_vis.jl`'s
`fcc_lattice`, reproduced here so this file stays self-contained under
`visualize/` (no shared fixture dependency).
"""
function fcc_lattice(n::Int, a::Float64)
    g = _fcc_grid(n)
    pts = [(a * i, a * j, a * k) for (i, j, k) in g]
    for (dx, dy, dz) in ((0.5, 0.5, 0.0), (0.5, 0.0, 0.5), (0.0, 0.5, 0.5))
        append!(pts, [(a * (i + dx), a * (j + dy), a * (k + dz)) for (i, j, k) in g])
    end
    return pts
end

"""
    hydro_shell_scene(; n = 6, a = 2.2, frac = 0.5, r = 1.6, probe = 1.4,
                         vacancy_r = 4.3) -> NamedTuple

A packed, close-fit FCC cluster of atoms alternating between `"c"`
(hydrophobic, `ASP["c"] > 0`) and `"o"` (hydrophilic, `ASP["o"] < 0`) -- the
ASP table's two most contrasting entries -- trimmed to a roughly spherical
block, then hollowed out by removing every lattice site within `vacancy_r`
of the centroid. The result is real, densely packed structure filling the
whole volume with one small enclosed pocket buried in the middle: rays cast
outward from the pocket's inner wall (`SASA.shell_points`'s escape test)
have to cross several atom-diameters of solid packing before they could
reach bulk solvent, so they're blocked and that wall reads as `CAVITY`. This
is deliberately unlike a thin hollow shell, where "cavity" would mean the
entire empty interior rather than a small buried pocket -- a solid cluster
with one vacancy is what an internal water cavity in a folded protein
actually looks like. `vacancy_r` must clear the expanded atom radius
`r + probe` by a real margin (default beads live comfortably below the
default 3.0 Å): a vacancy no bigger than that radius gets swallowed by the
neighbouring wall atoms' own expanded spheres before any point can be
exposed into it at all, so `shell_points` finds nothing there, not even a
`CAVITY` bead.
"""
function hydro_shell_scene(; n::Int = 6, a::Float64 = 2.2, frac::Float64 = 0.5,
                              r::Float64 = 1.6, probe::Float64 = 1.4,
                              vacancy_r::Float64 = 4.3)
    raw = fcc_lattice(n, a)
    ctr = ntuple(t -> sum(p[t] for p in raw) / length(raw), 3)
    dist(p) = sqrt(sum((p[t] - ctr[t])^2 for t in 1:3))
    kept = [p for p in raw if dist(p) <= a * n * frac && dist(p) > vacancy_r]
    elms = [isodd(i) ? "c" : "o" for i in eachindex(kept)]
    src = HydrophobicityRadii(Dict("c" => r, "o" => r))
    mol = Molecules.create("packed c/o cluster, buried vacancy", elms, kept;
                            radii_source = src)
    return (; mol, probe, title = "Packed c/o cluster ($(length(kept)) atoms, buried vacancy)")
end

# --------------------------------------------------------------------------
# color scale for continuous χ
# --------------------------------------------------------------------------

const EXPOSED_COLOR  = RGBf(1.00, 0.62, 0.13)   # warm/bright
const OCCLUDED_COLOR = RGBf(0.24, 0.26, 0.32)   # dark/desaturated
const DUMMY_COLOR    = RGBf(0.90, 0.15, 0.55)   # distinct from atoms and points
const CONCAVE_COLOR  = RGBf(0.20, 0.55, 0.90)
const CAVITY_COLOR   = RGBf(0.35, 0.80, 0.35)
const ATOM_COLOR     = RGBf(0.55, 0.62, 0.75)

# Diverging χ palette: hydrophilic (negative) <-> neutral (0) <-> hydrophobic
# (positive), matching ASP's own sign convention.
const HYDROPHILIC_COLOR = RGBf(0.15, 0.45, 0.95)   # cool blue
const NEUTRAL_COLOR     = RGBf(0.65, 0.65, 0.65)   # grey
const HYDROPHOBIC_COLOR = RGBf(0.95, 0.60, 0.10)   # warm amber

"""
    chi_color(χ, χmax) -> RGBf

Linear diverging colour for a z-scored ASP value `χ`, clamped to
`[-χmax, χmax]` and interpolated `HYDROPHILIC_COLOR -> NEUTRAL_COLOR ->
HYDROPHOBIC_COLOR`.
"""
function chi_color(χ::Float64, χmax::Float64)
    t = clamp(χ / χmax, -1.0, 1.0)
    return t < 0 ?  RGBf((1 + t) .* Tuple(NEUTRAL_COLOR) .+ (-t) .* Tuple(HYDROPHILIC_COLOR)...) :
                    RGBf((1 - t) .* Tuple(NEUTRAL_COLOR) .+ t .* Tuple(HYDROPHOBIC_COLOR)...)
end

"""
    bead_element_chi(mol, pts, sel) -> (elements, χ)

Per-`sel`-bead nearest-atom element label and z-scored ASP value, computed
the same way [`Hydrophobicity._aggregate`](@ref) does internally but keeping
the per-bead breakdown instead of collapsing straight to `(μ_χ, σ_χ)`.
"""
function bead_element_chi(mol::Molecule, pts::Matrix{Float64}, sel::Vector{Int})
    crds = Molecules.coords_cartesian(mol)
    els  = Molecules.elms(mol)
    n = length(sel)
    elements = Vector{String}(undef, n)
    χ = Vector{Float64}(undef, n)
    for (k, i) in enumerate(sel)
        d2 = [sum((crds[t, j] - pts[t, i])^2 for t in 1:3) for j in axes(crds, 2)]
        j = argmin(d2)
        el = els[j]
        elements[k] = el
        χ[k] = get(ASP, el, 0.0) / _ASP_SCALE
    end
    return (; elements, χ)
end

# --------------------------------------------------------------------------
# headless report
# --------------------------------------------------------------------------

"""
    hydrophobicity_report(; probe = 1.4, n_target = nothing) -> Nothing

Print the hydration-shell bead-class counts on [`hydro_shell_scene`](@ref),
`cavity_hydrophilicity`'s `(μ_χ, σ_χ)` summary, the per-`CAVITY`-bead
nearest-atom element/χ breakdown that summary is computed from, and the
z-scored `ASP` table for reference.
"""
function hydrophobicity_report(; probe::Float64 = 1.4, n_target::Union{Nothing,Int} = nothing)
    sc = hydro_shell_scene(; probe)
    println(sc.title, "  (probe = ", probe, ")")

    pts, pa, cls = SASA.shell_points(sc.mol; probe, n_target)
    @printf("  %d dummies: %d convex, %d concave, %d cavity\n\n",
            size(pts, 2), count(==(SASA.CONVEX), cls),
            count(==(SASA.CONCAVE), cls), count(==(SASA.CAVITY), cls))

    μχ, σχ = cavity_hydrophilicity(sc.mol; probe, n_target)
    @printf("  cavity_hydrophilicity: μ_χ = %.4f, σ_χ = %.4f\n\n", μχ, σχ)

    sel = findall(==(SASA.CAVITY), cls)
    bc = bead_element_chi(sc.mol, pts, sel)
    println("  per-cavity-bead nearest-atom assignment:")
    @printf("    %-6s %-8s %-10s\n", "bead", "element", "chi (z-scored ASP)")
    for (k, i) in enumerate(sel)
        @printf("    %-6d %-8s %-10.4f\n", i, bc.elements[k], bc.χ[k])
    end
    nc = count(==("c"), bc.elements)
    no = count(==("o"), bc.elements)
    @printf("\n  cavity beads by nearest element: c = %d, o = %d\n\n", nc, no)

    println("  ASP table (z-scored by _ASP_SCALE):")
    @printf("    %-6s %-10s %-14s\n", "elem", "raw ASP", "z-scored")
    for k in sort(collect(keys(ASP)))
        @printf("    %-6s %-10.3f %-14.4f\n", k, ASP[k], ASP[k] / _ASP_SCALE)
    end
    return nothing
end

# --------------------------------------------------------------------------
# plotting
# --------------------------------------------------------------------------

"""
    hydrophobicity_figure(; n_target = nothing, probe = 1.4) -> Figure

Two-panel view of [`hydro_shell_scene`](@ref)'s hydration beads: left panel
colours beads by `BeadClass` exactly like `sasa_hydro_figure` does (same
colour constants, for visual consistency across the two files); right panel
colours the same beads by continuous z-scored hydrophilicity `χ`, a
diverging scale from [`HYDROPHILIC_COLOR`](@ref) through
[`NEUTRAL_COLOR`](@ref) to [`HYDROPHOBIC_COLOR`](@ref). Atoms are drawn
small/translucent for context. Returns the `Figure` without displaying it.
"""
function hydrophobicity_figure(; n_target::Union{Nothing,Int} = nothing, probe::Float64 = 1.4)
    sc = hydro_shell_scene(; probe)
    crds = Molecules.coords_cartesian(sc.mol)
    rads = Molecules.radii(sc.mol)
    natoms = size(crds, 2)
    pts, _, cls = SASA.shell_points(sc.mol; probe, n_target)

    sel = findall(==(SASA.CAVITY), cls)
    bc = bead_element_chi(sc.mol, pts, sel)
    χmax = isempty(bc.χ) ? 1.0 : maximum(abs, bc.χ)
    χmax = χmax > 0 ? χmax : 1.0
    χ_all = zeros(Float64, size(pts, 2))
    for (k, i) in enumerate(sel)
        χ_all[i] = bc.χ[k]
    end

    fig = Figure(size = (1600, 900))

    # left: bead class
    ax1 = Axis3(
        fig[1, 1];
        title = @sprintf("%s: bead class\n%d dummies (%d convex, %d concave, %d cavity)",
            sc.title, size(pts, 2), count(==(SASA.CONVEX), cls),
            count(==(SASA.CONCAVE), cls), length(sel)),
        titlesize = 14, aspect = :data, azimuth = 1.1π,
        xlabel = "x", ylabel = "y", zlabel = "z")

    for i in 1:natoms
        ρ = Float32(rads[i] + probe)
        c = Point3f(crds[1, i], crds[2, i], crds[3, i])
        mesh!(ax1, Sphere(c, ρ); color = (ATOM_COLOR, 0.10), transparency = true, shading = NoShading)
    end
    bead_colour = Dict(SASA.CONVEX => DUMMY_COLOR, SASA.CONCAVE => CONCAVE_COLOR,
                        SASA.CAVITY => CAVITY_COLOR)
    # cavity beads are rare and the whole point of this figure, so they get a
    # visibly larger marker instead of blending in at the same size as everything else
    bead_size = Dict(SASA.CONVEX => 9, SASA.CONCAVE => 9, SASA.CAVITY => 20)
    scatter!(ax1, [Point3f(pts[1, k], pts[2, k], pts[3, k]) for k in axes(pts, 2)];
            color = [bead_colour[c] for c in cls], markersize = [bead_size[c] for c in cls])

    els1 = [MarkerElement(color = ATOM_COLOR, marker = :circle, markersize = 14),
            MarkerElement(color = DUMMY_COLOR, marker = :circle, markersize = 10),
            MarkerElement(color = CONCAVE_COLOR, marker = :circle, markersize = 10),
            MarkerElement(color = CAVITY_COLOR, marker = :circle, markersize = 10)]
    Legend(fig[2, 1], els1, ["atom (expanded radius)", "bead: convex", "bead: concave", "bead: cavity"];
            orientation = :horizontal, framevisible = false, labelsize = 12)

    # right: continuous hydrophilicity, cavity beads only (the rest carry no
    # χ assignment -- only CAVITY beads are scored by cavity_hydrophilicity)
    ax2 = Axis3(
        fig[1, 2];
        title = @sprintf("hydrophilicity of cavity beads (n=%d)\nc (ASP=%.2f) hydrophobic, o (ASP=%.2f) hydrophilic",
            length(sel), ASP["c"] / _ASP_SCALE, ASP["o"] / _ASP_SCALE),
        titlesize = 14, aspect = :data, azimuth = 1.1π,
        xlabel = "x", ylabel = "y", zlabel = "z")

    for i in 1:natoms
        ρ = Float32(rads[i] + probe)
        c = Point3f(crds[1, i], crds[2, i], crds[3, i])
        mesh!(ax2, Sphere(c, ρ); color = (ATOM_COLOR, 0.10), transparency = true, shading = NoShading)
    end
    if !isempty(sel)
        scatter!(ax2, [Point3f(pts[1, i], pts[2, i], pts[3, i]) for i in sel];
                color = [chi_color(χ, χmax) for χ in bc.χ], markersize = 22)
    end

    Colorbar(fig[2, 2]; limits = (-χmax, χmax),
            colormap = Makie.cgrad([HYDROPHILIC_COLOR, NEUTRAL_COLOR, HYDROPHOBIC_COLOR]),
            vertical = false, label = "chi (z-scored ASP): hydrophilic <-> hydrophobic",
            labelsize = 12)

    return fig
end

"""
    vis_hydrophobicity(; n_target = nothing, probe = 1.4) -> Nothing

Display [`hydrophobicity_figure`](@ref): bead-class and continuous-χ views of
the sealed c/o shell's hydration beads, side by side. Blocks until the
window is closed.

# Keywords
-   `n_target`: global dummy budget; `nothing` derives it from accessible area.
-   `probe`:    solvent probe radius.
"""
vis_hydrophobicity(; n_target::Union{Nothing,Int} = nothing, probe::Float64 = 1.4) =
    wait(display(hydrophobicity_figure(; n_target, probe)))
