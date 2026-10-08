# SPDX-License-Identifier: LGPL-2.1-or-later

# Shared baseline so every units/test_*.jl can run standalone
# (`julia --project=test test/unit_tests/units/test_X.jl`) or aggregated via
# run/unittests.jl. Include-guarded so re-including it (as happens when the
# aggregator includes every file in one process) is a no-op past the first hit.
if !@isdefined(check_float)
    using Test
    using BAYSOL
    using BAYSOL.PhysicalConstants: DRO_UNIT

    # Default absolute tolerance for floating-point equality checks
    # (abs(a - b) < DEFAULT_ATOL): a few orders of magnitude above Float64 roundoff.
    # Test-only, so it lives here, not in the package.
    const DEFAULT_ATOL = 1.0e-9

    check_float(a, b; atol = DEFAULT_ATOL) = abs(a - b) < atol
    check_complex(a, b; atol = DEFAULT_ATOL) = abs(a - b) < atol

    # CRYSOL's default bulk-solvent electron density (its fixed --dns), e·Å⁻³: the
    # conventional "bulk water" ρₑ input. Test-only, so it lives here, not in the package.
    const CRYSOL_SOLVENT_DENSITY = 0.334

    # Reference detector-scale intensity from a ForwardCache: the plain double sum
    #     I_calc(q) = scale · Σ_ab v_a(q) v_b(q) G_ab(q) + bkgrnd_corr,
    #     v(q) = (1, -dns·g(q; c_1), dro_1, dro_2, dro_3),  dro_k = DRO_UNIT·δρ_k,
    # g the excluded-volume envelope (c_1 = 1 ⇒ g ≡ 1). Written independently of the
    # fused A + g·B + g²·C path in BAYSOL.Fitting.profiled_corrs, so it can cross-check it.
    function reference_intensity(fw, scale, bkgrnd_corr, dns, δρ, c_1 = 1.0)
        g = BAYSOL.Scattering.excluded_volume_factor(fw.qvals, fw.r_m, c_1)
        d = DRO_UNIT .* δρ
        out = Vector{Float64}(undef, length(g))
        for k in eachindex(g)
            v = (1.0, -dns * g[k], d[1], d[2], d[3])
            s = 0.0
            for a in 1:5, b in 1:5
                s += v[a] * v[b] * fw.G[a, b, k]
            end
            out[k] = scale * s + bkgrnd_corr
        end
        return out
    end
end
