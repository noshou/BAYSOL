# SPDX-License-Identifier: LGPL-2.1-or-later

# Shared point-cloud geometry for tests that need a real 3D atom arrangement
# rather than a hand-picked handful of coordinates.

"""
Element letter -> radius (Å) for synthetic SASA geometries. Deliberately not real
elements: these are shapes.
"""
const SASA_RADII = Dict(
    "q" => 1.5,   # workhorse
    "a" => 1.0,
    "b" => 2.0,
    "c" => 0.5,   # tiny
    "d" => 5.0,   # huge
    "m" => 3.48,  # largest radius on file (Cs/Fr van der Waals)
)

"""
    sph(R, n) -> Vector{NTuple{3,Float64}}

`n` points on a sphere of radius `R`, via the Fibonacci/golden-angle spiral
(near-uniform coverage, no clustering at the poles). Used to build a sealed
shell of atoms around an enclosed void.

# Arguments
- `R`: sphere radius.
- `n`: point count.
"""
sph(R, n) = [(R * sqrt(1 - z^2) * cos(t), R * sqrt(1 - z^2) * sin(t), R * z)
            for (z, t) in ((-1 + 2(k - 0.5) / n, π * (1 + sqrt(5)) * k) for k in 1:n)]

"""
    jittered_lattice(n; a = 2.3) -> Vector{NTuple{3,Float64}}

An n×n×n cubic lattice of spacing `a` with small index-dependent offsets, so no
distance or direction is exactly degenerate: a dense, protein-like packing with a buried
interior, exposed faces, and partly cut edges. Spans [0, a·(n-1)] (plus the offsets) in
each axis; its top layer sits near z = a·(n-1).
"""
jittered_lattice(n; a = 2.3) =
    vec([(a * i + 0.1j, a * j + 0.05k, a * k + 0.07i) for i in 0:n-1, j in 0:n-1, k in 0:n-1])

"""
    witness_lattice() -> Vector{NTuple{3,Float64}}

A 5×5×5 [`jittered_lattice`](@ref) plus one isolated atom 30 Å away, so a SASA run over
it has buried, partly exposed, and fully exposed atoms (the lattice alone has none of the
last kind: even its corners are partly covered).
"""
witness_lattice() = [jittered_lattice(5); (30.0, 30.0, 30.0)]

"""
Large atoms placed at the surface by [`surface_atom_cases`](@ref): pseudo-element and
radius (Å). 3.48 Å is the largest radius the bundled radius table returns (Cs/Fr van der
Waals), 5.0 Å goes beyond anything on file.
"""
const SURFACE_ATOM_RADII = (("b", 2.0), ("m", 3.48), ("d", 5.0))

"""
    surface_atom_cases(; n = 6, a = 2.3, r_lattice = 1.5, probe = 1.4, steps = 24)
        -> Vector{NamedTuple}

One large atom on the top face of a [`jittered_lattice`](@ref) of `r_lattice` atoms, per
case, for gauging what SASA's witness pass loses. For each radius in
[`SURFACE_ATOM_RADII`](@ref) its centre height h (above the top layer) is swept over
`steps` values around the depth where its expanded sphere first emerges from the
lattice's accessible surface (h_e ≈ max lattice z + r_lattice + probe − (r + probe),
relative to the top layer), from 0.3 Å below to 0.6 Å above: exposure goes from none,
through a sliver of the sphere (the regime where an exposed atom can bail), to a few
percent. Four lateral offsets vary where the sliver falls relative to the sample
directions.

# Returns
- `Vector` of `(label, elms, crds, r, h)`: the lattice atoms are `"q"`, the large atom is
    last.
"""
function surface_atom_cases(; n = 6, a = 2.3, r_lattice = 1.5, probe = 1.4, steps = 24)
    base = jittered_lattice(n; a = a)
    top = a * (n - 1)
    sas_top = maximum(c[3] for c in base) + r_lattice + probe
    cases = NamedTuple[]
    for (e, r) in SURFACE_ATOM_RADII
        h_e = sas_top - top - (r + probe)
        for h in range(h_e - 0.3, h_e + 0.6, length = steps),
                (dx, dy) in ((0.31, -0.17), (1.07, 0.55), (-0.83, 0.92), (0.0, 0.0))
            crds = [base; (top / 2 + dx, top / 2 + dy, top + h)]
            elms = [fill("q", length(base)); e]
            push!(cases, (label = "r=$(r) h=$(round(h, digits = 3)) dx=$(dx) dy=$(dy)",
                          elms = elms, crds = crds, r = r, h = h))
        end
    end
    return cases
end
