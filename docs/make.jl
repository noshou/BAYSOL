# SPDX-License-Identifier: LGPL-2.1-or-later

using Documenter
using BayeSol

makedocs(
    sitename = "BayeSol.jl",
    modules  = [
        BayeSol,
        BayeSol.Constants,
        BayeSol.Cache,
        BayeSol.AtomicRadii,
        BayeSol.FormFactor,
        BayeSol.PartialMolarVolumes,
        BayeSol.MolecularStructure,
        BayeSol.Scattering,
        BayeSol.Scattering.SphFuncs,
        BayeSol.Solvation.SASA,
        BayeSol.Solvation.SASA.PlasticMap,
        BayeSol.Solvation.Electrostatics,
        BayeSol.Fitting,
    ],
    pages    = [
        "Home" => "index.md",
        "API Reference" => [
            "BayesolUtils" => "api/BayesolUtils.md",
            "AtomicRadii" => "api/atomicradii.md",
            "FormFactor" => "api/formfactor.md",
            "PartialMolarVolumes" => "api/partialmolarvolumes.md",
            "MolecularStructure" => "api/molecularstructure.md",
            "Scattering" => "api/scattering.md",
            "Solvation" => "api/solvation.md",
            "Fitting" => "api/fitting.md",
        ],
    ],
    # :exports would require every exported docstring across every submodule
    # to be referenced in a docs page -- most of this package's functions are
    # deliberately unexported (`_logπ`, `_ll`, ...), so :exports would flag
    # them as "missing" even though the `@autodocs` blocks under api/ do
    # pull them in (`@autodocs` defaults to `Public = true, Private = true`).
    # Left un-strict (`:none`) until there's a reason to enforce an explicit
    # public API surface.
    checkdocs = :none,
    # Now that every submodule has its own api/*.md page, `@ref` links like
    # [`run_fitting`](@ref)/[`_logπ`](@ref)/[`_ll`](@ref) in docstrings
    # should resolve for real; kept as a warn-not-fail safety net rather than
    # removed outright, since a doc `@ref` typo shouldn't block the build.
    warnonly = [:cross_references],
)
