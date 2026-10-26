# SPDX-License-Identifier: LGPL-3.0-or-later

"""
Bayesian CRYSOL: NUTS sampling of the CRYSOL nuisance parameters (solvent density,
hydration-shell contrasts) with the excluded-volume correction profiled out.

The package root only assembles the modules, one folder per module under `src/`,
in dependency order, and re-binds the pipeline entry points of
[`Pipeline`](@ref BAYSOL.Pipeline) so they are reachable as `BAYSOL.seed_model`,
`BAYSOL.run_model` and `BAYSOL.write_timings`, and its plotting entry point as
`BAYSOL.results` (with `BAYSOL.PlotStyle` and `BAYSOL.Reference`).
"""
module BAYSOL

include("Utils/Utils.jl")

# The Utils submodules are bound here,
# before the modules that import them by
# name are included. Utils is the only module
# with submodules; every other module is one module.
using .Utils: Utils
using .Utils.PhysicalConstants: PhysicalConstants
using .Utils.Shannon: Shannon

# Runtime needs PhysicalConstants (Timing), so it comes second.
include("Runtime/Runtime.jl")
using .Runtime: Runtime

# Geometry (point sets, excluded volumes, SASA) needs
# only Runtime; MolecularStructure builds on it.
include("Geometry/Geometry.jl")
include("BulkElectronDensity/BulkElectronDensity.jl")
include("MolecularStructure/MolecularStructure.jl")
include("Hydrogenator/Hydrogenator.jl")
include("Scattering/Scattering.jl")
include("Inference/Inference.jl")
include("Pipeline/Pipeline.jl")

using .Geometry: Geometry
using .BulkElectronDensity: BulkElectronDensity
using .MolecularStructure: MolecularStructure
using .Hydrogenator: Hydrogenator
using .Scattering: Scattering
using .Inference: Inference
using .Pipeline:
    Pipeline, seed_model, run_model, write_timings, print_summary, results,
    PlotStyle, Reference, font_available

# The pipeline entry points, reached qualified
# (`BAYSOL.seed_model`), not exported. Their
# result types live in Pipeline (`BAYSOL.Pipeline.MAPParams`, …).
public seed_model,
    run_model, write_timings, print_summary, results, PlotStyle, Reference,
    font_available

include("Precompile.jl")

end # module
