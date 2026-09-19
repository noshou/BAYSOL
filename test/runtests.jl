# SPDX-License-Identifier: LGPL-2.1-or-later

# to run the full test suite: 
#   julia --project=test test/runtests.jl

using Test
using ForwardDiff
using BayeSol
using BayeSol: Cache
using BayeSol.Constants: DEFAULT_ATOL
using BayeSol: AtomicRadii
using BayeSol.MolecularStructure: MolecularStructure
using BayeSol.Solvation.SASA: PlasticMap
using BayeSol: Scattering
using BayeSol.Scattering: SphFuncs
using BayeSol: FormFactor

check_float(a, b; atol = DEFAULT_ATOL) = abs(a - b) < atol
check_complex(a, b; atol = DEFAULT_ATOL) = abs(a - b) < atol

@testset "BayeSol" begin
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
