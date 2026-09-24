# SPDX-License-Identifier: LGPL-2.1-or-later

using Documenter
using BAYSOL

# ---------------------------------------------------------------------------
# Pull each module's own README.md into the generated site as a "Guides"
# page, rather than hand-duplicating its prose into docs/src. Explicit
# source -> destination mapping (not a directory glob) so it's obvious from
# reading this file which READMEs are part of the docs build, and the
# destination filename for each is stable across runs (`force = true` makes
# a re-run reproducible rather than erroring on an existing copy).
# ---------------------------------------------------------------------------
const README_PAGES = [
    "AtomicRadii"         => "AtomicRadii",
    "BAYSOL_Utils"        => "BAYSOL_Utils",
    "Fitting"              => "Fitting",
    "FormFactor"            => "FormFactor",
    "Geometry"              => "Geometry",
    "MolecularStructure"    => "MolecularStructure",
    "PartialMolarVolumes"   => "PartialMolarVolumes",
    "Scattering"            => "Scattering",
    "Solvation"              => "Solvation",
]

const GUIDES_DIR = joinpath(@__DIR__, "src", "guides")
mkpath(GUIDES_DIR)

for (name, srcdir) in README_PAGES
    src  = joinpath(@__DIR__, "..", "src", srcdir, "README.md")
    dest = joinpath(GUIDES_DIR, lowercase(name) * ".md")
    cp(src, dest; force = true)
end

makedocs(
    sitename = "BAYSOL.jl",
    # The "academic" theme (docs/src/assets/themes/academic.scss, compiled to
    # documenter-academic.css) isn't in Documenter's own hardcoded `THEMES`
    # list (HTMLWriter.jl), so it can't appear in the built-in theme-picker
    # switcher via any make.jl option. Instead it's loaded as a plain asset
    # and force-applied unconditionally by force-academic-theme.js, which
    # runs after Documenter's own themeswap.js and overrides whatever class
    # that set. See force-academic-theme.js for why this is the only way to
    # wire in a non-built-in theme.
    format   = Documenter.HTML(
        assets = [
            "assets/themes/documenter-academic.css",
            "assets/force-academic-theme.js",
        ],
    ),
    modules  = [
        BAYSOL,
        BAYSOL.Constants,
        BAYSOL.Cache,
        BAYSOL.Geometry,
        BAYSOL.Geometry.PlasticSequence,
        BAYSOL.Geometry.Metrics,
        BAYSOL.AtomicRadii,
        BAYSOL.FormFactor,
        BAYSOL.PartialMolarVolumes,
        BAYSOL.MolecularStructure,
        BAYSOL.Scattering,
        BAYSOL.Scattering.SphFuncs,
        BAYSOL.Solvation.SASA,
        BAYSOL.Solvation.Electrostatics,
        BAYSOL.Fitting,
    ],
    pages    = [
        "Home" => "index.md",
        "Guides" => [
            name => joinpath("guides", lowercase(name) * ".md")
            for (name, _) in README_PAGES
        ],
        "API Reference" => [
            "BAYSOL_Utils" => "api/baysolutils.md",
            "Geometry" => "api/geometry.md",
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

deploydocs(
    repo = "github.com/noshou/BAYSOL.git",
)
