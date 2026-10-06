# SPDX-License-Identifier: LGPL-2.1-or-later

"""
Bayesian CRYSOL: NUTS sampling of the CRYSOL nuisance parameters (solvent density,
hydration-shell contrasts) with the excluded-volume correction profiled out.

The package root only assembles the modules, one folder per module under `src/`, in
dependency order, and re-binds the pipeline entry points of [`Report`](@ref
BAYSOL.Report) so they are reachable as `BAYSOL.seed_model`, `BAYSOL.run_model` and
`BAYSOL.write_report`.
"""
module BAYSOL

include("PhysicalConstants/PhysicalConstants.jl")
include("Cache/Cache.jl")
include("Timing/Timing.jl")
include("PlasticSequence/PlasticSequence.jl")
include("AtomicRadii/AtomicRadii.jl")
include("FormFactor/FormFactor.jl")
include("PartialMolarVolumes/PMV.jl")
include("MolecularStructure/MolecularStructure.jl")
include("SASA/SASA.jl")
include("Scattering/Scattering.jl")
include("Fitting/Fitting.jl")
include("Report/Report.jl")

using .PhysicalConstants:   PhysicalConstants
using .Cache:               Cache
using .Timing:              Timing
using .PlasticSequence:     PlasticSequence
using .AtomicRadii:         AtomicRadii
using .FormFactor:          FormFactor
using .PartialMolarVolumes: PartialMolarVolumes
using .MolecularStructure:  MolecularStructure
using .SASA:                SASA
using .Scattering:          Scattering
using .Fitting:             Fitting
using .Report:              Report, seed_model, run_model, write_report

# The pipeline entry points, reached qualified (`BAYSOL.seed_model`), not exported. Their
# result types live in Report (`BAYSOL.Report.MAPParams`, …).
public seed_model, run_model, write_report

end # module
