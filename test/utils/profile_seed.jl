# SPDX-License-Identifier: LGPL-2.1-or-later

# Where does the static build of a fit spend its time? Builds the `Seed` of a fitting test twice (the first call warms
# the compiler), profiles the second with Julia's sampling profiler, and prints the stage timings of that build and
# the samples by function: exclusive (the function was running) and inclusive (it was on the stack), for frames in
# BAYSOL's own source. Started through `tclsh test/run/profile.tcl ID[:tag] [--delay 0.0005]`; development tooling,
# not a test.

using Printf
using Profile
using BAYSOL
include(joinpath(@__DIR__, "fit_seed.jl"))

function main(args)
    delay = 0.0005; specs = String[]
    i = 1
    while i ≤ length(args)
        if args[i] == "--delay"; delay = parse(Float64, args[i+1]); i += 2
        else push!(specs, args[i]); i += 1 end
    end
    isempty(specs) && error("give an ID[:tag]")
    for spec in specs
        id, tag = occursin(':', spec) ? split(spec, ":") : (spec, "")
        load_fit_seed(String(id), String(tag); makie = false)             # warm-up
        Profile.clear(); Profile.init(n = 10^7, delay = delay)
        local seed
        t = @elapsed (Profile.@profile (seed, _, _) = load_fit_seed(String(id), String(tag); makie = false))
        println("\n=== $spec: second seed build (script load included) took $(round(t; digits = 2)) s")
        for st in seed.timing.stages
            st.group === :static || continue
            @printf("  %s%-48s %7.3f s\n", "  "^st.depth, st.name, st.seconds)
        end
        data, lidict = Profile.retrieve()
        baysol(fr) = occursin("/BAYSOL/src/", string(fr.file))
        label(fr) = string(fr.func) * " (" * basename(string(fr.file)) * ")"
        self = Dict{String,Int}(); incl = Dict{String,Int}(); nsamp = 0
        trace_start = 1
        for k in eachindex(data)
            data[k] == 0 || continue
            trace = data[trace_start:k-1]; trace_start = k + 1
            isempty(trace) && continue
            frames = [fr for ip in trace for fr in get(lidict, ip, Base.StackTraces.StackFrame[])]
            bf = filter(baysol, frames)
            isempty(bf) && continue                   # idle threads, the REPL, the profiler itself
            nsamp += 1
            # time charged to the innermost BAYSOL function, including the libraries it called into
            n = label(bf[1]); self[n] = get(self, n, 0) + 1
            for l in unique(label.(bf)); incl[l] = get(incl, l, 0) + 1; end
        end
        println("  $nsamp samples with a BAYSOL frame on the stack")
        println("  -- charged to the innermost BAYSOL function (its own code plus the libraries it calls):")
        for (n, c) in first(sort(collect(self); by = last, rev = true), 20)
            @printf("     %5.1f %%  %s\n", 100c / nsamp, n)
        end
        println("  -- inclusive:")
        for (n, c) in first(sort(collect(incl); by = last, rev = true), 30)
            @printf("     %5.1f %%  %s\n", 100c / nsamp, n)
        end
    end
end

main(ARGS)
