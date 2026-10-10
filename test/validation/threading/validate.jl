# SPDX-License-Identifier: LGPL-2.1-or-later

# Does threading change what the code computes, and is it faster? The same script is run once per thread count
# (`--threads N`); each run compares itself with the earlier result files in results/ made with a different number of
# threads. Stages (`--stages static,map`; default static):
#   static  the seed build of each fitting test (SASA, excluded volumes, B_lm, Gram), built three times, the first
#           warming the compiler; the stage seconds are the best of three warm builds, each after a full collection, and the Gram matrix is fingerprinted
#           bit for bit.
#   map     the multi-start MAP search for each base value (`--bases 1,2,3`): the mode ẑ, the whitening S, the evaluation
#           count and the mode count, bit for bit, and the warm wall time. (Not threaded any more: it was measured slower
#           at 4 threads, see README.md; kept to show that the results do not depend on the thread count.)
#
#   tclsh test/run/validate.tcl threading [ID ...] --threads 1 --approved      # the entry point: prints its plan without --approved
#   tclsh test/run/validate.tcl threading [ID ...] --threads 4 --approved
#
# which runs
#
#   julia --project=test/fitting_tests test/validation/threading/validate.jl [--bases 1,2,3] [--out FILE.tsv] ID[:tag] ...
#
# Criteria are in README.md in this folder (fixed before the first run; stage by stage as each stage is threaded).

using Printf, Statistics
using BAYSOL
const Fit = BAYSOL.Inference
include(joinpath(@__DIR__, "..", "..", "utils", "fit_seed.jl"))

bits(x::AbstractArray{Float64}) = reinterpret(UInt64, collect(vec(x)))

# One MAP search with base `b`: its fingerprint and the wall time of a second, warm call.
function map_run(seed, b::UInt64)
    sp = Fit._sampling_space(seed, Fit.PROFILE(); base = b)          # compile + the result
    t = @elapsed Fit._sampling_space(seed, Fit.PROFILE(); base = b)  # warm timing
    fp = hash((bits(Vector(sp.ẑ)), bits(Matrix(sp.S)), sp.n_evals, sp.n_modes, sp.n_ok, sp.whitened))
    return (; fp, t, n_evals = sp.n_evals, n_modes = sp.n_modes)
end

const HDR = "fit\tbase\tthreads\tstage\tfingerprint\tseconds\tn_evals\tn_modes"

# Seconds of the stage called `name` in a seed's timing log (0 if absent).
stage_seconds(seed, name) = sum((st.seconds for st in seed.timing.stages if startswith(st.name, name)); init = 0.0)

# Rows of one fit's static build: best-of-two warm stage times, and the Gram matrix fingerprint.
function static_rows(id, tag, label)
    load_fit_seed(id, tag; makie = false)                       # warms the compiler
    best = Dict{String,Float64}(); fp = ""
    for _ in 1:3
        GC.gc(true)      # a clean heap before each timed build, so a collection of the previous one does not land in this one
        seed, _, _ = load_fit_seed(id, tag; makie = false)
        @printf(stderr, "  [%s] peak RSS so far %.2f GB, live heap %.2f GB\n", label, Sys.maxrss() / 2^30, Base.gc_live_bytes() / 2^30)
        fp = string(hash(bits(seed.fw.G)), base = 16)
        for (k, name) in (("sasa", "SASA"), ("forward_cache", "forward_cache"), ("vac_exvol", "vacuum + excluded volume"),
                          ("hydration", "hydration"))
            best[k] = min(get(best, k, Inf), stage_seconds(seed, name))
        end
    end
    return [(label, 0, k, k == "forward_cache" ? fp : "-", best[k]) for k in ("sasa", "forward_cache", "vac_exvol", "hydration")]
end

function read_rows(path)
    rows = Dict{Tuple{String,String,String},Tuple{String,Float64}}()   # (fit, base, stage) => (fingerprint, seconds)
    threads = 0
    for l in Iterators.drop(eachline(path), 1)
        f = split(l, '\t')
        length(f) ≥ 8 || continue
        threads = parse(Int, f[3])
        rows[(f[1], f[2], f[4])] = (f[5], parse(Float64, f[6]))
    end
    return threads, rows
end

function main(args)
    bases = [1, 2, 3]; out = nothing; specs = String[]; stages = ["static"]
    i = 1
    while i ≤ length(args)
        if args[i] == "--bases"; bases = parse.(Int, split(args[i+1], ",")); i += 2
        elseif args[i] == "--stages"; stages = String.(split(args[i+1], ",")); i += 2
        elseif args[i] == "--out"; out = args[i+1]; i += 2
        else push!(specs, args[i]); i += 1 end
    end
    isempty(specs) && error("give at least one ID[:tag]")
    nt = Threads.nthreads(:default)
    io = out === nothing ? nothing : open(out, "w")
    println(HDR); io === nothing || println(io, HDR)
    for spec in specs
        id, tag = occursin(':', spec) ? split(spec, ":") : (spec, "")
        if "static" in stages
            _, _, label = load_fit_seed(String(id), String(tag); makie = false)
            for (lab, b, k, fp, t) in static_rows(String(id), String(tag), label)
                line = @sprintf("%s\t%d\t%d\t%s\t%s\t%.4f\t0\t0", lab, b, nt, k, fp, t)
                println(line); io === nothing || (println(io, line); flush(io))
            end
        end
        if "map" in stages
            seed, _, label = load_fit_seed(String(id), String(tag); makie = false)
            for b in bases
                r = map_run(seed, UInt64(b))
                line = @sprintf("%s\t%d\t%d\tmap\t%s\t%.4f\t%d\t%d", label, b, nt, string(r.fp, base = 16), r.t, r.n_evals, r.n_modes)
                println(line); io === nothing || (println(io, line); flush(io))
            end
        end
    end
    io === nothing || close(io)
    out === nothing || compare(out, nt)
end

# Compare this run with every earlier result file made with another thread count.
function compare(out, nt)
    _, mine = read_rows(out)
    dir = dirname(out)
    others = [joinpath(dir, f) for f in readdir(dir) if endswith(f, ".tsv") && joinpath(dir, f) != out]
    any_other = false
    for path in others
        t2, theirs = read_rows(path)
        t2 == nt && continue
        any_other = true
        common = intersect(keys(mine), keys(theirs))
        isempty(common) && continue
        same = count(k -> mine[k][1] == theirs[k][1], common)
        @printf("\nvs %s (%d threads): fingerprints identical in %d of %d (fit, base, stage) rows\n", basename(path), t2, same, length(common))
        for stg in sort(unique(k[3] for k in common))
            ks = [k for k in common if k[3] == stg]
            ratio = [theirs[k][2] / mine[k][2] for k in ks]
            @printf("  %-14s wall ratio (other / this) median %.2f×, min %.2f×, max %.2f×  (%d rows)\n", stg, median(ratio), minimum(ratio), maximum(ratio), length(ks))
        end
        println("verdict (identical): ", same == length(common) ? "PASS (bit-identical)" : "FAIL (results depend on the thread count)")
    end
    any_other || println("\nno result file with another thread count in $dir yet; run again with a different --threads")
end

main(ARGS)
