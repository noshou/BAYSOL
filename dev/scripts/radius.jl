# SPDX-License-Identifier: LGPL-3.0-or-later

# The mean atomic radius rM of a fit's structure, after hydrogenation, for `bysl fits
# radius`, in two phases so that only the runs that are wanted are hydrogenated. Phase 1
# reads, per spec, only the `.fit` header (`load_fit_header`, no structure work); a run
# whose header has no `Ra:` is dropped. Phase 2 builds the `Seed` of each survivor
# (`load_fit_seed_info`, nothing is fitted) and reads `seed.fw.rM`. BAYSOL caches the
# hydrogenated structures (`<stem>_pH<pH>_<ff>_<method>.pdb` in $BAYSOL_CACHE), so a
# structure that was there is reused: the files of the cache are listed before and after
# each spec and the line says `cached` or `hydrogenated`. One tab-separated line per spec
# on stdout:
#
#     spec <TAB> rM <TAB> ok <TAB> fitFile <TAB> software <TAB> header <TAB> status
#
# `header` is the first lines of the `.fit` file joined by " | ", `software` is `-` when
# the script names none, `status` is `cached` or `hydrogenated`; a run without `Ra:` prints
# `spec <TAB> - <TAB> noRa`; a spec that fails prints `spec <TAB> - <TAB> error text` and
# the next spec goes on. `--header-only` stops after phase 1 (lines `ok` with rM `0`
# and status `-`).
# Started as `julia --project=test/fitting_tests dev/scripts/radius.jl [--header-only]
# ID[:tag] ...`; development tooling, not a test.

using BAYSOL
include(joinpath(@__DIR__, "..", "src", "fit-seed.jl"))

# One line of text: tabs and line breaks of `s` become spaces.
oneline(s) = strip(replace(string(s), r"[\t\r\n]+" => " "))

# The hydrogenated structures in the cache folder: the files named `*_pH*.pdb`.
function hydrogenated_files()
    dir = get(ENV, "BAYSOL_CACHE", "")
    isdir(dir) || return Set{String}()
    return Set(
        joinpath(root, f) for (root, _, files) in walkdir(dir) for
        f in files if occursin("_pH", f) && endswith(f, ".pdb")
    )
end

function main(args)
    header_only = "--header-only" in args
    specs = filter(a -> !startswith(a, "--"), args)
    isempty(specs) && error("give an ID[:tag]")
    # phase 1: the .fit header of each spec; the survivors have an Ra
    survivors = Tuple{String,Any}[]
    for spec in specs
        id, tag = occursin(':', spec) ? split(spec, ":"; limit = 2) : (spec, "")
        try
            h = load_fit_header(String(id), String(tag))
            if occursin(r"Ra:\s*[\d.]+", h.fitHeader)
                push!(survivors, (spec, h))
            else
                println(spec, "\t-\tnoRa")
            end
        catch err
            println(spec, "\t-\t", oneline(sprint(showerror, err)))
        end
        flush(stdout)
    end
    # phase 2: the seeds of the survivors
    for (spec, h) in survivors
        id, tag = occursin(':', spec) ? split(spec, ":"; limit = 2) : (spec, "")
        software = h.software === nothing ? "-" : oneline(h.software)
        header = oneline(join(split(h.fitHeader, '\n'), " | "))
        try
            if header_only
                rM, status = 0.0, "-"
            else
                before = hydrogenated_files()
                info = load_fit_seed_info(String(id), String(tag))
                rM = info.seed.fw.rM
                status = issubset(hydrogenated_files(), before) ? "cached" : "hydrogenated"
            end
            println(join([spec, rM, "ok", h.fitFile, software, header, status], "\t"))
        catch err
            println(spec, "\t-\t", oneline(sprint(showerror, err)))
        end
        flush(stdout)
    end
end

main(ARGS)
