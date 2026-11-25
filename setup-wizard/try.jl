# SPDX-License-Identifier: LGPL-3.0-or-later

# Tries the setup wizard in a sandbox: a temporary HOME with its own XDG folders and a
# stand-in bundle, so nothing of the real machine is touched. Run it from a terminal:
#     julia --startup-file=no setup-wizard/try.jl
# The sandbox is removed when the wizard ends; what it wrote is listed first.

const HERE = @__DIR__
include(joinpath(HERE, "..", "platform.jl"))
sandbox = mktempdir()
bundle = mkpath(joinpath(sandbox, "bundle"))
for f in ("baysol", joinpath("sysimage", "baysol.so"), "baysol.icns", "baysol.ico")
    mkpath(dirname(joinpath(bundle, f)))
    write(joinpath(bundle, f), "")
end
env = Dict(
    "HOME" => sandbox,
    "USERPROFILE" => sandbox,  # Windows: `homedir()` reads this, not HOME
    "LOCALAPPDATA" => joinpath(sandbox, "AppData", "Local"),
    "APPDATA" => joinpath(sandbox, "AppData", "Roaming"),
    "JULIA_DEPOT_PATH" => get(ENV, "JULIA_DEPOT_PATH", joinpath(homedir(), ".julia")),
    "XDG_DATA_HOME" => joinpath(sandbox, "d"),
    "XDG_CACHE_HOME" => joinpath(sandbox, "c"),
    "XDG_CONFIG_HOME" => joinpath(sandbox, "cfg"),
    "BAYSOL_BUNDLE" => bundle,
)
println("sandbox: $sandbox")
code = "using BAYSOLSetup; exit(runWizard())"
cmd = addenv(`$(Base.julia_cmd()) --startup-file=no --project=$HERE -e $code`, env...)
try
    run(cmd)
finally
    println("\nwhat the wizard left in the sandbox:")
    for (root, _, files) in walkdir(sandbox)
        startswith(root, bundle) && continue
        for f in files
            println("  ", joinpath(root, f))
        end
    end
    println("install.json:")
    file = joinpath(Platform.config_home(; env, home = sandbox), "baysol", "install.json")
    println(isfile(file) ? read(file, String) : "  (none)")
    rm(sandbox; recursive = true, force = true)
end
