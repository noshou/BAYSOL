# SPDX-License-Identifier: LGPL-2.1-or-later

# Runs the full unit-test suite:
#   julia --project=test test/unit_tests/run_unit_tests.jl
#
# Every test_*.jl file here is self-contained (each `include`s its own
# testsetup.jl and declares its own `using`s), so it can also be run on its
# own, e.g.:
#   julia --project=test test/unit_tests/test_atomicradii.jl

using Test

@testset "BAYSOL" begin
    include("test_cache.jl")
    include("test_atomicradii.jl")
    include("test_molecules.jl")
    include("test_sphfuncs.jl")
    include("test_partialwave.jl")
    include("test_scatterers.jl")
    include("test_intensity.jl")
    include("test_forward.jl")
    include("test_formfactor.jl")
    include("test_pmv.jl")
    include("test_dns.jl")
    include("test_ionization.jl")
    include("test_propka.jl")
    include("test_structuresource.jl")
    include("test_pdb2pqr.jl")
    include("test_pipeline.jl")
    include("test_integration.jl")
    include("test_wls.jl")
    include("test_plasticmap.jl")
    include("test_sasa.jl")
    include("test_electrostatics.jl")
    include("test_deltarho.jl")
    include("test_excludedvolume.jl")
    include("test_paramtransform.jl")
    include("test_sampler.jl")
    include("test_quality.jl")
end
