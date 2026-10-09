# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Bayesian CRYSOL: NUTS sampling of the CRYSOL nuisance parameters (solvent density,
hydration-shell contrasts) with the excluded-volume correction profiled out.

The package root only assembles the modules, one folder per module under `src/`, in
dependency order, and re-binds the pipeline entry points of [`Pipeline`](@ref
BAYSOL.Pipeline) so they are reachable as `BAYSOL.seed_model`, `BAYSOL.run_model` and
`BAYSOL.write_report`.
"""
module BAYSOL

include("Utils/Utils.jl")

# The Utils submodules are bound here,
# before the modules that import them by
# name are included.
using .Utils:               Utils
using .Utils.PhysicalConstants: PhysicalConstants
using .Utils.PlasticSequence: PlasticSequence
using .Utils.Shannon:       Shannon

# Runtime needs PhysicalConstants (Timing), so it comes second.
include("Runtime/Runtime.jl")

using .Runtime:             Runtime
using .Runtime.Cache:       Cache
using .Runtime.Timing:      Timing
using .Runtime.GCPause:     GCPause

include("PartialMolarVolumes/PMV.jl")
include("MolecularStructure/MolecularStructure.jl")
include("SASA/SASA.jl")
include("Scattering/Scattering.jl")
include("Inference/Inference.jl")
include("Pipeline/Pipeline.jl")

using .PartialMolarVolumes: PartialMolarVolumes
using .MolecularStructure:  MolecularStructure
using .SASA:                SASA
using .Scattering:          Scattering
using .Inference:             Inference
using .Pipeline:              Pipeline, seed_model, run_model, write_report

# The pipeline entry points, reached qualified
# (`BAYSOL.seed_model`), not exported. Their
# result types live in Pipeline (`BAYSOL.Pipeline.MAPParams`, …).
public seed_model, run_model, write_report

include("Precompile.jl")

end # module
