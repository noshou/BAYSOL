# SPDX-License-Identifier: LGPL-2.1-or-later

include(joinpath(@__DIR__, "..", "testsetup.jl"))

using BAYSOL.SASA: SASA, sasa
using BAYSOL.SASA: SHELL_MIN_POINTS, SHELL_SAMPLE, PROBE_RADIUS, SASA_N_OCC
using BAYSOL.SASA: blocked
using BAYSOL.MolecularStructure: MolecularStructure

# ---------------------------------------------------------------------------
# Hand-picked radii.
#
# Every molecule below is built with a fixed element -> radius table instead of
# the bundled SQLite radii DB, so the geometry under test is exactly what the
# test says it is and nothing here depends on `data/atomic_radii.sqlite3`.
# `MolecularStructure._build` takes the radii thunk directly.
# ---------------------------------------------------------------------------

# element letter -> radius (Å): `SASA_RADII`, in test/utils/geometry.jl (shared
# with the static snapshots in test/visualize/xyz/, which were written from these geometries).
include(joinpath(@__DIR__, "..", "..", "utils", "geometry.jl"))   # SASA_RADII, sph, lattices

function sasa_mol(elms, crds)
    es = String[lowercase(e) for e in elms]
    return MolecularStructure._build("sasa-test", es, crds, () -> Float64[SASA_RADII[e] for e in es])
end

"Total solvent-accessible surface area of `mol`: the sum of the cloud's point areas."
sasa_total(mol; kwargs...) = sum(SASA.sasa(mol; kwargs...)[2])

"""
Relative tolerance on the analytic two-sphere-cap area. The cloud samples
`SHELL_SAMPLE` = 256 quasi-random directions per atom; the measured worst error
over the eight separations below is 0.92 %, so 3 % leaves ~3x headroom.
"""
const SASA_CAP_RTOL = 0.03

"Analytic area of a lone expanded sphere: 4π(r + probe)²."
sasa_full(r, probe) = 4π * (r + probe)^2

"""
Exposed area of one of two equal spheres of expanded radius ρ whose centres are
`d` apart (0 < d < 2ρ): the occluded part is a spherical cap of area
`2πρ(ρ - d/2)`, so the exposed part is `4πρ² - 2πρ(ρ - d/2)`.
"""
sasa_cap_exposed(ρ, d) = 4π * ρ^2 - 2π * ρ * (ρ - d / 2)

"""
Most accessible area the witness pass (`SASA_N_OCC`) may lose: the shell
sampling's own measured worst error on the analytic two-sphere cap below (0.92 %), the
budget `SASA_N_OCC` was chosen against.
"""
const SASA_WITNESS_LOSS_MAX = 0.0092


@testset "SASA" begin

    @testset "argument contract" begin
        m = sasa_mol(["q"], [(0.0, 0.0, 0.0)])
        @test_throws DomainError SASA.sasa(m; n_target = 0)
        @test_throws DomainError SASA.sasa(m; n_target = -3)
        @test_throws DomainError SASA.sasa(m; probe = -1e-9)
    end

    @testset "single isolated atom is analytically exact" begin
        # A lone atom has no other candidate, so EVERY sample direction is
        # exposed and the area is 4π(r+probe)² (to rounding), for any probe.
        for (el, r) in (("c", 0.5), ("a", 1.0), ("q", 1.5), ("d", 5.0))
            m = sasa_mol([el], [(3.0, -2.0, 7.0)])   # centring puts it at the origin
            for probe in (0.0, 1.4, 2.5)
                @test sasa_total(m; probe = probe) ≈ sasa_full(r, probe) rtol = 1e-12
            end
        end
    end

    @testset "two well-separated atoms: exact sum of two spheres" begin
        probe = 1.4
        m = sasa_mol(["a", "b"], [(0.0, 0.0, 0.0), (50.0, 0.0, 0.0)])
        @test sasa_total(m; probe = probe) ≈ sasa_full(1.0, probe) + sasa_full(2.0, probe) rtol = 1e-12

        # exactly touching-but-not-overlapping expanded spheres:
        # ρ₁ + ρ₂ = 2.4 + 3.4 = 5.8, centres 6.0 apart -> still fully exposed.
        m2 = sasa_mol(["a", "b"], [(0.0, 0.0, 0.0), (6.0, 0.0, 0.0)])
        @test sasa_total(m2; probe = probe) ≈ sasa_full(1.0, probe) + sasa_full(2.0, probe) rtol = 1e-12
    end

    @testset "complete engulfment: the inner atom contributes nothing" begin
        # r_small = 0.5, r_large = 5.0, probe = 1.0, centres 1.0 apart: the small
        # atom's whole expanded sphere is strictly inside the large one, so the
        # total is the host's full analytic area.
        probe = 1.0
        m = sasa_mol(["d", "c"], [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0)])
        @test sasa_total(m; probe = probe) ≈ sasa_full(5.0, probe) rtol = 1e-12

        # concentric variant (d = 0) with strictly different radii is the same
        # clean case: ρ_small = 2.4 < ρ_large = 3.4.
        mc = sasa_mol(["a", "b"], [(0.0, 0.0, 0.0), (0.0, 0.0, 0.0)])
        @test sasa_total(mc; probe = 1.4) ≈ sasa_full(2.0, 1.4) rtol = 1e-12
    end

    @testset "coincident identical atoms are exactly zero" begin
        # `classify` decides it before any point is generated: d = 0 and
        # ρᵢ = ρⱼ means each atom is engulfed by the other, so neither has a surface.
        m = sasa_mol(["q", "q"], [(0.0, 0.0, 0.0), (0.0, 0.0, 0.0)])
        pts, areas, _ = SASA.sasa(m; probe = 1.4)
        @test isempty(areas) && size(pts) == (3, 0)
    end

    @testset "analytic spherical cap (strongest correctness check)" begin
        # Two equal spheres, expanded radius ρ = 2.9, centres d apart with
        # 0 < d < 2ρ. The total exposed area is 2·(4πρ² - 2πρ(ρ - d/2)) exactly.
        # The cloud samples 256 quasi-random directions per atom, so the tolerance
        # is a few percent, not the 1e-4 of a 40 000-point count.
        probe = 1.4
        ρ = 1.5 + probe
        for d in (0.5, 1.0, 1.7, 2.5, 3.3, 4.2, 5.0, 5.7)
            @test 0.0 < d < 2ρ
            exact = 2 * sasa_cap_exposed(ρ, d)
            m = sasa_mol(["q", "q"], [(0.0, 0.0, 0.0), (d, 0.0, 0.0)])
            @test abs(sasa_total(m; probe = probe) - exact) < SASA_CAP_RTOL * exact
        end
    end

    @testset "determinism (quasi-random, not random)" begin
        probe = 1.4
        els, crds = ["q", "a", "b", "c"], [(0.0, 0.0, 0.0), (2.0, 0.0, 0.0), (0.0, 3.0, 0.0), (1.0, 1.0, 1.0)]
        m = sasa_mol(els, crds)
        ref = SASA.sasa(m; probe = probe)
        for _ in 1:3
            @test SASA.sasa(m; probe = probe) == ref       # bit-identical
        end
        # a freshly-built but geometrically identical molecule agrees too
        @test SASA.sasa(sasa_mol(els, crds); probe = probe) == ref
    end

    @testset "probe scaling on a lone atom is exactly (r + probe)²" begin
        m = sasa_mol(["a"], [(1.0, 2.0, 3.0)])         # r = 1.0
        v0 = sasa_total(m; probe = 0.0)
        v1 = sasa_total(m; probe = 1.5)
        v2 = sasa_total(m; probe = 4.0)
        @test v0 ≈ sasa_full(1.0, 0.0) rtol = 1e-12
        @test v1 / v0 ≈ (2.5 / 1.0)^2 rtol = 1e-12
        @test v2 / v0 ≈ (5.0 / 1.0)^2 rtol = 1e-12
    end

    @testset "blocked (point test) unit tests" begin
        # atom 1 at origin (r = 1.0), atom 2 at x = 3.0 (r = 1.0), probe = 0.5
        # -> expanded radii 1.5 each.
        crds = [0.0 3.0; 0.0 0.0; 0.0 0.0]
        rads = [1.0, 1.0]
        probe = 0.5

        # strictly inside candidate 2's expanded sphere
        @test blocked((3.2, 0.0, 0.0), [1, 2], crds, rads, probe, 1)
        @test blocked((3.0, 0.4, -0.3), [2], crds, rads, probe, 1)

        # strictly outside every candidate's expanded sphere
        @test !blocked((10.0, 0.0, 0.0), [1, 2], crds, rads, probe, 1)
        @test !blocked((1.5 + 1e-9, 0.0, 0.0), [1, 2], crds, rads, probe, 2)

        # `self` is skipped even for a point ON self's own expanded sphere ...
        @test !blocked((1.5, 0.0, 0.0), [1], crds, rads, probe, 1)
        @test !blocked((0.0, 0.0, 1.5), [1], crds, rads, probe, 1)
        # ... and even for a point deep INSIDE self (self's own centre)
        @test !blocked((0.0, 0.0, 0.0), [1], crds, rads, probe, 1)
        @test !blocked((0.0, 0.0, 0.0), [1, 2], crds, rads, probe, 1)
        # the same point IS occluded once atom 1 is not `self`
        @test blocked((0.0, 0.0, 0.0), [1, 2], crds, rads, probe, 2)

        # degenerate candidate lists
        @test !blocked((0.0, 0.0, 0.0), Int[], crds, rads, probe, 1)
        @test !blocked((3.0, 0.0, 0.0), Int[], crds, rads, probe, 1)   # inside 2, but not a candidate
        @test !blocked((3.0, 0.0, 0.0), [2], crds, rads, probe, 2)     # only self

        # boundary: `dst² ≤ ρ_c²` is inclusive, so exactly on the surface counts
        @test blocked((1.5, 0.0, 0.0), [1], crds, rads, probe, 2)

        # probe widens the occluding sphere
        @test !blocked((2.0, 0.0, 0.0), [1], crds, rads, 0.5, 2)   # ρ = 1.5 < 2.0
        @test blocked((2.0, 0.0, 0.0), [1], crds, rads, 1.5, 2)    # ρ = 2.5 > 2.0

        @test blocked((3.2, 0.0, 0.0), [1, 2], crds, rads, probe, 1) isa Bool
    end

    @testset "sasa: the accessible surface as a point cloud" begin
        # A lone atom is ALL_EXPOSED, so every sampled direction survives and
        # each stands for an exact 1/n_pts of the analytic sphere.
        probe = 1.4
        r = 1.5
        ρ = r + probe
        # a lone atom is ALL_EXPOSED; its area is small enough that the derived
        # budget floors at SHELL_MIN_POINTS, and every bead carries an equal share
        m = sasa_mol(["q"], [(3.0, -2.0, 7.0)])
        pts, pa, cls = SASA.sasa(m; probe = probe)

        @test size(pts) == (3, SHELL_MIN_POINTS)
        @test length(pa) == SHELL_MIN_POINTS
        @test all(a -> a ≈ 4π * ρ^2 / SHELL_MIN_POINTS, pa)
        @test sum(pa) ≈ sasa_full(r, probe)
        @test all(==(SASA.CONVEX), cls)      # a lone sphere is convex everywhere

        # an explicit budget overrides the derived one
        pe, _, _ = SASA.sasa(m; probe = probe, n_target = 200)
        @test size(pe, 2) == 200

        # every point sits on the expanded sphere, in the molecule's own centred frame .
        atom = MolecularStructure.coords_cartesian(m)[:, 1]
        for k in axes(pts, 2)
            @test isapprox(sqrt(sum(abs2, pts[:, k] .- atom)), ρ; atol = 1e-1 * DEFAULT_ATOL)
        end

        # A fully engulfed atom contributes no points at all: the cloud is the
        # accessible surface, and it has none.
        mc = sasa_mol(["a", "b"], [(0.0, 0.0, 0.0), (0.0, 0.0, 0.0)])
        pc, ac, _ = SASA.sasa(mc; probe = probe)
        # both atoms are coincident; the larger engulfs the smaller, so at most
        # one atom's worth of points can survive
        @test size(pc, 2) == length(ac)
        @test size(pc, 2) ≤ SHELL_SAMPLE

        # Total cloud area tracks the analytic exposed area of two overlapping
        # equal spheres (radius 1.5 + probe, centres 2.0 apart).
        m2 = sasa_mol(["q", "q"], [(0.0, 0.0, 0.0), (2.0, 0.0, 0.0)])
        _, pa2, _ = SASA.sasa(m2; probe = probe)
        @test isapprox(sum(pa2), 2 * sasa_cap_exposed(1.5 + probe, 2.0); rtol = 1e-2)

        # the budget caps the cloud and preserves the area it represents
        for n in (16, 64, 256)
            pn, an, _ = SASA.sasa(m2; probe = probe, n_target = n)
            @test size(pn, 2) ≤ n
            @test isapprox(sum(an), sum(pa2); rtol = 5e-2)
        end

        @test_throws DomainError SASA.sasa(m2; n_target = 0)
        @test_throws DomainError SASA.sasa(m2; n_target = -3)
        @test_throws DomainError SASA.sasa(m2; probe = -1e-9)

        # a sealed void inside a dense shell is CAVITY throughout, while the
        # same construction with no void has none; detection holds while the
        # void fits inside the ray range and degrades to open surface past it.
        # (`sph` comes from test/utils/geometry.jl, included at the top.)
        for R in (4.0, 5.0, 6.0)
            hp, _, hc = SASA.sasa(
                sasa_mol(fill("q", 300), sph(R, 300)); probe = probe)
            inner = [k for k in axes(hp, 2) if sqrt(sum(abs2, hp[:, k])) < R]
            @test !isempty(inner)
            @test all(k -> hc[k] == SASA.CAVITY, inner)
        end
    end

    @testset "_sasa_loop: vectorized cap test and witness pass" begin
        # dense 5×5×5 lattice (buried interior, partly exposed faces and edges) plus one
        # isolated, fully exposed atom
        probe = 1.4
        crds = witness_lattice()
        m = sasa_mol(fill("q", length(crds)), crds)
        xyz = MolecularStructure.coords_cartesian(m); rads = MolecularStructure.radii(m)
        rmax = MolecularStructure.r_max(m); tree = MolecularStructure.neighbour_tree(m)
        pmap = BAYSOL.PlasticSequence.plastic_points(SHELL_SAMPLE)

        # reference: every direction through the per-point `blocked` test
        ref_counts = map(axes(xyz, 2)) do i
            ρ = rads[i] + probe
            cand = SASA.inrange(tree, xyz[:, i], ρ + rmax + probe)
            count(u -> !blocked((xyz[1, i] + ρ * u[1], xyz[2, i] + ρ * u[2], xyz[3, i] + ρ * u[3]),
                                cand, xyz, rads, probe, i), pmap)
        end
        @test any(==(0), ref_counts) && any(==(SHELL_SAMPLE), ref_counts) &&
              any(c -> 0 < c < SHELL_SAMPLE, ref_counts)

        # witness pass off (n_occ = n_pts): exactly the reference
        _, _, _, c0 = SASA._sasa_loop(tree, xyz, rads, rmax, pmap, probe, SHELL_SAMPLE, SHELL_SAMPLE)
        @test c0 == ref_counts

        # witness pass on: an atom bails iff none of its first SASA_N_OCC directions is
        # open, and every other atom is unchanged
        _, _, _, c1 = SASA._sasa_loop(tree, xyz, rads, rmax, pmap, probe, SHELL_SAMPLE, SASA_N_OCC)
        for i in axes(xyz, 2)
            ρ = rads[i] + probe
            cand = SASA.inrange(tree, xyz[:, i], ρ + rmax + probe)
            open_prefix = any(u -> !blocked((xyz[1, i] + ρ * u[1], xyz[2, i] + ρ * u[2], xyz[3, i] + ρ * u[3]),
                                            cand, xyz, rads, probe, i), pmap[1:SASA_N_OCC])
            @test c1[i] == (open_prefix ? ref_counts[i] : 0)
        end
    end

    @testset "witness pass: large atoms at the surface (gauge of lost area)" begin
        # One large atom (r = 2.0, 3.48 = largest on file, 5.0) on the face of a dense
        # lattice, swept through the depths where only a sliver of it is exposed: the
        # regime where an exposed atom can have no open point among its first
        # SASA_N_OCC directions and bail. Compares every case against the pass turned
        # off (n_occ = n_pts) and logs the lost area. (`surface_atom_cases`,
        # `jittered_lattice` come from test/utils/geometry.jl.)
        probe = 1.4
        pmap = BAYSOL.PlasticSequence.plastic_points(SHELL_SAMPLE)
        area = Dict(r => [0.0, 0.0] for (_, r) in SURFACE_ATOM_RADII)    # large atom's area, pass off / on
        cnt  = Dict(r => [0, 0, 0] for (_, r) in SURFACE_ATOM_RADII)      # exposed, sliver (≤ 5 %), bailed cases
        tot_off = 0.0; tot_on = 0.0
        for c in surface_atom_cases(; probe = probe)
            m = sasa_mol(c.elms, c.crds)
            xyz = MolecularStructure.coords_cartesian(m); rads = MolecularStructure.radii(m)
            rmax = MolecularStructure.r_max(m); tree = MolecularStructure.neighbour_tree(m)
            _, _, _, c_off = SASA._sasa_loop(tree, xyz, rads, rmax, pmap, probe, SHELL_SAMPLE, SHELL_SAMPLE)
            _, _, _, c_on  = SASA._sasa_loop(tree, xyz, rads, rmax, pmap, probe, SHELL_SAMPLE, SASA_N_OCC)
            w = [4π * (r + probe)^2 / SHELL_SAMPLE for r in rads]

            # the pass only ever drops a whole atom, and only one whose true exposure is
            # within the rule-of-three bound of SASA_N_OCC
            @test all(i -> c_on[i] == c_off[i] || c_on[i] == 0, eachindex(c_on))
            @test all(i -> c_on[i] == c_off[i] || c_off[i] / SHELL_SAMPLE ≤ 3 / SASA_N_OCC, eachindex(c_on))

            tot_off += sum(c_off .* w); tot_on += sum(c_on .* w)
            a = area[c.r]; n = cnt[c.r]
            a[1] += c_off[end] * w[end]; a[2] += c_on[end] * w[end]
            c_off[end] > 0 && (n[1] += 1)
            0 < c_off[end] ≤ 0.05 * SHELL_SAMPLE && (n[2] += 1)
            c_off[end] > 0 && c_on[end] == 0 && (n[3] += 1)
        end
        for (_, r) in SURFACE_ATOM_RADII
            a = area[r]; n = cnt[r]
            @test n[2] > 0                           # the sweep reaches the sliver regime
            loss = 1 - a[2] / a[1]
            @test loss ≤ SASA_WITNESS_LOSS_MAX
            @info "witness pass, large surface atom r = $(r) Å: exposed in $(n[1]) cases " *
                  "($(n[2]) sliver ≤ 5 %), $(n[3]) bailed; its area $(round(a[1]; digits = 1)) → " *
                  "$(round(a[2]; digits = 1)) Å² (lost $(round(100loss; digits = 2)) %)"
        end
        @test 1 - tot_on / tot_off ≤ SASA_WITNESS_LOSS_MAX
        @info "witness pass, all surface-atom cases: $(round(tot_off; digits = 1)) → " *
              "$(round(tot_on; digits = 1)) Å² (lost $(round(100(1 - tot_on / tot_off); digits = 3)) %; " *
              "budget $(round(100SASA_WITNESS_LOSS_MAX; digits = 2)) %)"
    end

    @testset "SASA draws from the hoisted PlasticSequence module" begin
        # SASA's sampling is the plastic sequence, now hoisted out into its own
        # domain-agnostic module; its own behaviour is covered in
        # test_plasticmap.jl, this just confirms the dependency is reachable
        # and functional from here.
        @test length(BAYSOL.PlasticSequence.plastic_points(8)) == 8
    end
end
