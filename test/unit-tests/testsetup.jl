# SPDX-License-Identifier: LGPL-3.0-or-later

# Shared baseline so every units/test-*.jl can run standalone
# (`julia --project=test test/unit-tests/units/test_X.jl`) or aggregated via
# dev/scripts/unittests.jl. Include-guarded so re-including it (as happens when the
# aggregator includes every file in one process) is a no-op past the first hit.
if !@isdefined(checkFloat)
    using Test
    using BAYSOL
    using BAYSOL.PhysicalConstants: UNIT_OF_δρ

    # Default absolute tolerance for floating-point equality checks
    # (abs(a - b) < DEFAULT_ATOL): a few orders of magnitude above Float64 roundoff.
    # Test-only, so it lives here, not in the package.
    const DEFAULT_ATOL = 1.0e-9

    checkFloat(a, b; atol = DEFAULT_ATOL) = abs(a - b) < atol

    # The folder of the experiment fixtures of the entry `id`. They are kept as one
    # archive per entry (`test/fixtures/experiments/<id>.7z`, no plain folders): the
    # plain folder is used when present, else the archive is unpacked once per process
    # into a `mktempdir` that is removed at exit (an archive entry path starts with
    # `<id>/`, or the files are flat in the archive). Test-only.
    const _EXPERIMENT_DIRS = Dict{String,String}()
    function experimentFixtureDir(id::AbstractString)::String
        get!(_EXPERIMENT_DIRS, String(id)) do
            base = joinpath(@__DIR__, "..", "fixtures", "experiments")
            plain = joinpath(base, id)
            isdir(plain) && return plain
            archive = joinpath(base, "$id.7z")
            isfile(archive) || error("no fixtures for $id in $base")
            exe = BAYSOL.Platform.find_tool("7z", "7zz")
            exe === nothing &&
                error(
                    "7z (7-Zip) is not on the PATH nor in the folders installers use " *
                    "for it",
                )
            tmp = mktempdir(; cleanup = true)
            run(pipeline(`$exe x -y -o$tmp $archive`; stdout = devnull))
            isdir(joinpath(tmp, id)) ? joinpath(tmp, id) : tmp
        end
    end

    # The value of every setting at its default, the `Dict` that the keyword helpers
    # (`seedKeywords`, `runKeywords`, `resultsKeywords`) take: what `loadSettings` of
    # `tui/julia/src/settings-file.jl` returns when there is no settings file.
    defaultSettings() = Dict{Symbol,Any}(
        n => BAYSOL.Pipeline._settingDefault(n) for n in BAYSOL.Pipeline._settingNames()
    )

    # Complex `Yₗᵐ` (packed row l(l+1)÷2 + m + 1, one column per point) from the one
    # implementation, the in-place `SphFuncs.sphHarm!`, which writes the real layout
    # [Re Y; −Im Y] per degree: builds the output and the workspace and converts (an
    # invalid `lMax` or shape reaches `sphHarm!`, which throws SphHarmError).
    function sphHarm(lMax::Int, θ, φ)
        sf = BAYSOL.Scattering
        n = length(θ)
        A = Matrix{Float64}(undef, max((lMax + 1) * (lMax + 2), 0), n)
        sf.sphHarm!(A, sf.sphHarmCache(max(lMax, 0)), lMax, θ, φ)
        y = Matrix{ComplexF64}(undef, (lMax + 1) * (lMax + 2) ÷ 2, n)
        for i in 1:n, l in 0:lMax, m in 0:l
            k0 = l * (l + 1) ÷ 2
            y[k0+m+1, i] = complex(A[2k0+m+1, i], -A[2k0+l+1+m+1, i])
        end
        return y
    end
    checkComplex(a, b; atol = DEFAULT_ATOL) = abs(a - b) < atol

    # CRYSOL's default bulk-solvent electron density (its fixed --dns), e·Å⁻³: the
    # conventional "bulk water" ρₑ input. Test-only, so it lives here, not in the package.
    const CRYSOL_SOLVENT_DENSITY = 0.334

    # Reference detector-scale intensity from a ForwardCache: the plain double sum
    #     I_calc(q) = scale · Σ_ab v_a(q) v_b(q) G_ab(q) + bkgrndCorr,
    #     v(q) = (1, -dns·g(q; c1Factor), dro_1, dro_2, dro_3),  dro_k = UNIT_OF_δρ·δρ_k,
    # g the excluded-volume envelope (c1Factor = 1 ⇒ g ≡ 1). Written independently of the
    # fused A + g·B + g²·C path in BAYSOL.Inference.profiledCorrs, so it can cross-check it.
    function referenceIntensity(fw, scale, bkgrndCorr, dns, δρ, c1Factor = 1.0)
        g = BAYSOL.Scattering.excludedVolumeFactor(fw.qvals, fw.rM, c1Factor)
        d = UNIT_OF_δρ .* δρ
        out = Vector{Float64}(undef, length(g))
        for k in eachindex(g)
            v = (1.0, -dns * g[k], d[1], d[2], d[3])
            s = 0.0
            for a in 1:5, b in 1:5
                s += v[a] * v[b] * fw.G[a, b, k]
            end
            out[k] = scale * s + bkgrndCorr
        end
        return out
    end
end
