# SPDX-License-Identifier: LGPL-2.1-or-later

module BayeSol

include("Helpers/Helpers.jl")
include("AtomicRadii/AtomicRadii.jl")
include("FormFactor/FormFactor.jl")
include("PartialMolarVolumes/PMV.jl")
include("MolecularStructure/MolecularStructure.jl")
include("Solvation/Solvation.jl")
include("Scattering/Scattering.jl")
include("Fitting/Fitting.jl")

using .Helpers:            Helpers
using .Helpers.Constants:  Constants
using .Helpers.Cache:      Cache
using .AtomicRadii:        AtomicRadii
using .FormFactor:         FormFactor
using .PartialMolarVolumes: PartialMolarVolumes
using .MolecularStructure: MolecularStructure
using .Solvation:          Solvation
using .Scattering:         Scattering
using .Fitting:            Fitting

function seed_model(
    mol_src::MolecularStructure.StructureSource,
    lMax::Int64,
    energy::Real,
    qvals::AbstractVector,
    I_exp::AbstractVector,
    σ_exp::AbstractVector,
    pH::Real,
    σ_pH::Real,
    solutes::Vector{Fitting.Solute};
    add_hydrogens::Bool=true,
    blm_chunk::Unsigned = Helpers.Constants.B_LM_CHUNK,
    thickness::Real = Helpers.Constants.SHELL_THICKNESS,
    t::Real = Helpers.Constants.DEFAULT_TEMPERATURE_C,
    n::Real = Helpers.Constants.C1_PRIOR_MASS_PERCENT,
    probe::Float64 = Helpers.Constants.PROBE_RADIUS,
    n_target::Union{Nothing,Int} = Helpers.Constants.SHELL_N_TARGET,
    ionic_strength_M::Float64 = Helpers.Constants.IONIC_STRENGTH_M,
    eps_r::Float64 = Helpers.Constants.WATER_EPS_R,
    T::Float64 = Helpers.Constants.DEBYE_TEMPERATURE_K,
    cutoff_debye_lengths::Float64 = Helpers.Constants.CUTOFF_DEBYE_LENGTHS,
)::Fitting.Seed
    
    if !(length(qvals) == length(I_exp) == length(σ_exp)) 
        throw(
            DomainError(
                (
                    length(qvals), length(I_exp), length(σ_exp),
                    "qvals, I_exp, and σ_exp must have the same length"
                )
            )
        )
    elseif (length(qvals) == 0)
        throw(ArgumentError("qvals, I_exp, and σ_exp cannot be empty"))
    end
    
    # load pdb into cache and load residues w/o hydrogens, then resolve if needed
    path            = MolecularStructure.resolve_structure(mol_src)
    pKa_records     = MolecularStructure.propka_pKas(path)
    hpath           = MolecularStructure.resolve_hydrogens(path, pKa_records, pH; add=add_hydrogens)
    mol, residues   = MolecularStructure.load_molecule(hpath)

    # calculate forward model
    fw = Scattering.forward_cache(
        mol,
        qvals,
        lMax,
        energy;
        chunk=blm_chunk,
        thickness=thickness,
        probe=probe,
        n_target=n_target
    )

    # calculate ionization + electrostatics
    ionization = MolecularStructure.Ionization(residues, pKa_records, pH, σ_pH)
    μ_χ, σ_χ = Solvation.protein_cavity_electrostatics(
        mol,
        residues,
        ionization;
        probe=probe,
        n_target=n_target,
        ionic_strength_M=ionic_strength_M,
        eps_r=eps_r,
        T=T,
        cutoff_debye_lengths=cutoff_debye_lengths
    )

    return Fitting.seed_fitting(
        fw,
        I_exp,
        σ_exp,
        pH,
        σ_pH,
        solutes;
        t=t,
        μ_χ=μ_χ,
        σ_χ=σ_χ,
        n=n
    )
end

"""
    run_model(
        seed::Seed, 
        n_samples::Int64, 
        n_adapt::Int64; 
        l::LIKELIHOOD=PROFILE(), 
        δ::Real=80
    ) -> (samples, stats)

Identical to [`Fitting.run_fitting`](@ref).

Run NUTS on [`_logπ`](@ref) starting from `seed`, returning posterior draws
of the physical parameters `ξ = (dns, δρ1, δρ2, δρ3, c1)`.

# The Hamiltonian

HMC adds an auxiliary momentum `r ~ N(0, M)` (`M` the mass matrix) and defines 
a Hamiltonian:

    H(θ, r) = -log π(θ) + ½ rᵀM⁻¹r

with potential energy as the negative log-posterior, and Gaussian kinetic energy. 
Leapfrog integration simulates the system's dynamics forward in time,
alternating half-steps in `r` with full steps in `θ`:

    r ← r - (ε/2)·∇[-log π(θ)]
    θ ← θ + ε·M⁻¹r
    r ← r - (ε/2)·∇[-log π(θ)]

which needs `∇[log π(θ)]` at every step.

Because energy is conserved, leapfrog proposes long, correlated jumps through
parameter space far more cheaply than random-walk Metropolis. NUTS removes the 
need to hand-pick a trajectory length: it grows the leapfrog trajectory by 
doubling a binary tree of steps, forward and backward in time, until the trajectory
starts to double back on itself (a "U-turn"), then samples from the valid part of that tree.

# Step-size adaptation

`δ` is the target Metropolis acceptance rate. During the first `n_adapt` iterations,
`StepSizeAdaptor` tunes the leapfrog step size `ε` via dual-averaging so the
empirical acceptance rate converges to `δ`; too-small `ε` wastes computation
taking tiny steps, too-large `ε` causes leapfrog's discretization error (and
therefore the rejection rate) to blow up. `MassMatrixAdaptor` learns `M` (here the 
full parameter covariance, since `dns`/`δρ`/`c1` are physically coupled through the 
forward model) from the trajectory's sample covariance.

# Arguments
- `seed::Seed`: priors, initial point, forward cache, and data.
- `n_samples::Int64`: total number of NUTS iterations (including the
    `n_adapt` warm-up steps, which are kept unless `drop_warmup` is set).
- `n_adapt::Int64`: number of warm-up iterations spent adapting the step
    size and mass matrix before sampling proper.

# Keywords
- `l::LIKELIHOOD=PROFILE()`: `PROFILE()` or `MARGINAL()`, forwarded to
    [`_logπ`](@ref)/[`_ll`](@ref).
- `δ::Real=80`: target acceptance rate as a percentage, `(0, 100)` exclusive
    (validated below); Stan's usual default of 80% is used here too absent a
    specific reason to retarget it.

# Returns
- `samples`: a `Vector` of posterior draws.
"""
function run_model(
    seed::Fitting.Seed,
    n_samples::Int64,
    n_adapt::Int64;
    l::Fitting.LIKELIHOOD=Fitting.PROFILE(),
    δ::Real=80
)
    return Fitting.run_fitting(seed, n_samples, n_adapt; l=l, δ=δ)
end

end # module
