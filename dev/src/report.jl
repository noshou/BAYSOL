# SPDX-License-Identifier: LGPL-3.0-or-later

# Parsing fitting-test runs into maps of numbers: `parse_log` reads a run log (`<ID>.LOG`,
# see `BAYSOL.writeLog`), the one file every tool looks at; `parse_report` reads a text
# report (`res*.txt`), which the revisions before the logs keep their results in, so
# `compare` can read them.
module Report

using OrderedCollections: OrderedDict

using ..Common

export Run, parse_log, parse_report, stage_notes, wall_ex

"""
A run: the values of one fitting-test run in `fields` (first-seen order of the keys, which
the TSV and CSV outputs follow) and the notes of its timing stages in `stage_notes`.
"""
struct Run
    fields::OrderedDict{Symbol,Any}
    stage_notes::Dict{String,String}
end

Base.getindex(r::Run, k::Symbol) = r.fields[k]
Base.get(r::Run, k::Symbol, default) = get(r.fields, k, default)
Base.haskey(r::Run, k::Symbol) = haskey(r.fields, k)
Base.keys(r::Run) = keys(r.fields)

# In a pattern, @N@ and @FLP@ are a number (one capture group), @NUM@ the same without a
# capture group (to skip a column), @QTY@ a number with an optional k (x1000) or M
# (x1000000) suffix (one capture group).
const TOKENS = ["@N@" => Common.NUM_RE, "@FLP@" => Common.NUM_RE,
    "@NUM@" => "[-+]?\\d+\\.?\\d*(?:[eE][-+]?\\d+)?",
    "@QTY@" => "([-+]?(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][-+]?\\d+)?[kM]?)"]

const RX_CACHE = Dict{Tuple{String,String},Regex}()

# The compiled pattern with its tokens replaced.
function rx(pat::AbstractString, flags::AbstractString = "(?m)")::Regex
    get!(RX_CACHE, (String(pat), String(flags))) do
        text = String(pat)
        for (token, replacement) in TOKENS
            text = replace(text, token => replacement)
        end
        Regex(flags * text)
    end
end

# The source text of a regex literal.
src(r::Regex) = r.pattern

# First capture group of `pat` in `text`, "" if absent.
function grab(text::AbstractString, pat)::String
    m = match(rx(pat isa Regex ? src(pat) : pat), text)
    (m === nothing || isempty(m.captures) || m.captures[1] === nothing) && return ""
    return String(m.captures[1])
end

# Java's `Math.round`: halves go up.
jround(x) = floor(x + 0.5)

"""
`'496.68k'` -> 496680.0, `'1.2M'` -> 1.2e6, rounded to 6 decimals (so 8.03k is exactly
8030.0, not 8029.999999999999).
"""
function qty(tok::AbstractString)::Float64
    scale = last(tok) == 'k' ? 1e3 : last(tok) == 'M' ? 1e6 : 1.0
    x = parse(Float64, replace(tok, r"[kM]+$" => ""))
    return jround(x * scale * 1e6) / 1e6
end

"`x` as an integer when it is a whole number."
whole(x) = x == floor(x) ? Int(x) : x

const REBIN_DROPPED_HEAD = raw"^rebin\s+= \d+ per channel: \d+ measured → "
const REBIN_DROPPED_TAIL = raw"\d+ fitted points \((\d+) non-positive dropped\)"

# The one-line quantities of a report as `key => pattern`.
const ENTRIES = Pair{Symbol,String}[
    :nAtoms        => raw"^nAtoms\s+= (\d+)",
    :lMax          => raw"^lMax\s+= (\d+)",
    :nQRaw         => raw"^nQRaw\s+= (\d+)",
    :nQ            => raw"^nQ\s+= (\d+)",
    :nSamples      => raw"^nSamples\s+= (\d+)",
    :nAdapt        => raw"^nAdapt\s+= (\d+)",
    :rngSeed       => raw"^rngSeed\s+= (\d+)",
    :dmax          => raw"^Dₘₐₓ\s+= @FLP@ Å",
    :channels      => raw"^channels\s+= @FLP@",
    :rebin_per_chn => raw"^rebin\s+= (\d+) per channel",
    :rebinMeasured => raw"^rebin\s+= \d+ per channel: (\d+) measured",
    :rebinFitted   => raw"^rebin\s+= \d+ per channel: \d+ measured → (\d+) fitted points",
    :rebin_dropped => REBIN_DROPPED_HEAD*REBIN_DROPPED_TAIL,
    :iterations    => raw"^iterations\s+= (\d+)",
    :accept        => raw"^meanAccept\s+= @FLP@",
    :depth         => raw"^treeDepth\s+= @FLP@",
    :depth_max     => raw"^treeDepth\s+=[^\n]*\(max (\d+)\)",
    :steps         => raw"^meanNSteps\s+= @FLP@",
    :ebfmi         => raw"^EBFMI\s+= @FLP@",
    :cavityFrac    => raw"^cavityFrac\s+= @FLP@",
    :sat           => raw"^exclVolSat\s+= (\w+)",
    :div           => raw"^divergenceRate\s+= @FLP@",
    :chainsPooled  => raw"^chains\s+= (\d+) pooled of \d+",
    :chains_total  => raw"^chains\s+= \d+ pooled of (\d+)",
    :rhatMax       => raw"^rhatMax\s+= @FLP@",
    :essMin        => raw"^essMin\s+= @FLP@",
    :essTailMin    => raw"^essTailMin\s+= @FLP@",
    :modes         => raw"^modes\s+= (\d+)",
    :optima        => raw"^optima\s+= (\d+) with mass",
    :lgdn_MAP      => raw"^logDensity\s+= @FLP@",
    :rho_e_MAP     => raw"^ρₑ\s+= @FLP@",
    :dro1_MAP      => raw"^δρ₁\s+= @FLP@",
    :dro2_MAP      => raw"^δρ₂\s+= @FLP@",
    :dro3_MAP      => raw"^δρ₃\s+= @FLP@",
    :scale_MAP     => raw"^scale\s+= @FLP@",
    :bkgrnd_MAP    => raw"^bkgrndCorr\s+= @FLP@",
    :excl_MAP      => raw"^exclVolCorr\s+= @FLP@",
    :chi2_MAP      => raw"^χ²\s+= @FLP@",
    :quantileLo    => raw"^=== Quantiles \((\d+)-\d+\) ===",
    :quantileHi    => raw"^=== Quantiles \(\d+-(\d+)\) ===",
    :wall          => raw"^wall clock.*\s@FLP@\s+100\.0",
    :static_build  => raw"^\s+static build\s+@FLP@",
    :resloveStruct => raw"^\s+resloveStruct\s+@FLP@",
    :components    => raw"^\s+components.*\s@FLP@\s*$",
    :compDwnld     => raw"^\s+components(?:[^\n]*\n\s*)?[^\n]*, (\d+) download\]",
    :struct_chk    => raw"^\s+structure checks.*\s@FLP@\s*$",
    :classify      => raw"^\s+classify.*\s@FLP@\s*$",
    :propka        => raw"^\s+propka.*\s@FLP@\s*$",
    :pdb2pqr       => raw"^\s+pdb2pqr.*\s@FLP@\s*$",
    :moded_hyd     => raw"^\s+modified nucleotide hydrogens.*\s@FLP@\s*$",
    :modedAaHyd    => raw"^\s+modified amino acid hydrogens.*\s@FLP@\s*$",
    :heavy_atoms   => raw"^\s+heavy atoms.*\s@FLP@\s*$",
    :loadMolecule  => raw"^\s+loadMolecule\s+@FLP@",
    :sasa          => raw"^\s+SASA\s+@FLP@",
    :shannon       => raw"^\s+shannon \(diameter, binning\)\s+@FLP@",
    :fwd           => raw"^\s+forwardCache\s+@FLP@",
    :vac_excl      => raw"^\s+vacuum \+ excluded volume \(vols \+ B_lm\)\s+@FLP@",
    :hydration     => raw"^\s+hydration \(B_lm\)\s+@FLP@",
    :gram_rm       => raw"^\s+Gram \+ rM\s+@FLP@",
    :seed_fitting  => raw"^\s+seed_(?:fitting|sampler) \(priors, WLS\)\s+@FLP@",
    :sampling      => raw"^\s+sampling\s+@FLP@",
    :map_s         => raw"^\s+MAP search \+ whitening .*\)\s+@FLP@\s*$",
    :nuts_setup    => raw"^\s+NUTS setup \(.*\)\s+@FLP@\s*$",
    :nuts          => raw"^\s+NUTS\s+\(.*\)\s+@FLP@\s*$",
    :reprofile     => raw"^\s+per-draw c1 re-profile.*\)\s+@FLP@\s*$",
    :map_quantiles => raw"^\s+MAP \+ quantiles\s+@FLP@",
    :report_write  => raw"^\s+report write\s+@FLP@",
    :unaccounted   => raw"^\s+unaccounted\s+@FLP@",
    :gc            => raw"^GC: @FLP@",
    :fit_timing    => raw"^fit timing\s+= @FLP@",
    :plot_timing   => raw"^plot timing\s+= @FLP@",
    :mapStartsOk   => raw"^\s+MAP search \+ whitening \((\d+)/\d+ starts",
    :mapStartsTot  => raw"^\s+MAP search \+ whitening \(\d+/(\d+) starts",
    :mapModes      => raw"^\s+MAP search \+ whitening \(\d+/\d+ starts, (\d+) modes?",
    :nuts_iters    => raw"^\s+NUTS\s+\(@QTY@ iters",
    :leapfrog      => raw"^\s+NUTS\s+\(\S+ iters, @QTY@ leapfrog",
    :ms_per_step   => raw"^\s+NUTS\s+\(\S+ iters, \S+ leapfrog, @QTY@ ms/step\)",
    :draws         => raw"^\s+per-draw c1 re-profile.*\((\d+) draws\)",
]

# The parameter rows: (prefix, label).
const PARAMS = [
    (:lgdn, "logDensity"),
    (:rho_e, "ρₑ"),
    (:dro1, "δρ₁"),
    (:dro2, "δρ₂"),
    (:dro3, "δρ₃"),
    (:scale, "scale"),
    (:bkgrnd, "bkgrndCorr"),
    (:excl, "exclVolCorr"),
    (:chi2, "χ²"),
]

# `key => pattern` pairs for the columns `cols` of the table rows labelled `<label>_<tag>`
# of the parameters `ps`: column i is the (i+1)-th number after the label.
function columns(ps, tag, cols)
    return Pair{Symbol,String}[
        Symbol(string(p), "_", col) =>
            "^" * label * "_" * tag * "\\s+" *
            repeat("@NUM@\\s+", i - 1) * "@FLP@"
        for (p, label) in ps for (i, col) in enumerate(cols)
    ]
end

const TABLE_ENTRIES = vcat(
    columns(PARAMS, "Q", ["QUANT_LO", "QUANT_HI", "BOUND_LO", "BOUND_HI"]),
    columns(PARAMS[2:5], "Z", ["Z_MAP", "Z_QUANT_LO", "Z_QUANT_HI"]))

# Later passes re-read lines the ones above already took, so a key set twice keeps its
# first position and takes the last value.
const SAMPLER_QUALITY = Pair{Symbol,String}[
    :div    => raw"^divergenceRate = @N@",
    :steps  => raw"^meanNSteps\s+= @N@",
    :depth  => raw"^treeDepth\s+= @N@",
    :accept => raw"^meanAccept\s+= @N@",
    :ebfmi  => raw"^EBFMI\s+= @N@",
]

const FIT_QUALITY = Pair{Symbol,String}[
    :chi2 => raw"^χ²\s+= @N@",
    :c1   => raw"^exclVolCorr\s+= @N@",
    :sat  => raw"^exclVolSat\s+= (\w+)",
    :rhoE => raw"^ρₑ\s+= @N@",
    :d1   => raw"^δρ₁\s+= @N@",
    :d2   => raw"^δρ₂\s+= @N@",
    :d3   => raw"^δρ₃\s+= @N@",
]

const TIMING = Pair{Symbol,String}[
    :wall      => raw"^wall clock.*\s@N@\s+100\.0",
    :fwd       => raw"^\s+forwardCache\s+@N@",
    :propka    => raw"^\s+propka.*\s@N@\s*$",
    :pdb2pqr   => raw"^\s+pdb2pqr.*\s@N@\s*$",
    :map_s     => raw"^\s+MAP search \+ whitening .*\)\s+@N@\s*$",
    :reprofile => raw"^\s+per-draw c1 re-profile.*\)\s+@N@\s*$",
    :gc        => raw"^GC: @N@",
]

const N_MODES_RE = raw"MAP search \+ whitening \(\d+/\d+ starts, (\d+) modes?"

const SHARE_RE = raw"^mode_\d+\s+= chains [\d,]+, share ([\d.]+(?:e[-+]?\d+)?)"

# "NUTS (2k iters, 496.68k leapfrog, 0.2 ms/step) <seconds>"
const NUTS_RE =
    raw"NUTS  \(([\d.]+k?) iters, ([\d.]+[kM]?) leapfrog, ([\d.]+) ms/step\)\s+@N@"

# The map being built, with its keys in first-seen order.
put!(st::OrderedDict{Symbol,Any}, k::Symbol, v) = (st[k] = v; st)
puts!(st, kvs) = (foreach(kv -> put!(st, kv[1], kv[2]), kvs); st)

# `(key, value)` pairs from a `key => pattern` list.
grabs(text, kv) = [(k, grab(text, pat)) for (k, pat) in kv]

# The largest (`pick = max`) or smallest value among the strings `shares`, as a number, ""
# if there are none.
function by_value(pick, shares)
    isempty(shares) && return ""
    return as_number(shares[pick(parse.(Float64, shares))])
end

# The notes of the timing table.
const NOTE_RE = r"^\s+([^\[\n]*?)\s*(\[.*\])\s"
const NOTE_LINE_RE = r"^\s+(\[.*\])\s*$"
const STAGE_NUMBERS_RE = r"(\s+[-+]?\d[\d.]*(?:e[-+]?\d+)?){1,2}(\s+\([\d.]+\))?\s*$"

"""
    stage_notes(text) -> Dict{String,String}

The notes of the stages in the `=== Timing ===` section of `text`, as a map from stage
name to note (`"classify" => "[nucleic: AMBER, titration none]"`), in either layout; a
note wrapped over several lines is joined with single spaces.
"""
function stage_notes(text::AbstractString)::Dict{String,String}
    m = match(r"(?ms)^=== Timing ===[^\n]*\n(.*)", text)
    section = if m !== nothing
        m[1]
    elseif !occursin("=== ", text)
        # a timing file is the table alone, below its column-label line
        m2 = match(r"(?s)\A[^\n]*\n(.*)", text)
        m2 === nothing ? nothing : m2[1]
    else
        nothing
    end
    notes = Dict{String,String}()
    prev = nothing
    open = nothing  # (name, text) of a note wrapped over several lines
    for line in split_lines(something(section, ""))
        own = match(NOTE_LINE_RE, line)
        nn = match(NOTE_RE, line * " ")
        if open !== nothing
            # the lines of a wrapped note up to the one that closes it
            joined = open[2] * " " * strip(line)
            if endswith(strip(line), "]")
                notes[open[1]] = joined
                prev = nothing
                open = nothing
            else
                open = (open[1], joined)
            end
        elseif prev !== nothing && occursin(r"^\s+\[", line) && own === nothing
            open = (prev, String(strip(line)))
        elseif own !== nothing && prev !== nothing
            notes[prev] = own[1]
            prev = nothing
        elseif nn !== nothing && own === nothing
            notes[nn[1]] = nn[2]
            prev = nothing
        else
            prev = String(strip(replace(line, STAGE_NUMBERS_RE => "")))
        end
    end
    return notes
end

# A number from the string `v`, 0 if it is empty.
or_zero(v) = isempty(v) ? 0 : as_number(v)

"""
    wall_ex(m) -> Union{String,Number}

The wall clock of the run map `m` without the startup (before `seedModel`), the
external-tool time (PROPKA and every `pdb2pqr*` stage, which depend on the cache, and a
component download) and without the plotting (`plot timing`, which older reports lack: the
fit is what is compared), the convention for every comparison; "" without a wall clock.
"""
function wall_ex(m)
    g(k) = get(m, k, nothing)
    wall = g(:wall)
    (wall === nothing || (wall isa AbstractString && isempty(wall))) && return ""
    gz(k) = (v = g(k); v === nothing ? 0 : or_zero(v isa AbstractString ? v : v))
    download = gz(:compDwnld)
    return as_number(wall) - gz(:startup) - gz(:propka) - gz(:pdb2pqr) -
           (download > 0 ? gz(:components) : 0) - gz(:plot_timing)
end

"""
    parse_report(text) -> Run

The numbers of one report as a run; a key is "" where a revision's format lacks it.
"""
function parse_report(text::AbstractString)::Run
    g(pat) = grab(text, pat)
    # a quantity with a k or M suffix is stored as the plain number
    function quantity((k, pat))
        v = g(pat)
        return (k, (occursin("@QTY@", pat) && !isempty(v)) ? whole(qty(v)) : v)
    end
    # the mass shares of the posterior modes (each has a `mode_<k>` line)
    shares = String[m[1] for m in eachmatch(rx(SHARE_RE), text)]
    # the NUTS line: groups are iterations, leapfrog steps, ms/step, seconds
    nuts = match(rx(NUTS_RE), text)
    leap, ms, secs =
        nuts === nothing ? (nothing, nothing, nothing) :
        (nuts[2], nuts[3], nuts[4])
    # the z-score of the MAP δρ₃ from the prior: the number after its row label
    zm = match(r"(?ms)=== Standard deviations from prior.*?^δρ₃", text)
    z3 =
        zm === nothing ? "" :
        grab(text[(zm.offset+ncodeunits(zm.match)):end], raw"\A\s*@N@")
    st = OrderedDict{Symbol,Any}()
    puts!(st, quantity.(ENTRIES))
    puts!(st, quantity.(TABLE_ENTRIES))
    puts!(
        st,
        [(:modeShareMax, by_value(argmax, shares)),
            (:modeShareMin, by_value(argmin, shares)),
            # chains that were not pooled (a `chain_dropped` line each)
            (
                :chains_dropped,
                length(collect(eachmatch(rx(raw"^chain_dropped\s+="), text))),
            )],
    )
    puts!(st, grabs(text, SAMPLER_QUALITY))
    puts!(st, grabs(text, FIT_QUALITY))
    # the Shannon-binned fit's χ² on the measured grid (reports since Shannon binning
    # only), and the χ² every comparison uses: that one when there is one, else the
    # (unbinned) fit's own
    raw_chi2 = g(raw"^measured grid\s+lag-1.*χ²_red\s+@N@")
    puts!(
        st,
        [(:chi2_raw, raw_chi2), (:chi2_cmp, isempty(raw_chi2) ? st[:chi2] : raw_chi2)],
    )
    puts!(st, grabs(text, TIMING))
    puts!(
        st,
        [(:leapfrog, leap === nothing ? "" : qty(leap)), (:msStep, something(ms, "")),
            (:nuts, something(secs, "")),
            # reports since the `_Z` row labels have it in its own key
            (:z3, isempty(z3) ? get(st, :dro3_Z_MAP, "") : z3),
            # number of distinct local optima the MAP search found
            (:nModes, g(N_MODES_RE))],
    )
    put!(st, :wall_ex, wall_ex(st))
    return Run(st, stage_notes(text))
end

# --- the run log

# The key of the run map <- the row of a log section (its first value), in the order the
# map lists them.
const LOG_KEYS = [(:nAtoms, "nAtoms"), (:lMax, "lmax"), (:dmax, "dmax"),
    (:nQRaw, "nQRaw"), (:nQ, "nQ"), (:nSamples, "nSamples"),
    (:nAdapt, "nAdapt"), (:rngSeed, "rngSeed"), (:baysol, "baysol"),
    (:structure, "structure"), (:refChi2, "refChi2"), (:chi2, "chi2"),
    (:chi2_MAP, "chi2"), (:chi2_cmp, "chi2"), (:rhoE, "rhoE"), (:rho_e_MAP, "rhoE"),
    (:d1, "deltaRho1"), (:dro1_MAP, "deltaRho1"), (:d2, "deltaRho2"),
    (:dro2_MAP, "deltaRho2"), (:d3, "deltaRho3"), (:dro3_MAP, "deltaRho3"),
    (:scale_MAP, "scale"), (:bkgrnd_MAP, "bkgrndCorr"), (:c1, "c1"), (:excl_MAP, "c1"),
    (:z3, "zDeltaRho3"), (:dro3_Z_MAP, "zDeltaRho3"),
    (:cavityFrac, "cavityFrac"),
    (:div, "divergenceRate"), (:nDivergent, "nDivergent"), (:rhatMax, "rhatMax"),
    (:essMin, "essMin"), (:essTailMin, "essTailMin"), (:ebfmi, "ebfmi"),
    (:accept, "meanAccept"), (:depth, "treeDepthAvg"),
    (:depth_max, "treeDepthMax"),
    (:steps, "meanNSteps"), (:iterations, "iterations"), (:leapfrog, "leapfrog"),
    (:msStep, "msStep"), (:ms_per_step, "msStep"), (:chainsPooled, "chainsPooled"),
    (:chains_total, "chainsRun"), (:modes, "modes"), (:optima, "optima"),
    (:modeShareMax, "modeShareMax"), (:modeShareMin, "modeShareMin"),
    (:mapStartsOk, "mapStartsOk"), (:mapStartsTot, "mapStartsTot"),
    (:mapModes, "mapModes"), (:nModes, "mapModes"),
    (:compDwnld, "compDwnld")]

# The key of the run map <- the stage of the timing table of a log section (the stage's
# name without what it carries in parentheses or after a comma; the seconds).
const LOG_STAGES = Dict("wall clock" => :wall, "startup" => :startup,
    "static build" => :static_build, "resloveStruct" => :resloveStruct,
    "components" => :components, "structure checks" => :struct_chk,
    "classify" => :classify, "propka" => :propka, "pdb2pqr" => :pdb2pqr,
    "modified nucleotide hydrogens" => :moded_hyd,
    "modified amino acid hydrogens" => :modedAaHyd,
    "heavy atoms" => :heavy_atoms, "loadMolecule" => :loadMolecule, "SASA" => :sasa,
    "shannon" => :shannon, "forwardCache" => :fwd,
    "vacuum + excluded volume" => :vac_excl, "hydration" => :hydration,
    "Gram + rM" => :gram_rm, "seedSampler" => :seed_fitting, "sampling" => :sampling,
    "MAP search + whitening" => :map_s, "NUTS setup" => :nuts_setup, "NUTS" => :nuts,
    "optima from the draws" => :optima_s,
    "per-draw c1 re-profile + curves" => :reprofile,
    "MAP + quantiles" => :map_quantiles,
    "plotting" => :plotting, "report write" => :report_write,
    "unaccounted" => :unaccounted)

# The order the stage keys come in a run's column list (the columns of the TSV output).
const LOG_STAGE_ORDER = [:sasa, :nuts, :reprofile, :gram_rm, :report_write, :pdb2pqr,
    :vac_excl, :struct_chk, :fwd, :moded_hyd, :startup,
    :heavy_atoms,
    :modedAaHyd, :map_quantiles, :unaccounted, :optima_s, :map_s,
    :classify,
    :shannon, :hydration, :sampling, :propka, :plotting, :resloveStruct,
    :seed_fitting,
    :components, :loadMolecule, :wall, :nuts_setup, :static_build]

# A row of the timing table: indent, stage, seconds, % wall, (JIT), (GC), then the notes,
# if there are any, after two spaces.
const TIMING_ROW_RE =
    r"^( *)(\S.*?)\s+(-?\d\S*)\s+(-?\d\S*)\s+\((\S+)\)\s+\((\S+)\)(?:\s{2}(.*?))?\s*$"

# What a log section's timing table (its lines) says: `(kvs, notes)`.
function timing_values(lines)
    by_stage = Dict{String,Tuple{String,String}}()
    for l in lines
        m = match(TIMING_ROW_RE, l)
        m === nothing && continue
        haskey(by_stage, m[2]) && continue
        by_stage[m[2]] = (m[3], something(m[7], ""))
    end
    note(stage) = haskey(by_stage, stage) ? by_stage[stage][2] : ""
    nuts = match(r"([\d.]+[kM]?) iters, ([\d.]+[kM]?) leapfrog, ([\d.]+) ms/step",
        note("NUTS"))
    leap, ms = nuts === nothing ? (nothing, nothing) : (nuts[2], nuts[3])
    starts = match(r"(\d+)/(\d+) starts, (\d+) modes?", note("MAP search + whitening"))
    ok, total, modes =
        starts === nothing ? (nothing, nothing, nothing) :
        (starts[1], starts[2], starts[3])
    line(re) =
        (i = findfirst(l -> occursin(re, l), lines); i === nothing ? nothing : lines[i])
    function labelled(re, pat)
        l = line(re)
        return l === nothing ? "" : grab(l, pat)
    end
    kvs = Dict{Symbol,Any}()
    for (stage, k) in LOG_STAGES
        haskey(by_stage, stage) && (kvs[k] = by_stage[stage][1])
    end
    kvs[:gc] = labelled(r"^GC: ", raw"^GC: @N@")
    kvs[:fit_timing] = labelled(r"^fit timing", raw"^fit timing\s+= @N@")
    kvs[:plot_timing] = labelled(r"^plot timing", raw"^plot timing\s+= @N@")
    kvs[:leapfrog_label] = leap === nothing ? "" : whole(qty(leap))
    kvs[:ms_step_label] = something(ms, "")
    kvs[:map_starts_ok_label] = something(ok, "")
    kvs[:map_starts_tot_label] = something(total, "")
    kvs[:map_modes_label] = something(modes, "")
    dm = match(r"(\d+) draws", note("per-draw c1 re-profile + curves"))
    kvs[:draws] = dm === nothing ? "" : dm[1]
    notes = Dict{String,String}(
        "$stage" => "[" * n * "]"
        for (stage, (_, n)) in by_stage if !isempty(n)
    )
    return kvs, notes
end

# The sections of a log's text, in file order: `(title, lines)`, the lines of the section
# (the stamp before the first section is in none).
function log_sections(text)
    out = Tuple{String,Vector{String}}[]
    for line in split_lines(text)
        m = match(r"^=== (.*) ===$", line)
        if m !== nothing
            push!(out, (String(m[1]), String[]))
        elseif !isempty(out)
            push!(out[end][2], line)
        end
    end
    return out
end

# The lines of a section split at its `--- name ---` markers: the stats, timing and
# machine blocks; the lines before the first marker are the stats.
function split_blocks(lines)
    out = Dict{Symbol,Vector{String}}()
    cur = :stats
    for line in lines
        m = match(r"^--- (\w+) ---$", line)
        if m !== nothing
            cur = Symbol(m[1])
        else
            push!(get!(out, cur, String[]), line)
        end
    end
    return out
end

# The rows `name<tab>value` of lines, as name => [value ...] (the cells trimmed; blank
# lines skipped).
function rowsOf(lines)
    rows = Dict{String,Vector{String}}()
    for l in lines
        isblank(l) && continue
        cells = String.(split(l, '\t'; keepempty = true))
        while length(cells) > 1 && isempty(last(cells))
            pop!(cells)
        end
        cells = strip.(cells)
        rows[first(cells)] = String.(cells[2:end])
    end
    return rows
end

isblank(s) = all(isspace, s)

# The run map of one section's lines.
function log_run(lines)
    blocks = split_blocks(lines)
    m = merge(rowsOf(get(blocks, :stats, String[])),
        rowsOf(get(blocks, :machine, String[])))
    v(k) = haskey(m, k) && !isempty(m[k]) ? m[k][1] : ""
    kvs, notes = timing_values(get(blocks, :timing, String[]))
    base = OrderedDict{Symbol,Any}(k => v(lk) for (k, lk) in LOG_KEYS)
    for k in LOG_STAGE_ORDER
        base[k] = get(kvs, k, "")
    end
    for k in (:gc, :fit_timing, :plot_timing, :draws)
        base[k] = kvs[k]
    end
    # the leapfrog steps, ms/step and MAP search of the notes, where the stats rows do not
    # have them
    for (k, lab) in ((:leapfrog, :leapfrog_label), (:msStep, :ms_step_label),
        (:ms_per_step, :ms_step_label), (:mapStartsOk, :map_starts_ok_label),
        (:mapStartsTot, :map_starts_tot_label), (:mapModes, :map_modes_label),
        (:nModes, :map_modes_label))
        isempty(get(base, k, "")) && (base[k] = get(kvs, lab, ""))
    end
    # the flag of c1 on its bound, as the text reports wrote it
    c1Sat = v("c1Sat")
    base[:sat] = c1Sat == "" ? "" : c1Sat == "0" ? "false" : "true"
    base[:wall_ex] = wall_ex(base)
    return Run(base, notes)
end

"""
    parse_log(text) -> Vector{Tuple{String,Run}}

The runs of the text of a run log: a vector of `(title, run)`, in file order.
"""
function parse_log(text::AbstractString)
    return Tuple{String,Run}[
        (title, log_run(lines)) for (title, lines) in log_sections(text)
    ]
end

end
