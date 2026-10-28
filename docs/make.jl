# SPDX-License-Identifier: LGPL-3.0-or-later

using Documenter
# Loaded for its effect: it makes the HTML pages render ```mermaid fences as diagrams.
using DocumenterMermaid
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
    "Hydrogenator"        => BAYSOL.Hydrogenator,
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
    "Overview"       => "test/README.md",
    "Unit tests"     => "test/unit_tests/README.md",
    "Baselines"      => "test/baselines/README.md",
    "Fixtures"       => "test/fixtures/README.md",
    "Fitting tests"  => "test/fitting_tests/README.md",
    "Visualizations" => "test/visualize/README.md",
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

# ---------------------------------------------------------------------------
# The home page is the repository README (so the guide for running an experiment is on the
# site too), copied like the guides, with its links to other READMEs pointed at the site's
# pages, followed by the root module's docstring. `docs/src/index.md` is generated and
# gitignored: edit the README, not the copy.
# ---------------------------------------------------------------------------
readme = read(joinpath(REPO_ROOT, "README.md"), String)
readme = replace(readme, r"<!--.*?-->[ \t]*\n?"s => "")
readme = replace(
    readme,
    r"\]\(src/([A-Za-z]+)/README\.md\)" =>
        m -> "](guides/" * lowercase(match(r"src/([A-Za-z]+)/", m).captures[1]) * ".md)",
)
for (_, path) in vcat(DEV_GUIDES, TEST_GUIDES)
    page = "](testing/" * test_page(path) * ")"
    global readme = replace(readme, "](" * path * ")" => page)
end
write(
    joinpath(@__DIR__, "src", "index.md"),
    readme * "\n\n```@autodocs\nModules = [BAYSOL]\n```\n",
)

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

# The release under the sidebar title on every page: `v0.3.0-wʋsg_n_yɩɩda` on a tag build
# (the tag and its message; .github/workflows/docs.yml fetches the annotated tag), `dev`
# otherwise. See release_label.jl.
include(joinpath(@__DIR__, "release_label.jl"))
stamp_release_label(joinpath(@__DIR__, "build"), release_label(REPO_ROOT))

# Only the light and dark themes stay in the settings menu (see prune_themes.jl).
include(joinpath(@__DIR__, "prune_themes.jl"))
prune_themes(joinpath(@__DIR__, "build"))

# The sun/moon button that toggles light and dark (see theme_toggle.jl).
include(joinpath(@__DIR__, "theme_toggle.jl"))
add_theme_toggle(joinpath(@__DIR__, "build"))

# A short link to the latest release in the navbar of older ones, instead of Documenter's
# pop-up (see version_notice.jl).
include(joinpath(@__DIR__, "version_notice.jl"))
add_version_notice(joinpath(@__DIR__, "build"))

# Deploys only from CI (.github/workflows/docs.yml): a push to master builds
# the "dev" docs, a pushed version tag builds that version's folder.
# Locally this prints "could not auto-detect the building environment" and
# skips, which is expected.
#
# `versions` is what the version selector lists and where the site root goes. The root
# redirects to the FIRST entry, and older releases get a "newer version available" banner
# pointing at it, so the releases come first (`v#.#.#`: every release by its full number,
# newest first: v0.3.0, v0.2.0, ...) and `dev` is last. There is deliberately no `stable`
# and no per-minor alias (`v0.3`): Documenter's default,
# `["stable" => "v^", "v#.#", "dev" => "dev"]`, would list `stable` and `v0.3` (symlinks to
# the same build) and hide `v0.3.0`. Documenter still writes `v0.3`-style symlinks on
# gh-pages (old links keep working); they are not in the selector.
#
# A release tag must be a plain `vX.Y.Z` (the release's name goes in the tag's message):
# a suffix such as `v0.3.0-name` is a pre-release to Documenter and is never listed.
deploydocs(
    repo = "github.com/noshou/BAYSOL.git",
    devbranch = "master",
    versions = ["v#.#.#", "dev" => "dev"],
)
