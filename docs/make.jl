# SPDX-License-Identifier: LGPL-2.1-or-later

using Documenter
using BAYSOL

# ---------------------------------------------------------------------------
# One list drives the whole site: every documented module, in dependency
# order. From it come the module list handed to `makedocs`, the "Guides"
# pages (each module's own `src/<Name>/README.md`, pulled in rather than
# hand-duplicated into docs/src) and the "API Reference" pages
# (`docs/src/api/<name>.md`). Adding a module means adding one line here
# (plus its README and api page).
# ---------------------------------------------------------------------------
const DOC_MODULES = [
    "Utils"               => BAYSOL.Utils,
    "Runtime"             => BAYSOL.Runtime,
    "Geometry"            => BAYSOL.Geometry,
    "BulkElectronDensity" => BAYSOL.BulkElectronDensity,
    "MolecularStructure"  => BAYSOL.MolecularStructure,
    "Scattering"          => BAYSOL.Scattering,
    "Inference"           => BAYSOL.Inference,
    "Pipeline"            => BAYSOL.Pipeline,
]

# Documented modules that have no page of their own: Utils
# is the only module with submodules, covered by its page.
const DOC_SUBMODULES = [BAYSOL.PhysicalConstants, BAYSOL.Shannon]

# A module whose API reference spans several pages lists them here (title =>
# page); every other module has the single page `api/<lowercase name>.md`.
const API_PAGE_OVERRIDES = Dict(
    "Inference" => [
        "Model and priors" => "api/inference.md",
        "Sampler" => "api/inference_sampler.md",
    ],
)

api_pages(name) = get(API_PAGE_OVERRIDES, name, "api/" * lowercase(name) * ".md")

# The tests are documented by their READMEs only (the test files themselves are far too
# large for a site): one "Testing" page per README under test/, in the order they appear
# in the navigation. title => README path relative to the repository root. The development
# commands (dev/README.md): their own section of the site, copied the same way.
const DEV_GUIDES = ["Commands" => "dev/README.md"]

const TEST_GUIDES = [
    "Overview"        => "test/README.md",
    "Unit tests"      => "test/unit_tests/README.md",
    "Utilities"       => "test/utils/README.md",
    "Baselines"       => "test/baselines/README.md",
    "Fixtures"        => "test/fixtures/README.md",
    "Validation"      => "test/validation/README.md",
    "Shannon binning" => "test/validation/shannon_binning/README.md",
    "MAP f-stop"      => "test/validation/map_fstop/README.md",
    "Threading"       => "test/validation/threading/README.md",
    "Fitting tests"   => "test/fitting_tests/README.md",
    "Visualizations"  => "test/visualize/README.md",
]

# The page file a test README is copied to: docs/src/testing/<its
# directory name>.md ("tests" for test/README.md).
const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
test_page(path) = (
    d = basename(dirname(normpath(joinpath(REPO_ROOT, path))));
    (d == "test" ? "tests" : d) * ".md"
)

# ---------------------------------------------------------------------------
# Pull each module's own README.md into the generated site as a "Guides"
# page. The destination filename for each is stable across runs
# (`force = true` makes a re-run reproducible rather than erroring on an
# existing copy).
# ---------------------------------------------------------------------------
const GUIDES_DIR = joinpath(@__DIR__, "src", "guides")
mkpath(GUIDES_DIR)

for (name, _) in DOC_MODULES
    cp(
        joinpath(@__DIR__, "..", "src", name, "README.md"),
        joinpath(GUIDES_DIR, lowercase(name) * ".md");
        force = true,
    )
end

# The test READMEs, with their relative links to each other pointed at the copied pages
# (the READMEs link to one another as files, which would be dead links on the site).
const TESTING_DIR = joinpath(@__DIR__, "src", "testing")
mkpath(TESTING_DIR)

page_of = Dict(
    normpath(joinpath(REPO_ROOT, path)) => test_page(path)
    for (_, path) in vcat(DEV_GUIDES, TEST_GUIDES)
)

for (_, path) in vcat(DEV_GUIDES, TEST_GUIDES)
    readme = normpath(joinpath(REPO_ROOT, path))
    # Documenter's Markdown parser does not know HTML comments: left in, they
    # print as text and swallow the table that follows (the Results-table
    # markers of the fitting-tests README), so they are dropped here.
    text = replace(read(readme, String), r"<!--.*?-->[ \t]*\n?"s => "")
    text = replace(
        text,
        r"\]\(([^)\s#]+\.md)(#[^)\s]*)?\)" => function (m)
            target, anchor = match(r"\]\(([^)\s#]+\.md)(#[^)\s]*)?\)", m).captures
            page = get(page_of, normpath(joinpath(dirname(readme), target)), nothing)
            page === nothing ? m : "](" * page * something(anchor, "") * ")"
        end,
    )
    write(joinpath(TESTING_DIR, test_page(path)), text)
end

makedocs(
    sitename = "BAYSOL.jl",
    # The default HTML format, except for the size warning (see below): the "academic" theme
    # (academic.scss) compiles directly to docs/src/assets/themes/documenter-light.css,
    # overwriting Documenter's own built-in light theme file in place.
    modules = [BAYSOL; last.(DOC_MODULES); DOC_SUBMODULES],
    pages   = [
    "Home" => "index.md",
    "Guides" => [
    name => joinpath("guides", lowercase(name) * ".md") for (name, _) in DOC_MODULES
    ],
    "Development" => [
    title => joinpath("testing", test_page(path)) for (title, path) in DEV_GUIDES
    ],
    "Testing" => [
    title => joinpath("testing", test_page(path)) for (title, path) in TEST_GUIDES
    ],
    "API Reference" => [name => api_pages(name) for (name, _) in DOC_MODULES]
    ],
    # :exports would require every exported docstring across every submodule
    # to be referenced in a docs page -- most of this package's functions are
    # deliberately unexported (`_logπ`, `_ll`, ...), so :exports would flag
    # them as "missing" even though the `@autodocs` blocks under api/ do
    # pull them in (`@autodocs` defaults to `Public = true, Private = true`).
    # Left un-strict (`:none`) until there's a reason to enforce an explicit
    # public API surface.
    checkdocs = :none,
    # The Scattering API page is a bit over Documenter's default 100 KiB warning size and
    # the search index over 500 KiB. The Scattering page is one coherent module, so the
    # warning levels are raised (the error levels stay).
    format = Documenter.HTML(;
        size_threshold_warn = 150 * 1024,
        search_size_threshold_warn = 750 * 1024,
    ),
    # Strict: every `@ref` resolves as of 2026-10-01, so a broken
    # cross-reference now fails the build (and the deploy) instead of
    # shipping a dead link.
)

# Deploys only from CI (.github/workflows/docs.yml): a push to master builds
# the "dev" docs, a pushed version tag builds that version and "stable".
# Locally this prints "could not auto-detect the building environment" and
# skips, which is expected.
deploydocs(
    repo = "github.com/noshou/BAYSOL.git",
    devbranch = "master",
)
