# SPDX-License-Identifier: LGPL-3.0-or-later

"""
Bayesian CRYSOL: NUTS sampling of the CRYSOL nuisance parameters (solvent density,
hydration-shell contrasts) with the excluded-volume correction profiled out.
"""
module BAYSOL

# The one module that detects the operating system (shared by every project of the
# repository by relative path, see platform.jl).
include("../platform.jl")

# The physical constants (one root file, like platform.jl and precompile.jl) and the
# DataGrid module are bound here, before the modules that import them by name are included.
include("physical-constants.jl")
include("data-grid/data-grid.jl")

using .PhysicalConstants: PhysicalConstants
using .DataGrid: DataGrid

# Runtime needs PhysicalConstants (Timing), so it comes after them.
include("runtime/runtime.jl")
using .Runtime: Runtime

# Geometry (point sets, excluded volumes, SASA) needs
# only Runtime; MolecularStructure builds on it.
include("geometry/geometry.jl")
include("bulk-electron-density/bulk-electron-density.jl")
include("molecular-structure/molecular-structure.jl")
include("hydrogenator/hydrogenator.jl")
include("scattering/scattering.jl")
include("inference/inference.jl")
include("pipeline/pipeline.jl")

using .Geometry: Geometry
using .BulkElectronDensity: BulkElectronDensity
using .MolecularStructure: MolecularStructure
using .Hydrogenator: Hydrogenator
using .Scattering: Scattering
using .Inference: Inference
using .Pipeline:
    Pipeline, seedModel, runModel, writeLog, printSummary, results, compareResults,
    PlotStyle, Reference, fontAvailable, InvalidSettingsError, seedKeywords,
    runKeywords, runArguments, resultsKeywords

# The pipeline entry points, reached qualified
# (`BAYSOL.seedModel`), not exported. Their
# result types live in Pipeline (`BAYSOL.Pipeline.MAPParams`, …).
public seedModel,
    runModel, writeLog, printSummary, results, compareResults, PlotStyle, Reference,
    fontAvailable, InvalidSettingsError, seedKeywords, runKeywords, runArguments,
    resultsKeywords

include("precompile.jl")

end # module
