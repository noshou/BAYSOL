# SPDX-License-Identifier: LGPL-3.0-or-later

# Runs the visual checks in test/visualize/.
module Vis

using ..Common

const WHO = "bysl vis"

const USAGE = """
Runs the visual checks of test/visualize/ (most need a display).

    bysl vis [NAME ...] [--list] [--dry-run]

    NAME        checks to run (default: all); an unknown name stops the run
    --list      show the checks
    --dry-run   print the commands, run nothing
    --threads N Julia threads (4, auto, 4,1); default one
"""

"A visual check: its name, script in test/visualize/, the Julia call, a description."
struct Check
    name::String
    script::String
    call::String
    doc::String
end

# The checks, in the order they run.
const CHECKS = [
    Check("plastic_2d", "plastic-vis.jl", "visPlasticPoints2d(2000)",
        "plastic sequence on a spherical surface (2-D generator)"),
    Check("plastic_3d", "plastic-vis.jl", "visPlasticPoints3d(2000)",
        "plastic sequence filling a spherical volume (3-D generator)"),
    Check("sasa_hydro", "sasa-hydro-vis.jl", "visSasaHydro()",
        "SASA hydration-shell dummy cloud over a packed cluster"),
    Check("sasaHydroReport", "sasa-hydro-vis.jl", "sasaHydroReport()",
        "the same, numbers only, no window (works headless)"),
]

"The Julia command line of one check: include its script, then call it."
command(julia, c::Check) = [julia, "--startup-file=no",
    "--project=" * in_root("test", "visualize"), "-e",
    "include(\"" * in_root("test", "visualize", c.script) * "\"); " * c.call]

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    if any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    (; flags, specs) = split_args(WHO, String[], ["--list", "--dry-run"], argv;
        word = "one of")
    by_name = Dict(c.name => c for c in CHECKS)
    missing_names = filter(!in(keys(by_name)), specs)
    if "--list" in flags
        for c in CHECKS
            println(rpad(c.name, 18), " ", c.doc)
        end
        return 0
    elseif !isempty(missing_names)
        fail(
            WHO,
            "no visual check named: $(join(missing_names, ", ")) " *
            "(available: $(join([c.name for c in CHECKS], " ")))",
        )
    end
    julia = find_julia()
    dry = "--dry-run" in flags
    chosen = [by_name[n] for n in (isempty(specs) ? [c.name for c in CHECKS] : specs)]
    failed = String[]
    for c in chosen
        println("\n=== ", c.name)
        sh(dry, command(julia, c)) || push!(failed, c.name)
    end
    isempty(failed) && return 0
    println(stderr, "\n", WHO, ": failed: ", join(failed, ", "))
    return 1
end

end
