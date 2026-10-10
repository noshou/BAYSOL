# SPDX-License-Identifier: LGPL-2.1-or-later

# Formats Julia files with JuliaFormatter.jl to the settings of the
# repository's .JuliaFormatter.toml (92 characters per line, the author's
# line breaks kept wherever they fit). Started by dev/format.tcl:
#
#   julia --project=test/format test/utils/format.jl (--apply|--check) FILE_OR_DIR ...
#
# `--apply` rewrites the files and lists the ones that changed; `--check` changes nothing
# and lists the files that are not formatted. Exit status 1 if `--check` finds one.

using JuliaFormatter

function julia_files(path)
    isfile(path) && return endswith(path, ".jl") ? [path] : String[]
    out = String[]
    for (root, dirs, files) in walkdir(path)
        filter!(
            d -> d ∉ (".git", "build", "_cache", "sources", "manuscript", ".CondaPkg"),
            dirs,
        )
        for f in files
            endswith(f, ".jl") && push!(out, joinpath(root, f))
        end
    end
    return sort!(out)
end

function main(args)
    mode = args[1]
    mode in ("--apply", "--check") || error("first argument must be --apply or --check")
    files = reduce(vcat, julia_files.(args[2:end]); init = String[])
    changed = String[]
    for f in files
        if mode == "--apply"
            format_file(f) || push!(changed, f)
        else
            format_file(f; overwrite = false) || push!(changed, f)
        end
    end
    for f in changed
        println(mode == "--apply" ? "formatted: " : "not formatted: ", f)
    end
    println(length(files), " Julia files, ", length(changed),
        mode == "--apply" ? " rewritten" : " not formatted")
    exit(mode == "--check" && !isempty(changed) ? 1 : 0)
end

main(ARGS)
