# SPDX-License-Identifier: LGPL-2.1-or-later

# Visual check for `Electrostatics.nucleic_acid_cavity_electrostatics` and
# `Electrostatics.protein_cavity_electrostatics`: a sealed cavity around one
# or more charge sites, coloured by bead class (convex/concave/cavity) and
# by the continuous screened-field signal each CAVITY bead actually carries.
#
# Run with:
#   julia --project=test/visualize -e 'include("test/visualize/electrostatics_vis.jl"); vis_electrostatics_na()'
#   julia --project=test/visualize -e 'include("test/visualize/electrostatics_vis.jl"); vis_electrostatics_protein()'
#
# Numbers only, no window (works headless):
#   julia --project=test/visualize -e 'include("test/visualize/electrostatics_vis.jl"); electrostatics_report()'

using BayeSol
using BayeSol.Interfaces: Interfaces, RadiiSource
using BayeSol.MolecularStructure: MolecularStructure, Molecule
using BayeSol.Solvation.SASA: SASA
using BayeSol.Solvation.Electrostatics: Electrostatics, nucleic_acid_cavity_electrostatics, protein_cavity_electrostatics
using BayeSol.MolecularStructure: Residues 
using Printf: @printf, @sprintf
using GLMakie

# --------------------------------------------------------------------------
# radii source
# --------------------------------------------------------------------------

"Fixed per-element radii, so scene geometry is exact and reproducible."
struct ElecVisRadii <: RadiiSource
    table::Dict{String,Float64}
end

function Interfaces.lookup(src::ElecVisRadii, ions)
    out = Vector{Tuple{String,Union{Float64,Nothing}}}(undef, length(ions))
    for (i, ion) in enumerate(ions)
        s = String(ion)
        out[i] = (s, get(src.table, s, nothing))
    end
    return out
end

const ELEC_VIS_SRC = ElecVisRadii(Dict("c" => 1.7, "o" => 1.5, "p" => 1.9, "n" => 1.6))

# --------------------------------------------------------------------------
# scenes: a sealed shell (stands in for a folded backbone) around one or
# more charge sites sitting in the enclosed cavity. Shell radius/density
# match test_electrostatics.jl's empirically-chosen values that reliably
# produce a healthy CAVITY-bead population.
# --------------------------------------------------------------------------

"Points on a sphere of radius `r`, `n` of them, Fibonacci/golden-angle spiral."
_sphere_points(r::Float64, n::Int) =
    [(r * sqrt(1 - z^2) * cos(t), r * sqrt(1 - z^2) * sin(t), r * z)
     for (z, t) in ((-1 + 2(k - 0.5) / n, π * (1 + sqrt(5)) * k) for k in 1:n)]

"""
    nucleic_acid_cavity_scene(; probe = 1.4, shell_r = 8.0, n_shell = 800) -> NamedTuple

A sealed carbon shell enclosing one backbone phosphate group (`p` + 2 `o`),
the same fixture shape `test_electrostatics.jl` uses to guarantee a
populated `CAVITY` region.
"""
function nucleic_acid_cavity_scene(; probe::Float64 = 1.4, shell_r::Float64 = 8.0, n_shell::Int = 800)
    shell_elms = fill("c", n_shell)
    shell_crds = _sphere_points(shell_r, n_shell)
    ion_elms = ["p", "o", "o"]
    ion_crds = [(0.0, 0.0, 0.0), (1.5, 0.0, 0.0), (-1.5, 0.0, 0.0)]

    mol = MolecularStructure.create("nucleic-acid cavity", vcat(shell_elms, ion_elms), vcat(shell_crds, ion_crds);
                            radii_source = ELEC_VIS_SRC)
    sites = Electrostatics._phosphate_charge_sites(mol)
    return (; mol, probe, sites, title = "Nucleic-acid cavity with one phosphate group")
end

"""
    protein_cavity_scene(; probe = 1.4, shell_r = 8.0, n_shell = 800) -> NamedTuple

A sealed backbone-like carbon shell enclosing an Asp carboxylate and a Lys
amine, resolved through `Interfaces.ResidueNetCharge.
"""
function protein_cavity_scene(; probe::Float64 = 1.4, shell_r::Float64 = 8.0, n_shell::Int = 800)
    shell_elms = fill("c", n_shell)
    shell_crds = _sphere_points(shell_r, n_shell)
    ion_elms = ["o", "o", "n"]
    ion_crds = [(0.0, 0.0, 0.0), (1.5, 0.0, 0.0), (-2.0, 0.0, 0.0)]

    mol = MolecularStructure.create("protein cavity", vcat(shell_elms, ion_elms), vcat(shell_crds, ion_crds);
                            radii_source = ELEC_VIS_SRC)
    residues = Residues(
        vcat(fill("GLY", n_shell), ["ASP", "ASP", "LYS"]),
        vcat(fill("CA", n_shell), ["OD1", "OD2", "NZ"]),
    )
    sites = Electrostatics._protein_charge_sites(mol, residues)
    return (; mol, probe, sites, residues, title = "Protein cavity: one Asp carboxylate + one Lys amine")
end

# --------------------------------------------------------------------------
# per-bead field values (recomputes `_aggregate`'s inner loop; the module
# itself only returns the reduced (μ_χ, σ_χ), which is the right public
# contract but throws away exactly the per-bead detail a plot needs)
# --------------------------------------------------------------------------

"""
    bead_field_values(mol, pts, sel, sites; kwargs...) -> Vector{Float64}

The screened-field sum at each bead in `sel`, one value per bead.
"""
function bead_field_values(
    mol::Molecule, pts::Matrix{Float64}, sel::Vector{Int}, sites::Vector{Tuple{Int,Float64}};
    ionic_strength_M::Float64 = 0.15, eps_r::Float64 = 80.0, T::Float64 = 300.0,
    cutoff_debye_lengths::Float64 = 5.0,
)
    crds = MolecularStructure.coords_cartesian(mol)
    κinv = Electrostatics.debye_length(; ionic_strength_M, eps_r, T)
    cutoff = cutoff_debye_lengths * κinv

    vals = Vector{Float64}(undef, length(sel))
    for (k, i) in enumerate(sel)
        bx, by, bz = pts[1, i], pts[2, i], pts[3, i]
        total = 0.0
        for (o, q) in sites
            r = sqrt((bx - crds[1, o])^2 + (by - crds[2, o])^2 + (bz - crds[3, o])^2)
            (r == 0.0 || r > cutoff) && continue
            total += Electrostatics._screened_field(q, r, κinv, eps_r)
        end
        vals[k] = total
    end
    return vals
end

# --------------------------------------------------------------------------
# headless report
# --------------------------------------------------------------------------

"""
    electrostatics_report(; probe = 1.4) -> Nothing

Print `(μ_χ, σ_χ)` for both scenes, plus the per-bead field range over the
`CAVITY` population, so the signal can be sanity-checked without a window.
"""
function electrostatics_report(; probe::Float64 = 1.4)
    na = nucleic_acid_cavity_scene(; probe)
    prot = protein_cavity_scene(; probe)

    for (name, sc, μ_σ) in (
        ("Nucleic acid", na, nucleic_acid_cavity_electrostatics(na.mol; probe)),
        ("Protein", prot, protein_cavity_electrostatics(prot.mol, prot.residues; probe)),
    )
        println("== $name cavity ==")
        pts, _, class = SASA.shell_points(sc.mol; probe)
        sel = findall(==(SASA.CAVITY), class)
        vals = bead_field_values(sc.mol, pts, sel, sc.sites)
        μ, σ = μ_σ
        @printf("  %d charge site(s), %d CAVITY beads\n", length(sc.sites), length(sel))
        @printf("  μ_χ = %.4f MV/cm, σ_χ = %.4f MV/cm  (from the real δρ_prior entry point)\n", μ, σ)
        isempty(vals) || @printf("  per-bead range: [%.4f, %.4f] MV/cm\n", minimum(vals), maximum(vals))
        println()
    end
    return nothing
end

# --------------------------------------------------------------------------
# plotting
# --------------------------------------------------------------------------

const CONVEX_COLOR  = RGBf(1.00, 0.62, 0.13)
const CONCAVE_COLOR = RGBf(0.20, 0.55, 0.90)
const CAVITY_COLOR  = RGBf(0.35, 0.80, 0.35)
const ATOM_COLOR    = RGBf(0.55, 0.62, 0.75)
const SITE_COLOR    = RGBf(0.90, 0.15, 0.55)

"""
    electrostatics_figure(scene) -> Figure

Two panels sharing one scene, both drawn over the translucent enclosing
shell (so the cavity's geometric context stays visible, not just the bead
cloud floating in empty axes):

- left: the plain `SASA.shell_points` bead classification (convex/concave cavity).
- right: the same `CAVITY` beads only, coloured by their continuous
screened-field value ([`bead_field_values`](@ref)) on a sequential
colormap with a labelled colorbar.

Both panels mark every charge site (the actual phosphate/ionizable atoms
driving the field) with the same large magenta marker.
"""
function electrostatics_figure(scene)
    mol, probe, sites, title = scene.mol, scene.probe, scene.sites, scene.title
    crds = MolecularStructure.coords_cartesian(mol)
    pts, _, class = SASA.shell_points(mol; probe)
    sel = findall(==(SASA.CAVITY), class)
    vals = bead_field_values(mol, pts, sel, sites)
    site_idx = Set(first.(sites))

    fig = Figure(size = (1500, 850))

    function draw_shell!(ax)
        shell_idx = [i for i in axes(crds, 2) if i ∉ site_idx]
        scatter!(ax, [Point3f(crds[1, i], crds[2, i], crds[3, i]) for i in shell_idx];
                color = ATOM_COLOR, markersize = 4)
        for (o, _) in sites
            scatter!(ax, [Point3f(crds[1, o], crds[2, o], crds[3, o])]; color = SITE_COLOR, markersize = 22)
        end
    end

    ax1 = Axis3(
        fig[1, 1];
        title = @sprintf(
            "Bead classification\n%d beads total: %d convex, %d concave, %d cavity",
            size(pts, 2), count(==(SASA.CONVEX), class), count(==(SASA.CONCAVE), class), length(sel)),
        titlesize = 14, aspect = :data, azimuth = 1.1π,
        xlabel = "x (Å)", ylabel = "y (Å)", zlabel = "z (Å)")
    draw_shell!(ax1)
    class_colour = Dict(SASA.CONVEX => CONVEX_COLOR, SASA.CONCAVE => CONCAVE_COLOR, SASA.CAVITY => CAVITY_COLOR)
    scatter!(ax1, [Point3f(pts[1, k], pts[2, k], pts[3, k]) for k in axes(pts, 2)];
            color = [class_colour[c] for c in class], markersize = 6)

    ax2 = Axis3(
        fig[1, 2];
        title = @sprintf("Screened-field over CAVITY beads and \n%d charge site(s)", length(sites)),
        titlesize = 14, aspect = :data, azimuth = 1.1π,
        xlabel = "x (Å)", ylabel = "y (Å)", zlabel = "z (Å)")
    draw_shell!(ax2)
    if isempty(vals)
        text!(ax2, "no CAVITY beads at this shell density/radius"; position = Point3f(0, 0, 0), align = (:center, :center))
    else
        cmap = cgrad(:viridis)
        vmin, vmax = minimum(vals), maximum(vals)
        colors = vmax > vmin ? [cmap[(v - vmin) / (vmax - vmin)] for v in vals] : fill(cmap[0.5], length(vals))
        scatter!(ax2, [Point3f(pts[1, k], pts[2, k], pts[3, k]) for k in sel]; color = colors, markersize = 10)
        Colorbar(fig[1, 3]; limits = (vmin, vmax), colormap = cmap,
                label = "Debye-Hückel field χ (MV/cm)")
    end

    els = [
        MarkerElement(color = ATOM_COLOR, marker = :circle, markersize = 8),
        MarkerElement(color = SITE_COLOR, marker = :circle, markersize = 14),
        MarkerElement(color = CONVEX_COLOR, marker = :circle, markersize = 10),
        MarkerElement(color = CONCAVE_COLOR, marker = :circle, markersize = 10),
        MarkerElement(color = CAVITY_COLOR, marker = :circle, markersize = 10),
    ]
    Legend(fig[2, 1:3], els,
            ["enclosing shell atom",
            "charge site (phosphate O, or Asp/Lys ionizable atom)",
            "bead: convex (open solvent)", "bead: concave",
            "bead: cavity"];
            orientation = :horizontal, framevisible = false, nbanks = 2, labelsize = 12)

    Label(fig[0, 1:3], title; fontsize = 16)
    return fig
end

"Display the nucleic-acid cavity scene. Blocks until the window is closed."
vis_electrostatics_na(; probe::Float64 = 1.4) =
    wait(display(electrostatics_figure(nucleic_acid_cavity_scene(; probe))))

"Display the protein cavity scene. Blocks until the window is closed."
vis_electrostatics_protein(; probe::Float64 = 1.4) =
    wait(display(electrostatics_figure(protein_cavity_scene(; probe))))
