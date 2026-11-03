# SPDX-License-Identifier: LGPL-3.0-or-later

# The cache of the programs the tools start: what is in it and what the daemon will clear.
module Cache

using ..Common

const WHO = "bysl cache"

const USAGE = """
The cache of the programs the tools start.

    bysl cache list
    bysl cache clear

    list        the cache folder, the manifest, and what `clear` would remove
    clear       remove what the manifest lists (the daemon does this on exit)

Structure files (.pdb .cif .mmcif .ent) and components/ are never removed.
"""

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    if isempty(argv) || any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return 0
    end
    length(argv) == 1 || fail(WHO, "give list or clear")
    if argv[1] == "list"
        println("cache folder: ", cache_root())
        entries = manifest_entries()
        println("manifest:     ", Common.cache_manifest(), " (", length(entries), " files)")
        for rel in entries
            fate =
                Common.protected(rel) ? "kept" :
                isfile(joinpath(cache_root(), rel)) ? "cleared" : "gone"
            println("  ", rpad(fate, 8), rel)
        end
    elseif argv[1] == "clear"
        println("removed ", clear_cache!(), " files from ", cache_root())
    else
        fail(WHO, "unknown subcommand $(argv[1]) (one of: list, clear)")
    end
    return 0
end

end
