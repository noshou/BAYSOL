# SPDX-License-Identifier: LGPL-3.0-or-later

# Visual check for the hydration-shell dummy cloud `Geometry.sasa`
# builds; every solvent-accessible sample point becomes one dummy, so the
# shell is a resolved layer over the molecular surface rather than one marker
# per exposed atom. 
#
# Run with:
#   julia --project=test/visualize \
#       -e 'include("test/visualize/sasa-hydro-vis.jl"); visSasaHydro()'
#
# Numbers only, no window (works headless):
#   julia --project=test/visualize \
#       -e 'include("test/visualize/sasa-hydro-vis.jl"); sasaHydroReport()'

using BAYSOL
using BAYSOL.MolecularStructure: MolecularStructure, Molecule
using BAYSOL: Geometry
using BAYSOL.Geometry: PROBE_RADIUS
using BAYSOL.Geometry: plasticPoints
using BAYSOL.Geometry: blocked
using Printf: @printf, @sprintf
using GLMakie

# --------------------------------------------------------------------------
# radii source
# --------------------------------------------------------------------------

"""
Test-only table mapping element labels to hand-picked radii,
so the packed-sphere scene has exact, reproducible geometry instead of
whatever the atomic-radii database happens to hold.
"""
struct HydroRadii
    table::Dict{String,Float64}
end

"""
Build a molecule whose per-atom radii come from `src.table` (element label -> Å),
through `MolecularStructure._build`, the lazy-radii constructor `create` itself
uses. Labels are lowercased as `create` does.
"""
function radiiMol(name, elms, crds, src)
    es = String[lowercase(e) for e in elms]
    return MolecularStructure._build(
        name,
        es,
        crds,
        () -> Float64[src.table[e] for e in es],
    )
end

# --------------------------------------------------------------------------
# the scene: a real packed cluster (FCC lattice carved to a sphere)
# --------------------------------------------------------------------------

"`0:n-1` grid over 3 axes, as a flat vector of `(i,j,k)`."
_fccGrid(n::Int) = vec([(i, j, k) for i in 0:(n-1), j in 0:(n-1), k in 0:(n-1)])

"""
    fccLattice(n, a) -> Vector{NTuple{3,Float64}}

Face-centred-cubic lattice sites over an `n×n×n` block of conventional cells
of side `a` (4 atoms/cell). Nearest-neighbour distance is `a/√2`.
"""
function fccLattice(n::Int, a::Float64)
    g = _fccGrid(n)
    pts = [(a * i, a * j, a * k) for (i, j, k) in g]
    for (dx, dy, dz) in ((0.5, 0.5, 0.0), (0.5, 0.0, 0.5), (0.0, 0.5, 0.5))
        append!(pts, [(a * (i + dx), a * (j + dy), a * (k + dz)) for (i, j, k) in g])
    end
    return pts
end

"""
    packedClusterScene(; probe = PROBE_RADIUS, r = 1.5, n = 4, a = 2.2, frac = 0.42)
        -> NamedTuple

A real packed object: `n³` FCC conventional cells of equal spheres (`r = 1.5`
by default), trimmed to the sites within `a*n*frac` of the centroid 
At the defaults this is 80 atoms, ~2/3 exposed and ~1/3 buried.
"""
function packedClusterScene(;
    probe::Float64 = PROBE_RADIUS,
    r::Float64 = 1.5,
    n::Int = 4,
    a::Float64 = 2.2,
    frac::Float64 = 0.42,
)
    pts = fccLattice(n, a)
    ctr = ntuple(t -> sum(p[t] for p in pts) / length(pts), 3)
    keep = [p for p in pts if sqrt(sum((p[t] - ctr[t])^2 for t in 1:3)) ≤ a * n * frac]
    src = HydroRadii(Dict("a" => r))
    mol = radiiMol("packed cluster", fill("A", length(keep)), keep, src)
    return (; mol, probe, title = "Packed cluster ($(length(keep)) spheres, FCC)")
end

# --------------------------------------------------------------------------
# pure geometry: plastic sample points, no plotting
# --------------------------------------------------------------------------

const EXPOSED_COLOUR  = RGBf(1.00, 0.62, 0.13)   # warm/bright
const OCCLUDED_COLOUR = RGBf(0.24, 0.26, 0.32)   # dark/desaturated
const DUMMY_COLOUR    = RGBf(0.90, 0.15, 0.55)   # distinct from atoms and points
const CONCAVE_COLOUR  = RGBf(0.20, 0.55, 0.90)
const CAVITY_COLOUR   = RGBf(0.35, 0.80, 0.35)
const ATOM_COLOUR     = RGBf(0.55, 0.62, 0.75)

"""
    atomSamplePoints(mol, i, n, probe) -> NamedTuple

The `n` plastic-sequence directions mapped onto atom `i`'s expanded sphere
(radius `radii(mol)[i] + probe`), each tested with `blocked` against
every other atom.

# Returns
`(; pts, exposed)`: the `n` sample points and which of them are solvent
accessible.
"""
function atomSamplePoints(mol::Molecule, i::Int, n::Int, probe::Float64)
    crds = MolecularStructure.coordsCartesian(mol)
    rads = MolecularStructure.radii(mol)
    cands = collect(1:size(crds, 2))

    ρ = rads[i] + probe
    cx = crds[1, i]
    cy = crds[2, i]
    cz = crds[3, i]
    dirs = plasticPoints(n)

    pts = Vector{NTuple{3,Float64}}(undef, n)
    exposed = Vector{Bool}(undef, n)
    @inbounds for j in 1:n
        ux, uy, uz = dirs[j]
        p = (cx + ρ * ux, cy + ρ * uy, cz + ρ * uz)
        pts[j] = p
        exposed[j] = !blocked(p, cands, crds, rads, probe, i)
    end
    return (; pts, exposed)
end

"""
    atomAccessibility(mol, probe; n = 1024) -> NamedTuple

Per-atom accessible area (Å²) and exposed flag, by sampling each atom's expanded
sphere at `n` plastic-sequence directions ([`atomSamplePoints`](@ref)): area =
4π(r+probe)² × exposed fraction, exposed = at least one accessible point.
"""
function atomAccessibility(mol::Molecule, probe::Float64; n::Int = 1024)
    rads = MolecularStructure.radii(mol)
    na = length(rads)
    area = Vector{Float64}(undef, na)
    for i in 1:na
        frac = count(atomSamplePoints(mol, i, n, probe).exposed) / n
        area[i] = 4π * (rads[i] + probe)^2 * frac
    end
    return (; area, exposed = area .> 0)
end

# --------------------------------------------------------------------------
# headless report
# --------------------------------------------------------------------------

"""
    sasaHydroReport(; probe = PROBE_RADIUS, nTarget = nothing) -> Nothing

Print the hydration-shell dummy cloud on [`packedClusterScene`](@ref): buried
vs exposed atoms, and how the cloud behaves as the global budget varies. The
area column should stay flat Budgets shown bracket CRYSOL's `--fb` range (`F(10) = 55` to
`F(18) = 2584`, default `F(17) = 1597`).
"""
function sasaHydroReport(;
    probe::Float64 = PROBE_RADIUS,
    nTarget::Union{Nothing,Int} = nothing,
)
    sc = packedClusterScene(; probe)
    (; area, exposed) = atomAccessibility(sc.mol, probe)
    println(sc.title, "  (probe = ", probe, ")")
    @printf("  %d atoms: %d exposed, %d buried\n",
        length(area), count(exposed), count(!, exposed))
    @printf("  total SASA %.3f A^2\n\n", sum(area))

    @printf("  %-10s %-9s %-14s %-8s %-8s %-8s\n",
        "nTarget", "dummies", "shell area A^2", "convex", "concave", "cavity")
    for n in (55, 233, 610, 1597, 2584)
        pts, pa, cl = Geometry.sasa(sc.mol; probe, nTarget = n)
        @printf("  %-10d %-9d %-14.3f %-8d %-8d %-8d\n", n, size(pts, 2), sum(pa),
            count(==(Geometry.CONVEX), cl), count(==(Geometry.CONCAVE), cl),
            count(==(Geometry.CAVITY), cl))
    end

    pts, pa, _ = Geometry.sasa(sc.mol; probe, nTarget)
    @printf("\n  auto budget: %d dummies, %.4f A^2 each\n",
        size(pts, 2), isempty(pa) ? 0.0 : first(pa))
    return nothing
end

# --------------------------------------------------------------------------
# plotting
# --------------------------------------------------------------------------

"""
    sasaHydroFigure(; nTarget = nothing, nShow = 400, probe = PROBE_RADIUS) -> Figure

The hydration-shell dummy cloud on a real packed object
([`packedClusterScene`](@ref), ~80 atoms): every accessible sample point from
`Geometry.sasa` is drawn as one dummy, so the shell reads as a layer
coating the cluster's outside with its buried core visibly left uncoated.

Raw sample points for one exposed and one buried atom are overlaid in the
exposed/occluded colours, so the cloud can be seen coming *from* the occlusion
test rather than being asserted alongside it.

Split out from [`visSasaHydro`](@ref) so the plot can be assembled, saved
or inspected without a window.
"""
function sasaHydroFigure(;
    nTarget::Union{Nothing,Int} = nothing,
    nShow::Int = 400,
    probe::Float64 = PROBE_RADIUS,
)
    sc = packedClusterScene(; probe)
    crds = MolecularStructure.coordsCartesian(sc.mol)
    rads = MolecularStructure.radii(sc.mol)
    natoms = size(crds, 2)
    (; area, exposed) = atomAccessibility(sc.mol, probe)
    shell, shellArea, shellCls = Geometry.sasa(sc.mol; probe, nTarget)

    expIdx = findall(exposed)
    burIdx = findall(!, exposed)
    iExposed = expIdx[argmax(area[expIdx])]                        # most-exposed atom
    highlight = isempty(burIdx) ? (iExposed,) : (iExposed, first(burIdx))

    fig = Figure(size = (1000, 900))
    ax = Axis3(
        fig[1, 1];
        title = @sprintf(
            "%s: hydration-shell dummy cloud\n%d dummies (%d convex, \
                %d concave, %d cavity) over %d exposed atoms, %d buried",
            sc.title, size(shell, 2),
            count(==(Geometry.CONVEX), shellCls),
            count(==(Geometry.CONCAVE), shellCls),
            count(==(Geometry.CAVITY), shellCls), length(expIdx), length(burIdx)),
        titlesize = 15, aspect = :data, azimuth = 1.1π,
        xlabel = "x", ylabel = "y", zlabel = "z")

    # atom spheres: small, uniform, low-alpha.
    for i in 1:natoms
        ρ = Float32(rads[i] + probe)
        c = Point3f(crds[1, i], crds[2, i], crds[3, i])
        mesh!(ax, Sphere(c, ρ); color = (ATOM_COLOUR, i in highlight ? 0.35 : 0.10),
            transparency = true, shading = NoShading)
    end

    # the shell itself: one marker per accessible point, i.e. one per dummy
    # `Scattering.hydration` will place. Every point of a given atom carries the
    # same area, so a uniform marker size is the honest rendering.
    beadColour = Dict(Geometry.CONVEX => DUMMY_COLOUR, Geometry.CONCAVE => CONCAVE_COLOUR,
        Geometry.CAVITY => CAVITY_COLOUR)
    scatter!(ax, [Point3f(shell[1, k], shell[2, k], shell[3, k]) for k in axes(shell, 2)];
        color = [beadColour[c] for c in shellCls], markersize = 5)

    # raw sample points, only on the two highlighted atoms
    for i in highlight
        st = atomSamplePoints(sc.mol, i, nShow, probe)
        ex = [Point3f(p...) for (p, e) in zip(st.pts, st.exposed) if e]
        oc = [Point3f(p...) for (p, e) in zip(st.pts, st.exposed) if !e]
        isempty(oc) || scatter!(ax, oc; color = OCCLUDED_COLOUR, markersize = 5)
        isempty(ex) || scatter!(ax, ex; color = EXPOSED_COLOUR, markersize = 5)
    end

    els = [MarkerElement(color = ATOM_COLOUR, marker = :circle, markersize = 14),
        MarkerElement(color = DUMMY_COLOUR, marker = :circle, markersize = 10),
        MarkerElement(color = CONCAVE_COLOUR, marker = :circle, markersize = 10),
        MarkerElement(color = CAVITY_COLOUR, marker = :circle, markersize = 10),
        MarkerElement(color = EXPOSED_COLOUR, marker = :circle, markersize = 10),
        MarkerElement(color = OCCLUDED_COLOUR, marker = :circle, markersize = 10)]
    Legend(fig[2, 1], els,
        ["atom (expanded radius)",
            @sprintf("bead: convex (%.3f A^2 each)",
                isempty(shellArea) ? 0.0 : first(shellArea)),
            "bead: concave", "bead: cavity",
            "sample point: exposed (highlighted atoms only)",
            "sample point: occluded (highlighted atoms only)"];
        orientation = :horizontal, framevisible = false, nbanks = 2, labelsize = 12)
    return fig
end

"""
    visSasaHydro(; nTarget = nothing, nShow = 400, probe = PROBE_RADIUS) -> Nothing

Display [`sasaHydroFigure`](@ref): the whole hydration-shell dummy cloud on a
real ~80-atom packed cluster, plus the raw sample points on one buried and one
exposed atom to show the underlying mechanism. Blocks until the window is
closed.

# Keywords
-   `nTarget`: global dummy budget; `nothing` derives it from accessible area.
                CRYSOL's `--fb` analogue, and what `Scattering.hydration` pays for.
-   `nShow`:   sample points drawn for the two highlighted atoms only.
-   `probe`:    solvent probe radius.
"""
visSasaHydro(;
    nTarget::Union{Nothing,Int} = nothing,
    nShow::Int = 400,
    probe::Float64 = PROBE_RADIUS,
) =
    wait(display(sasaHydroFigure(; nTarget, nShow, probe)))
