# SPDX-License-Identifier: LGPL-3.0-or-later

# runProject: the fit of a whole project (the terminal interface's, or a plain command
# line's) in ONE process, and the run folder it leaves. Julia knows nothing of the
# terminal interface: it reads the files of the project, writes plain files into
# `<project>/runs/<stamp>/` and prints; the interface wraps that (prompts, live view,
# archive, viewers). The layout and the rules of concurrency (one writer of `run.json`,
# a heartbeat, a snapshot of the inputs, a folder claimed with a non-recursive mkdir) are
# the ones of notes/run-design.md.

module BAYSOLRun

using BAYSOL
# JSON3 and SHA are dependencies of BAYSOL; they are taken through the modules that use
# them, so this file runs in any environment that holds BAYSOL (the repository's, or the
# one of the tests), whether or not it lists them itself.
using BAYSOL.BulkElectronDensity: BulkElectronDensity, JSON3, Solute, ρₑ
using BAYSOL.MolecularStructure: MolecularStructure, SHA
using BAYSOL.Inference: Inference
using BAYSOL.PhysicalConstants: energyEv

using Printf: @sprintf

# What the run needs of the Pipeline module (the fit and its outputs; the project folder,
# the settings files and the run folder are the files of this module). BAYSOL exports
# nothing, so each name is imported from the module that defines it.
import BAYSOL.Pipeline: seedModel, runModel, results, compareResults, writeLog,
    printSummary, PlotStyle, Reference, InvalidSettingsError, seedKeywords,
    runKeywords, resultsKeywords, SETTING_KEYWORDS, REFERENCE_EXTENSIONS,
    FIGURES_COMPILE, FIGURES_COMPILER, FIGURES_DIR, FIGURES_FORMATS, FIGURES_TEX,
    TABLE_DIR, TABLE_SIGFIGS, VAL_SIGMA, N_ADAPT, N_DRAWS, PLOT_COMPARE,
    _SETTINGS_KEYWORD_HINT, _applyKeywords!, _bad, _checkedValue, _isNullable,
    _logCell, _logRevision, _plainText, _logStamp, _logVersion, _need, _readReference,
    _readReferences, _relationProblems, _settingDefault, _settingInput,
    _settingNames, _tabLines, _textWidth, _updateLog

# The settings files, the buffer and the references of single models: the other files of
# this module (`settings-file.jl` first, the others read JSON with its reader).
include("settings-file.jl")
include("buffer.jl")
include("model-references.jl")

# ---------------------------------------------------------------------------
#          guardrails of the run folder (the interface relies on these)
# ---------------------------------------------------------------------------

"The folder of a project that holds its runs, `<project>/runs/`."
const RUN_FOLDER = "runs"

"The seconds between two rewrites of the heartbeat in `run.json`."
const RUN_HEARTBEAT_S = 10.0

"""
The age, in seconds, of a heartbeat from which a `running` run no longer counts as live
(the interface and the plain command line agree on it).
"""
const RUN_STALE_S = 60.0

"The ways of showing a run: `:cli` prints the plots, `:tui` leaves them to `plots.txt`."
const RUN_UI = (:cli, :tui)

"""
The files of a project that a run takes a snapshot of (the models are listed, not copied);
`model-settings.json` and `model-references.json` are optional.
"""
const RUN_INPUTS = (
    "settings.json", "buffer.json", "data.tsv", "data.json", MODEL_SETTINGS_FILE,
    MODEL_REFERENCES_FILE,
)

"""
The folder of a project that holds its reference fits (`<project>/reference-fit/`, the
depositor's curves): copied into the run folder like the other inputs (each file as
`reference-fit-<file>`, the run's folder is flat), and read from there.
"""
const RUN_REFERENCES = "reference-fit"

"The name of the combined comparison's files in a run (`compare.tsv`, `compare-*.tex`)."
const RUN_COMPARE = "compare"

"The name of the run's own log, `run.LOG`: no model may take it."
const RUN_LOG_NAME = "run"

"The names a model may not take, because the run's own files have them."
const RUN_RESERVED_NAMES = (RUN_LOG_NAME, RUN_COMPARE)

"The prefix of the reference fits in a run folder (`reference-fit-<file>`)."
const RUN_REFERENCE_PREFIX = RUN_REFERENCES * "-"

# ---------------------------------------------------------------------------
#                          time and the run folder's name, no Dates
# ---------------------------------------------------------------------------

# The civil date and time (UTC) of the Unix time `t` seconds, by the days-from-civil
# algorithm (proleptic Gregorian), so that no package is needed for a stamp.
function _utcFields(t::Real)
    s = floor(Int, t)
    days, secs = fldmod(s, 86400)
    z = days + 719468
    era = fld(z, 146097)
    doe = z - era * 146097
    yoe = (doe - doe ÷ 1460 + doe ÷ 36524 - doe ÷ 146096) ÷ 365
    doy = doe - (365 * yoe + yoe ÷ 4 - yoe ÷ 100)
    mp = (5 * doy + 2) ÷ 153
    d = doy - (153 * mp + 2) ÷ 5 + 1
    m = mp < 10 ? mp + 3 : mp - 9
    y = yoe + era * 400 + (m <= 2 ? 1 : 0)
    return (y, m, d, secs ÷ 3600, (secs % 3600) ÷ 60, secs % 60)
end

# The Unix time of a UTC date and time (the inverse of `_utcFields`).
function _unixTime(y, m, d, H, M, S)
    y -= m <= 2 ? 1 : 0
    era = fld(y, 400)
    yoe = y - era * 400
    doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) ÷ 5 + d - 1
    doe = yoe * 365 + yoe ÷ 4 - yoe ÷ 100 + doy
    return (era * 146097 + doe - 719468) * 86400 + H * 3600 + M * 60 + S
end

"""
The offset from UTC, in seconds (east positive), of this machine's time zone at the Unix
time `t`. It is the local civil time (`Libc.TmStruct`, which reads the zone and its
daylight saving, on Linux, macOS and Windows alike: `%z` of `strftime` is a zone NAME on
Windows) taken as if it were UTC, minus `t`. macOS and Windows are untested.

# Returns
- The offset in seconds, such as `-18000` for UTC-05:00.

# Exceptions
- None.
"""
function _localOffset(t::Real)
    tm = Libc.TmStruct(floor(Int, t))
    return _unixTime(tm.year + 1900, tm.month + 1, tm.mday, tm.hour, tm.min, tm.sec) -
           floor(Int, t)
end

# `text` as a zone label: whitespace, underscores and hyphens removed, kept only when what
# is left is 3 or more Unicode letters (NFC-normalised); `nothing` otherwise. A mixed form
# such as `GMT+5` or `+03` is no label: keeping its letters would show a stand-in.
function _lettersLabel(text::AbstractString)
    s = Base.Unicode.normalize(replace(text, r"[\s_-]" => ""), :NFC)
    return length(s) >= 3 && all(isletter, s) ? s : nothing
end

"""
The name of this machine's time zone for a label: the last path segment of the `TZ`
environment variable (`America/Sao_Paulo` is `SaoPaulo`) when it is set, else of the
target of the `/etc/localtime` link (`.../zoneinfo/Asia/Kolkata` is `Kolkata`), with the
underscores removed. macOS and Windows untested (Windows has neither).

# Returns
- The name, or `nothing` when the zone has no name made of letters.

# Exceptions
- None.
"""
function _zoneName()
    tz = get(ENV, "TZ", "")
    path = if !isempty(tz)
        lstrip(tz, ':')
    else
        try
            realpath("/etc/localtime")
        catch
            ""
        end
    end
    isempty(path) && return nothing
    return _lettersLabel(String(last(split(path, '/'))))
end

"""
The label of a time zone for a run folder name, from the name the platform gives
(`Libc.strftime("%Z", t)`): that name as it is (Unicode letters kept, whitespace removed,
NFC) when it is made of 3 or more letters (`EST`, `CEST`, Windows `Eastern Standard Time`
as `EasternStandardTime`); otherwise (a numeric form such as `+03`, `GMT-5`, nothing) the
zone's own name from `zone` ([`_zoneName`](@ref): `TZ` or the `/etc/localtime` link, so
`Istanbul`); the last resort is `LOCAL`. `GMT` and `UTC` are never a stand-in: they are
the label only of a zone whose platform name is that. The label is only a label: the
parser reads the instant from the time fields and the offset. This is the ONE definition
here (the interface has `zoneLabel` in `tui/src/store/projects.ts`, fed by tz libraries;
this one uses the standard library alone, no time-zone package).

# Returns
- The label, 3 or more Unicode letters.

# Exceptions
- None.
"""
function _zoneLabel(
    name::AbstractString,
    zone::Union{Nothing,AbstractString} = _zoneName(),
)
    label = _lettersLabel(name)
    label === nothing || return label
    zone === nothing || (label = _lettersLabel(zone)) === nothing || return label
    return "LOCAL"
end

# The label of this machine's time zone at the Unix time `t` (macOS and Windows untested).
_localZone(t::Real) = _zoneLabel(Libc.strftime("%Z", floor(Int, t)))

"""
The name of a run folder, `HH-MM-SS-mmm_TZ_±HHMM_YYYY-MM-DD`: the local wall-clock time
of the Unix time `t` (seconds, to the millisecond), the zone's label
(`_zoneLabel`), its offset from UTC and the local date in ISO order, e.g.
`23-35-29-123_EST_-0500_2026-11-07`. No colons, spaces or slashes (safe as a file name
on Windows, macOS and Linux). This is the ONE definition of the name; the interface has
the same one (`runStamp` in `tui/src/store/projects.ts`). `offset` (seconds east of UTC)
and `zone` are the machine's unless given, which keeps the format testable in any zone.

# Returns
- The name.

# Exceptions
- None.
"""
function _runStamp(
    t::Real,
    offset::Integer = _localOffset(t),
    zone::AbstractString = _localZone(t),
)
    ms = round(Int, t * 1000)
    y, mo, d, H, M, S = _utcFields(fld(ms, 1000) + offset)
    sign = offset < 0 ? '-' : '+'
    hh, mm = divrem(abs(offset) ÷ 60, 60)
    return @sprintf(
        "%02d-%02d-%02d-%03d_%s_%c%02d%02d_%04d-%02d-%02d",
        H, M, S, mod(ms, 1000), zone, sign, hh, mm, y, mo, d
    )
end

# The name of `_runStamp`: time, millisecond, zone
# label (3 or more Unicode letters), offset (sign, HHMM), date.
const RUN_STAMP_RE =
    r"^(\d\d)-(\d\d)-(\d\d)-(\d{3})_\p{L}{3,}_([+-])(\d\d)(\d\d)_(\d{4})-(\d\d)-(\d\d)$"

"""
The Unix time, in whole milliseconds, a run folder name denotes: the name of the format
of [`_runStamp`](@ref) (local time minus its offset; the zone label is opaque, any
3 or more Unicode letters, NFC-normalised before the match). Anything else, an impossible
date or time included, is no stamp.

# Returns
- The milliseconds since the Unix epoch, or `nothing` when `s` is not such a name.

# Exceptions
- None.
"""
function _parseRunStamp(s)
    s isa AbstractString || return nothing
    s = Base.Unicode.normalize(s, :NFC)    # macOS may return a name decomposed
    m = match(RUN_STAMP_RE, s)
    m === nothing && return nothing
    c = m.captures
    H, M, S, ms, oh, om, y, mo, d =
        (parse(Int, c[i]) for i in (1, 2, 3, 4, 6, 7, 8, 9, 10))
    (H < 24 && M < 60 && S < 60 && oh < 24 && om < 60) || return nothing
    _validDate(y, mo, d) || return nothing
    offset = (oh * 60 + om) * 60 * (c[5] == "-" ? -1 : 1)
    return (_unixTime(y, mo, d, H, M, S) - offset) * 1000 + ms
end

# Whether year `y`, month `m`, day `d` is a day of the calendar (the round trip of the
# days-from-civil algorithm gives it back).
function _validDate(y, m, d)
    (1 <= m <= 12 && d >= 1) || return false
    return _utcFields(_unixTime(y, m, d, 0, 0, 0))[1:3] == (y, m, d)
end

"The UTC time `t` (Unix seconds) as `yyyy-MM-ddTHH:mm:ssZ`, the way `run.json` keeps times."
_isoUtc(t::Real) = @sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", _utcFields(t)...)

"The Unix time of an `_isoUtc` string, `nothing` if `s` is not one."
function _parseIsoUtc(s)
    s isa AbstractString || return nothing
    m = match(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z$", s)
    m === nothing && return nothing
    return Float64(_unixTime((parse(Int, c) for c in m.captures)...))
end

# ---------------------------------------------------------------------------
#                               JSON files, atomic
# ---------------------------------------------------------------------------

"""
Writes `value` as pretty JSON to `path` through a temporary file in the same folder that is
then renamed, so a reader sees the old file or the new one and never half of one.
"""
function _writeJsonAtomic(path::AbstractString, value)
    tmp = string(path, ".tmp.", getpid())
    open(tmp, "w") do io
        JSON3.pretty(io, value)
        println(io)
    end
    mv(tmp, path; force = true)
    return String(path)
end

# ---------------------------------------------------------------------------
#                           what a run knows about itself
# ---------------------------------------------------------------------------

"One model of a run: where it is, what it was, and how it went."
mutable struct _ModelRec
    const name::String
    const path::String
    const size::Int
    const sha256::String
    status::String          # pending | running | done | failed | aborted | skipped
    seconds::Union{Nothing,Float64}
    error::Union{Nothing,String}
    # the terminal plots at the other sizes: `(file, width, rows)` each (`:tui` runs)
    plotSizes::Vector{NamedTuple}
    # the settings this model was given of its own (`model-settings.json`), their names
    overrides::Vector{String}
    # the files of the model in the run folder (`<model>.xlsx`, the `.tex` figures, ...)
    files::Vector{String}
end

function _ModelRec(name, path, size, sha256, status, seconds, error)
    return _ModelRec(
        name, path, size, sha256, status, seconds, error, NamedTuple[], String[],
        String[],
    )
end

"""
The state of one run, shared by the loop, the heartbeat and the abort paths: every change
and every write of `run.json` happens under `lock`.
"""
mutable struct _RunState
    const dir::String
    const project::String
    const ui::Symbol
    const started::Float64
    const lock::ReentrantLock
    const models::Vector{_ModelRec}
    const errors::Vector{String}
    rngSeed::Union{Nothing,Int}
    status::String
    ended::Union{Nothing,Float64}
    finished::Bool
    abortRequested::Bool
    logio::Union{Nothing,IO}
    # what became of the comparison; nothing: none made
    compare::Union{Nothing,NamedTuple}
end

"The `run.json` of a state, as a named tuple (the order of its keys is the file's)."
function _runJson(st::_RunState)
    nowS = time()
    done = st.ended === nothing ? nowS : st.ended
    return (;
        schema = 1,
        status = st.status,
        pid = getpid(),
        host = gethostname(),
        ui = String(st.ui),
        project = st.project,
        started = _isoUtc(st.started),
        heartbeat = _isoUtc(nowS),
        ended = st.ended === nothing ? nothing : _isoUtc(st.ended),
        julia = string(VERSION),
        baysol = _logVersion(),
        rngSeed = st.rngSeed,
        models = [
            (; name = m.name, path = m.path, size = m.size, sha256 = m.sha256,
                status = m.status, seconds = m.seconds, error = m.error,
                plotSizes = m.plotSizes, overrides = m.overrides, files = m.files)
            for m in st.models
        ],
        timings = (; seconds = done - st.started,
            models = Dict(m.name => m.seconds for m in st.models if m.seconds !== nothing)),
        (st.compare === nothing ? (;) : (; compare = st.compare))...,
    )
end

"Rewrites `run.json` (atomically, under the state's lock): the heartbeat is now."
function _flushRun!(st::_RunState)
    lock(st.lock) do
        _writeJsonAtomic(joinpath(st.dir, "run.json"), _runJson(st))
    end
    return nothing
end

"Appends `text` to the run's `run.LOG` under the state's lock; nothing once it is closed."
function _logAppend!(st::_RunState, text::AbstractString)
    lock(st.lock) do
        io = st.logio
        io === nothing && return nothing
        write(io, text)
        flush(io)
    end
    return nothing
end

"The rows `[name, value]` of the end of `run.LOG`: how the run ended."
function _resultRows(st::_RunState)
    n(s) = string(count(m -> m.status == s, st.models))
    return [
        ["status", st.status],
        ["ended", _isoUtc(something(st.ended, time()))],
        ["seconds", _logCell(something(st.ended, time()) - st.started)],
        ["models", string(length(st.models))],
        ["modelsDone", n("done")],
        ["modelsFailed", n("failed")],
        ["modelsAborted", n("aborted")],
        ["modelsSkipped", n("skipped")],
    ]
end

"""
Closes the run once: marks the models that were running as `aborted` (a model that was not
started as `skipped`) when the run was aborted, sets the final status, rewrites
`run.json`, appends the result rows and the ERRORS section to `run.LOG` and closes it.
Safe to call again, and from the exit hook while a loop is still running.
"""
function _finish!(st::_RunState, status::AbstractString)
    lock(st.lock) do
        st.finished && return nothing
        st.finished = true
        st.status = String(status)
        st.ended = time()
        for m in st.models
            if m.status == "running"
                m.status = status == "aborted" ? "aborted" : "failed"
            elseif m.status == "pending"
                m.status = "skipped"
            end
        end
        try
            _flushRun!(st)
        catch e
            e isa InterruptException && rethrow()
        end
        lines = vcat(["", "--- result ---"], _tabLines(_resultRows(st)))
        if !isempty(st.errors)
            push!(lines, "", "=== ERRORS ===")
            for (i, e) in enumerate(st.errors)
                i > 1 && push!(lines, "")
                append!(lines, split(rstrip(e), '\n'))
            end
        end
        try
            _logAppend!(st, join(lines, "\n") * "\n")
            io = st.logio
            io === nothing || close(io)
            st.logio = nothing
        catch e
            e isa InterruptException && rethrow()
        end
    end
    return nothing
end

"The widest a brief error text may be, so a line of it fits a terminal of 80 columns."
const _BRIEF_ERROR_WIDTH = 50

"""
A short reason for the error `e`, for the line the terminal shows (`model X failed: ...`):
a non-converged run says `not converged`, any other error its first sentence, cut at a
word when it is longer than `_BRIEF_ERROR_WIDTH`. The whole message stays in `run.json`
and in the ERRORS section of `run.LOG`.
"""
function _briefError(e)
    e isa Inference.NotConvergedError && return "not converged"
    text = String(strip(first(split(sprint(showerror, e), '\n'))))
    text = String(first(split(text, r"(?<=[.!?])\s")))
    length(text) <= _BRIEF_ERROR_WIDTH && return rstrip(text, '.')
    cut = first(text, _BRIEF_ERROR_WIDTH)
    at = findlast(' ', cut)
    return String(strip(at === nothing ? cut : cut[1:prevind(cut, at)]))
end

"The error `e` with its stack as the text of an ERRORS entry headed by `what`."
function _errorText(what::AbstractString, e, bt)
    return string(what, ": ", sprint(showerror, e, bt))
end

# ---------------------------------------------------------------------------
#                      claiming a run folder, and who else runs
# ---------------------------------------------------------------------------

# Whether a process with this id exists on this machine (`nothing` when it cannot be told).
function _pidExists(pid::Integer)
    Sys.isunix() || return nothing
    r = ccall(:kill, Cint, (Cint, Cint), pid, 0)
    return r == 0 || Libc.errno() == Libc.EPERM
end

"""
The pid of a live run of the project whose runs folder is `runs`, or `nothing`: a run
whose `run.json` says `running`, whose heartbeat is under `RUN_STALE_S` seconds old and,
when it is on this host, whose process exists. A file that cannot be read is no run.
"""
function _liveRun(runs::AbstractString)
    isdir(runs) || return nothing
    for entry in readdir(runs; join = true)
        file = joinpath(entry, "run.json")
        isfile(file) || continue
        j = try
            JSON3.read(read(file, String))
        catch e
            e isa InterruptException && rethrow()
            continue
        end
        get(j, :status, nothing) == "running" || continue
        beat = _parseIsoUtc(get(j, :heartbeat, nothing))
        (beat !== nothing && time() - beat < RUN_STALE_S) || continue
        pid = get(j, :pid, nothing)
        if pid isa Integer && get(j, :host, nothing) == gethostname()
            _pidExists(pid) === false && continue
        end
        return pid isa Integer ? Int(pid) : 0
    end
    return nothing
end

"""
Claims a new run folder in `runs` (made if missing) with a NON-recursive `mkdir` named by
the stamp of `t` (see `_runStamp`); when the name is taken (`EEXIST`, a run started in the
same millisecond) the next millisecond is tried, and so on. Nothing is ever overwritten.

# Returns
- The path of the folder, which the caller now owns.

# Exceptions
- `Base.IOError` for anything but an existing name (no permission, no space).
"""
function _claimRunDir(runs::AbstractString, t::Real = time())
    mkpath(runs)
    ms = round(Int, t * 1000)
    while true
        dir = joinpath(runs, _runStamp(ms / 1000))
        try
            mkdir(dir)
            return dir
        catch e
            (e isa Base.IOError && e.code == Base.UV_EEXIST) || rethrow()
            ms += 1
        end
    end
end

# ---------------------------------------------------------------------------
#                       the snapshot of the inputs, and reading it
# ---------------------------------------------------------------------------

"""
The models of a project folder, `(name, path)` in file order: the `.cif` and `.pdb` files
of `<project>/models/` (any case of the extension), named by their file stem; a stem that is
taken, or that the run's own folders use (`RUN_RESERVED_NAMES`), gets `-2`, `-3`, ...
"""
function _projectModels(project::AbstractString)
    folder = joinpath(project, "models")
    isdir(folder) || return Tuple{String,String}[]
    files = sort(
        filter(f -> lowercase(splitext(f)[2]) in (".cif", ".pdb"), readdir(folder)),
    )
    used = Set{String}(RUN_RESERVED_NAMES)
    out = Tuple{String,String}[]
    for f in files
        path = joinpath(folder, f)
        isfile(path) || continue
        stem = splitext(f)[1]
        name, k = stem, 1
        while name in used
            k += 1
            name = string(stem, "-", k)
        end
        push!(used, name)
        push!(out, (name, abspath(path)))
    end
    return out
end

"""
Puts the inputs of the project `project` into the run folder `dir` (flat: the run folder has
no subfolders), which the run reads from from then on: each of `RUN_INPUTS` is copied
unless the folder already has it (an interface that took the snapshot itself, under its
locks, has done it first), the reference curves of `reference-fit/` (the files with a
`REFERENCE_EXTENSIONS` extension)
are copied as `reference-fit-<file>` unless the folder already has such a file, a missing
`settings.json` becomes an empty object (the defaults) and `models.json` lists the models
(name, full path, size, sha256) unless it is there already.

# Returns
- The vector of models, as `models.json` has them.

# Exceptions
- `SystemError` if a file cannot be copied or written.
"""
function _snapshotInputs(project::AbstractString, dir::AbstractString)
    mkpath(dir)
    for f in RUN_INPUTS
        dest = joinpath(dir, f)
        isfile(dest) && continue
        src = joinpath(project, f)
        if isfile(src)
            cp(src, dest)
        elseif f == "settings.json"
            write(dest, "{}\n")
        end
    end
    refs = joinpath(project, RUN_REFERENCES)
    if isdir(refs) && !any(f -> startswith(f, RUN_REFERENCE_PREFIX), readdir(dir))
        for f in readdir(refs)
            path = joinpath(refs, f)
            isfile(path) && lowercase(splitext(f)[2]) in REFERENCE_EXTENSIONS &&
                cp(path, joinpath(dir, RUN_REFERENCE_PREFIX * f))
        end
    end
    file = joinpath(dir, "models.json")
    if !isfile(file)
        entries = [
            (; name, path, size = filesize(path), sha256 = _sha256File(path))
            for (name, path) in _projectModels(project)
        ]
        _writeJsonAtomic(file, entries)
    end
    return [
        (; name = String(e.name), path = String(e.path), size = Int(e.size),
            sha256 = String(e.sha256))
        for e in JSON3.read(read(file, String))
    ]
end

"The SHA-256 of the file `path`, as lower-case hexadecimal."
_sha256File(path::AbstractString) = open(io -> bytes2hex(SHA.sha256(io)), path)

"""
The measured curve of a run folder, `(q, I, σ, energy)`: `data.tsv` (three
tab-separated columns q, I, sigma, no header; blank lines are skipped) with q in Å⁻¹ (q is
divided by 10 when `data.json` says `"nm-1"`), and the X-ray energy of `data.json` in eV:
the `energy` as typed, read in the `energyUnit` (`"eV"`, `"keV"`, `"nm"` or `"A"`, a
wavelength; required; see `energyEv` of `PhysicalConstants`). `data.json` has more
keys (the source, the mapping of the columns): they are ignored.

# Exceptions
- `ArgumentError` naming the file and the line for a missing file, a line that has fewer
    than 3 columns or a cell that is no number, a `units` that is neither `"nm-1"` nor
    `"A-1"`, an `energy` that is no number above 0, an unknown `energyUnit` or an energy
    that is not above 0 in eV.
"""
function _readSnapshotData(dir::AbstractString)
    tsv, jsn = joinpath(dir, "data.tsv"), joinpath(dir, "data.json")
    isfile(tsv) && isfile(jsn) ||
        throw(ArgumentError("the project has no measured curve (data.tsv and data.json)"))
    meta = _readJson(read(jsn, String))
    meta isa AbstractDict || throw(ArgumentError("data.json must hold an object"))
    units = get(meta, :units, nothing)
    units in ("nm-1", "A-1") ||
        throw(
            ArgumentError(
                "data.json: `units` is $(repr(units)), expected \"nm-1\" or \"A-1\"",
            ),
        )
    energy = get(meta, :energy, nothing)
    (_isnum(energy) && energy > 0 && isfinite(energy)) ||
        throw(ArgumentError("data.json: `energy` is $(repr(energy)), expected above 0"))
    unit = get(meta, :energyUnit, nothing)
    unit isa AbstractString ||
        throw(ArgumentError("data.json: `energyUnit` is $(repr(unit)), expected a unit"))
    ev = energyEv(energy, unit)
    (isfinite(ev) && ev > 0) ||
        throw(ArgumentError("data.json: the energy is $ev eV, expected above 0"))
    q, I, σ = Float64[], Float64[], Float64[]
    for (n, line) in enumerate(eachline(tsv))
        isempty(strip(line)) && continue
        cells = split(line, '\t')
        length(cells) >= 3 ||
            throw(
                ArgumentError(
                    "data.tsv line $n: expected 3 columns, found $(length(cells))",
                ),
            )
        vals = map(c -> tryparse(Float64, strip(c)), cells[1:3])
        any(isnothing, vals) &&
            throw(ArgumentError("data.tsv line $n: a cell is not a number"))
        push!(q, vals[1])
        push!(I, vals[2])
        push!(σ, vals[3])
    end
    isempty(q) && throw(ArgumentError("data.tsv holds no measurement"))
    units == "nm-1" && (q ./= 10)
    return q, I, σ, ev
end

# A named tuple of the pairs, in their order (a JSON object whose keys keep it).
_ordered(pairs::Pair...) = NamedTuple{Tuple(first.(pairs))}(Tuple(last.(pairs)))

"""
The solutes of the buffer as the snapshot file `solutes.json` keeps them: for each row of
`buffer.json` its name and kind, the concentration and its uncertainty in mM as typed, the
electrons `Z`, the partial molar volume `pmv` and its uncertainty `sigmaPmv` (cm³ mol⁻¹
at 25 °C, as `ρₑ` uses them at this pH and with the fallback uncertainty), the row itself
for a custom solute (its snapshot), and for a DNA, RNA or protein a summary of the
sequence (its length and first residues) instead of the sequence. The buffer's own
`ρₑ` with its uncertainty at `t` is added, which is also what proves the buffer can be
evaluated before any model is started.

# Exceptions
- Whatever `ρₑ` throws for a solute that cannot be resolved (`DomainError`,
    `ArgumentError`).
"""
function _solutesSnapshot(
    solutes::Vector{Solute}, rows, pH::Real, σ_pH::Real, t::Real, fallback::Real,
)
    entries = Any[]
    for (s, row) in zip(solutes, rows)
        BulkElectronDensity._checkCustom(s)
        Z, v, σ = BulkElectronDensity._ρₑ_i(s, pH, σ_pH, fallback)
        kind = String(get(row, :kind, ""))
        name = String(get(row, :name, get(row, :custom, s.arg)))
        what = if kind in ("dna", "rna", "protein")
            :sequence => (; length = length(s.arg), head = first(s.arg, 12))
        elseif kind in ("custom-nonbio", "custom-polymer")
            :custom => _plainJson(row)
        else
            :arg => s.arg
        end
        push!(
            entries,
            _ordered(
                :name => name, :kind => kind, what, :mM => row[:mM],
                Symbol("sigmaMm") => row[Symbol("sigmaMm")], :Z => Int(round(Z)),
                :pmv => v, Symbol("sigmaPmv") => σ,
            ),
        )
    end
    ρ, σρ = ρₑ(pH, σ_pH, solutes; t, pmvFallbackUncert = fallback)
    return (; temperatureC = Float64(t), pH = Float64(pH), sigmaPh = Float64(σ_pH),
        pmvFallbackUncert = Float64(fallback), rhoE = ρ, sigmaRhoE = σρ,
        solutes = entries)
end

# ---------------------------------------------------------------------------
#                       the live output, tee'd into run.LOG
# ---------------------------------------------------------------------------

"""
The stream of the terminal while `runProject` redirects stdout and stderr into a pipe that
is copied both to the terminal and to `run.LOG`: the saved original streams and the lock
the two pumps and a direct print (`_teePrint`) share.
"""
struct _Tee
    out::IO
    err::IO
    lock::ReentrantLock
end

"Prints `text` to the real terminal output, past the copy into `run.LOG` (the plots)."
function _teePrint(tee::_Tee, text::AbstractString)
    lock(tee.lock) do
        write(tee.out, text)
        flush(tee.out)
    end
    return nothing
end

_teePrint(::Nothing, text::AbstractString) = (print(stdout, text); nothing)

"""
Runs `f(tee)` with stdout and stderr (the HMC output, `@warn` and `@info`, and what a
child process writes) redirected into pipes, each copied to the original stream and
appended to the run's `run.LOG`; the streams are restored, and the pumps drained, when `f`
returns or throws.
"""
function _withTee(f, st::_RunState)
    # the original streams, as streams of their own: `redirect_stdout` re-points the
    # descriptors 1 and 2, so the originals are reached through duplicates
    out0 = Base.fdio(Int(reinterpret(Int32, Base.dup(RawFD(1)))), true)
    err0 = Base.fdio(Int(reinterpret(Int32, Base.dup(RawFD(2)))), true)
    tee = _Tee(out0, err0, ReentrantLock())
    stdoutBefore, stderrBefore = stdout, stderr
    pump(rd, orig) = Threads.@spawn :interactive begin
        while !eof(rd)
            data = readavailable(rd)
            lock(tee.lock) do
                write(orig, data)
                flush(orig)
            end
            _logAppend!(st, String(copy(data)))
        end
    end
    ro, wo = redirect_stdout()
    re, we = redirect_stderr()
    tOut, tErr = pump(ro, out0), pump(re, err0)
    try
        return f(tee)
    finally
        # the descriptors go back to the terminal through the duplicates, and the streams
        # `stdout` and `stderr` name are the ones they were
        redirect_stdout(out0)
        redirect_stderr(err0)
        redirect_stdout(stdoutBefore)
        redirect_stderr(stderrBefore)
        close(wo)
        close(we)
        wait(tOut)
        wait(tErr)
        close(out0)
        close(err0)
    end
end

# ---------------------------------------------------------------------------
#                    one model: seed, sample, results, log
# ---------------------------------------------------------------------------

"""
The text of a failed model's `<model>.LOG`: the conditions of the run and what went
wrong, in the layout of the other LOGs.
"""
function _failedModelLog(path, name, rows, message)
    firstLine = String(first(split(message, '\n')))
    _updateLog(
        path,
        name,
        _tabLines(vcat(rows, [["status", "failed"], ["error", firstLine]])),
    )
    return nothing
end

# The rows `[override<Setting>, value]` of the settings a model was given of its own.
function _overrideRows(cfg)
    return [
        ["override" * join(uppercasefirst(lowercase(p)) for p in split(String(n), '_')),
            v isa Real ? _logCell(v) : string(v)]
        for (n, v) in cfg.overrides
    ]
end

# The sizes of the terminal plots written into the run folder `dir` for `stem` (a model's
# name, or `compare`): `(file, width, rows)` of each `<stem>-<W>x<H>.txt` of `sizes` that is
# there, the width of the widest line in terminal cells and the lines of the tallest plot.
function _measuredPlotSizes(dir::AbstractString, stem::AbstractString, sizes)
    out = NamedTuple[]
    for (W, H) in sizes
        file = "$(stem)-$(W)x$(H).txt"
        path = joinpath(dir, file)
        isfile(path) || continue
        text = read(path, String)
        blocks = split(strip(text), r"\n[ \t]*\n"; keepempty = false)
        push!(
            out,
            (; file, width = _textWidth(text),
                rows = maximum(b -> count('\n', b) + 1, blocks; init = 0)),
        )
    end
    return out
end

"""
The `results` keywords `kw` of a run for the model `name`: the plot folder, when there is
one, is one folder for all projects and so gets the model's place in it,
`<plot dir>/<project>/<run>/<model>` (the layout the terminal interface moves plots to);
`st` is the run's state (its `project` and `dir`).
"""
function _modelResultsKw(kw, st, name::AbstractString)
    isempty(kw.plotDir) && return kw
    place = joinpath(kw.plotDir, basename(st.project), basename(st.dir), name)
    return merge(kw, (; plotDir = place))
end

"""
Moves what `results` or `compareResults` wrote into the staging folder `stage` up into the
run folder `st.dir`, flat: the files of the folder and of its `plots/` subfolder (the
`.tex` figures and what is compiled from them) keep their names, except that the terminal
plots `plots_<W>x<H>.txt` become `<stem>-<W>x<H>.txt` and `rename` may change the others
(it is given a file name and returns the one to use). The staging folder is removed.

# Returns
- The names of the files now in the run folder, sorted.
"""
function _flattenStage!(st, stage::AbstractString, stem::AbstractString; rename = identity)
    files = String[]
    for (root, _, names) in walkdir(stage)
        for f in sort(names)
            m = match(r"^plots_(\d+x\d+)\.txt$", f)
            dest = m === nothing ? rename(f) : string(stem, "-", m[1], ".txt")
            mv(joinpath(root, f), joinpath(st.dir, dest); force = true)
            push!(files, dest)
        end
    end
    rm(stage; recursive = true, force = true)
    return sort!(files)
end

"""
Fits one model of a run and writes its files: `seedModel`, `runModel`, then `results`
into a staging folder that is then emptied into the run folder (flat: `<model>.xlsx`, the
`.tex` figures `<model>*.tex`, the plots as plain text into `<model>-plots.txt`, and, when
`ui` is `:cli`, to the terminal too; and under the model's name into the run's
`plots.txt`; when `ui` is `:tui`, also `<model>-<W>x<H>.txt` for each size of the setting
`PLOT_TUI_SIZES`) and `writeLog` into `<model>.LOG`, with a row `override<Setting>` for
each setting the model was given of its own. The files are listed in the model's `files`.
"""
function _runModel!(st, rec, inputs, cfg, tee)
    stage = joinpath(st.dir, ".stage-" * rec.name)
    mkpath(stage)
    logfile = joinpath(st.dir, rec.name * ".LOG")
    s = inputs
    seed = seedModel(
        MolecularStructure.LocalPathSource(rec.path), s.energy, s.q, s.I, s.σ, s.pH,
        s.σ_pH, s.solutes;
        s.seedKw..., t = cfg.temperature,
    )
    result = runModel(seed, cfg.nSamples, cfg.nAdapt; cfg.runKw...)
    printSummary(result)
    buf = IOBuffer()
    kw = _modelResultsKw(cfg.resultsKw, st, rec.name)
    # the model's own reference curve and the depositor's χ² (`model-references.json`)
    mref = get(cfg, :modelRef, (; references = Reference[], refChi2 = nothing))
    results(
        result, seed; dir = stage, name = rec.name, preview = true, io = buf,
        tuiDir = st.ui === :tui ? stage : nothing, references = mref.references,
        refChi2 = mref.refChi2, kw...,
    )
    files = _flattenStage!(st, stage, rec.name)
    plotsFile = joinpath(st.dir, rec.name * "-plots.txt")
    _writePlots(st, plotsFile, rec.name, String(take!(buf)), tee)
    rec.files = vcat(files, [rec.name * "-plots.txt"])
    for (k, v) in _overrideRows(cfg)
        result[1].timing.info[k] = v
    end
    writeLog(result; path = logfile, name = rec.name, refChi2 = mref.refChi2)
    return (; result)
end

"""
Writes the terminal plots `text` (printed by `results` or `compareResults` into a buffer)
as plain text into `path`, appends them under `=== <title> ===` to the run's
`plots.txt`, and prints them to the terminal when the run's `ui` is `:cli`. The one
route every plot of a run takes.
"""
function _writePlots(st, path::AbstractString, title::AbstractString, text::AbstractString,
    tee)
    plots = _plainText(text)
    write(path, plots)
    open(joinpath(st.dir, "plots.txt"), "a") do io
        println(io, "=== ", title, " ===")
        print(io, plots)
        println(io)
    end
    st.ui === :cli && _teePrint(tee, plots)
    return nothing
end

"""
The reference curves of a run folder, its `reference-fit-<file>` files (q in Å⁻¹: divided
by 10 when `data.json` says `"nm-1"`, as `data.tsv` is), as `(references, problems)` of
`_readReferences`.
"""
function _snapshotReferences(dir::AbstractString)
    return _readReferences(
        dir; qScale = _snapshotQScale(dir), prefix = RUN_REFERENCE_PREFIX,
    )
end

"The factor of q in a run folder's curves: 0.1 when `data.json` says `\"nm-1\"`, else 1."
function _snapshotQScale(dir::AbstractString)
    meta = _readJson(read(joinpath(dir, "data.json"), String))
    return get(meta, :units, "A-1") == "nm-1" ? 0.1 : 1.0
end

"""
Makes the combined comparison of the models of `fitted` (`(name, result)` pairs, the
models that finished) with `refs` and the measured curve `data`, into the run folder:
[`compareResults`](@ref) writes the `.tex` figure and the table into a staging folder, and
they come up as `compare.tex` and `compare.tsv` (`compare-<W>x<H>.txt` for the terminal
plots at the other sizes), the terminal plot goes to `compare-plots.txt` and the run's
`plots.txt` by the route of the other plots. What came of it is `st.compare` (`status`,
the `files` in the run folder, the `models` and `references` drawn, an `error` line) and so
`run.json`. A failure is caught like a model's: a note in the ERRORS section, and the run's
status is unchanged.
"""
function _runCompare!(st, fitted, refs, data, cfg, tee)
    stage = joinpath(st.dir, ".stage-" * RUN_COMPARE)
    outcome = try
        mkpath(stage)
        kw = cfg.resultsKw
        buf = IOBuffer()
        name = basename(st.dir)
        compareResults(
            [r for (_, r) in fitted], data; names = [n for (n, _) in fitted],
            references = refs, dir = stage, name,
            style = get(kw, :style, PlotStyle()), preview = true, io = buf,
            tex = kw.tex, compile = kw.compile, formats = kw.formats,
            tableSigfigs = kw.tableSigfigs, plotTuiSizes = kw.plotTuiSizes,
            tuiDir = st.ui === :tui ? stage : nothing,
        )
        # `<run>_compare.tex` becomes `compare.tex`, the same for what is made of it
        prefix = name * "_" * RUN_COMPARE
        renamed(f) =
            startswith(f, prefix) ? RUN_COMPARE * f[(length(prefix)+1):end] : f
        files = _flattenStage!(st, stage, RUN_COMPARE; rename = renamed)
        plotsFile = RUN_COMPARE * "-plots.txt"
        _writePlots(st, joinpath(st.dir, plotsFile), RUN_COMPARE, String(take!(buf)), tee)
        (; status = "done",
            files = vcat(
                # the plots at other sizes are the `plotSizes`
                [f for f in files if !occursin(r"^compare-\d+x\d+\.txt$", f)],
                [plotsFile],
            ),
            models = [n for (n, _) in fitted], references = [r.name for r in refs],
            plotSizes = _measuredPlotSizes(st.dir, RUN_COMPARE, kw.plotTuiSizes),
            error = nothing)
    catch e
        e isa InterruptException && rethrow()
        rm(stage; recursive = true, force = true)
        push!(st.errors, _errorText("compare", e, catch_backtrace()))
        println(
            stderr,
            "the comparison failed: " * first(split(sprint(showerror, e), '\n')),
        )
        (; status = "failed", files = String[], models = String[],
            references = String[], plotSizes = NamedTuple[],
            error = String(first(split(sprint(showerror, e), '\n'))))
    end
    lock(st.lock) do
        st.compare = outcome
    end
    _flushRun!(st)
    return nothing
end

"""
The names under which `files` are put into `folder` without taking the place of a file that
is there: their own, or, when one of them is taken, all of them with `-2`, `-3`, ... before
the extension (the first number that frees every name), so the files of one unit stay
together.

# Returns
- The new names, in the order of `files`.
"""
function _freeNames(folder::AbstractString, files::AbstractVector{<:AbstractString})
    k = 1
    named(f) = begin
        stem, ext = splitext(f)
        k == 1 ? f : string(stem, "-", k, ext)
    end
    while any(f -> ispath(joinpath(folder, named(f))), files)
        k += 1
    end
    return [named(f) for f in files]
end

"""
Copies the workbooks of the models that finished and the comparison table of the run into
`folder` (the setting `TABLE_DIR`), each model's files under its own name, the comparison's
as `<project>-compare.tsv`; a taken name gets a number ([`_freeNames`](@ref)). A failure
is a note in the ERRORS section and a warning, never a failed run.
"""
function _copyData!(st, folder::AbstractString)
    try
        mkpath(folder)
        units = Pair{String,Vector{String}}[
            m.name => filter(endswith(".xlsx"), m.files) for m in st.models if
            m.status == "done"
        ]
        cmp = st.compare
        if cmp !== nothing && cmp.status == "done"
            name = "$(basename(st.project))-$(RUN_COMPARE)"
            push!(units, name => filter(endswith(".tsv"), cmp.files))
        end
        for (stem, files) in units
            isempty(files) && continue
            # the comparison's file is `compare.tsv`; the others are named for the model
            wanted = [stem * splitext(f)[2] for f in files]
            for (f, dest) in zip(files, _freeNames(folder, wanted))
                cp(joinpath(st.dir, f), joinpath(folder, dest))
            end
        end
    catch e
        e isa InterruptException && rethrow()
        note = "tableDir: " * sprint(showerror, e)
        push!(st.errors, note)
        @warn note
    end
    return nothing
end

# ---------------------------------------------------------------------------
#                                 the entry point
# ---------------------------------------------------------------------------

"""
    runProject(projectDir; temperature, ui = :cli, runDir = nothing, ...) -> NamedTuple

Fits every model of a project, in this one process, and writes what came out
as a run folder, `<projectDir>/runs/<stamp>/` (`stamp` is the local time,
the zone label, its offset from UTC and the date, `(HH-MM-SS-mmm_TZ_±HHMM)_(YYYY-MM-DD)`),
which is FLAT, with no subfolders (the terminal interface packs it, once the run is over,
into one `runs/<stamp>.7z` and removes the folder):

    run.json            status, pid, host, times, heartbeat, versions, the models (each
                        with its `files`, `plotSizes` and `overrides`), timings and,
                        once made, the `compare` entry
    run.LOG             the log of the run (the output of the fits, then the result)
    plots.txt           every terminal plot of the run, each under `=== <model> ===`
    settings.json buffer.json solutes.json data.tsv data.json models.json
    model-settings.json (if the project has one)
    reference-fit-<file>   the reference curves the run read (the snapshot)
    <model>.LOG         the log of that fit ([`writeLog`](@ref)); `status` and `error`
                        rows instead of a fit for a model that failed (a model is named
                        by its file stem; a clash gets `-2`, ...; `run` and `compare`
                        are taken)
    <model>.xlsx        the workbook of the model
    <model>*.tex        its figures (`<model>.tex`, `<model>_hist_<parameter>.tex`, ...;
                        rendered files too when the settings compile)
    <model>-plots.txt   its terminal plots as plain text, and with `ui = :tui` the same
                        plots at the other sizes, `<model>-<W>x<H>.txt`
    compare.tsv         the combined comparison (compareResults), made when
    compare.tex         `plotCompare` is on, with `compare-plots.txt` and (`:tui`)
    compare-<W>x<H>.txt   the plots at the other sizes

The project folder holds `settings.json` (what [`loadSettings`](@ref) reads: the settings
of this project), `buffer.json` (the solutes with the pH and its σ, see
[`loadBuffer`](@ref) and [`loadBufferPh`](@ref)), `data.tsv` and `data.json` (the curve,
three columns q, I, sigma; `units` `"nm-1"` or `"A-1"`, the X-ray `energy` (in
`energyUnit`); the other keys are ignored), `models/` (`.cif` and
`.pdb` files) and, optionally, `reference-fit/`: every `.tsv`, `.dat` or `.txt` file in it
with
two or three numeric columns (q in the units
of `data.json`, I, an optional σ that is read and not used) is a reference curve named by
its file stem, drawn on the comparison figure (comments `#`, blank lines and text lines
before the first numbers are skipped; a file that cannot be read is a note in the ERRORS
section and is skipped, never a failed run). **The inputs are copied into the run folder
first and the run reads only the copies**, so editing the project while it runs changes
nothing; a file that is already there (a caller that took the snapshot itself) is used as it
is.
`temperature` (°C, no uncertainty) is the buffer's, and with the pH, its σ and the energy
it is a row of every LOG (`temperatureC`, `ph`, `sigmaPh`, `energyEv`).

After the last model, when the setting `PLOT_COMPARE` (the keyword `plotCompare`, `true` by
default) is on and at least one model was fitted, the run makes ONE combined figure of the
measured curve, the fitted curve of every model that finished and the reference curves
([`compareResults`](@ref)) into the run folder (`compare.tex`, `compare.tsv`), and records
it in `run.json` as the `compare` entry: `status` (`done` or `failed`), `files` (in the run
folder), the `models` and `references` drawn and an `error` line. Its failure is caught
like a model's (a note in the ERRORS section) and does not change the run's status; the
key is absent when no comparison was made.

`ui = :cli` prints the plots to the terminal as well as writing them; `ui = :tui` never
prints them (they are in `plots.txt` only), for a caller that shows the output live, and
writes them at the sizes of the setting `PLOT_TUI_SIZES` too (the keyword
`plotTuiSizes`): `<model>-<W>x<H>.txt` next to `<model>-plots.txt` for every model and
`compare-<W>x<H>.txt` for the comparison, in the same layout, so a viewer shows the largest
that fits its window. Each
model's `run.json` entry (and the `compare` entry) lists them as `plotSizes`,
`[{file, width, rows}]` (`file` in the run folder, `width` the widest line in
terminal cells, `rows` the lines of the tallest plot); the list is empty with `:cli`.

**Settings of single models.** The project's `model-settings.json` gives some settings to
single models: `{"<model>": {<sheet>: {"<SETTING>": {"value": ...}}}}`, the shape of
`settings.json` for each model, named by its file stem. The keyword `modelSettings`, a
`Dict` or `NamedTuple` from a model name to a `Dict` or `NamedTuple` of keywords
(`(; crambin = (; qMax = 0.3, nChains = 8))`), does the same for a caller and wins over
the file. A model is fitted with the settings of the project (the defaults, then
`settings.json`, then the keywords of this call) and, on top of them, its own: the order
of strength is the `modelSettings` keyword, the file, the keywords of the call,
`settings.json`, the default. Every setting that belongs to one fit may be given for a
model (the data selection, the structure, the model, shell, bead and prior settings, the
sampler, `LMAX`, `RNG_SEED`, `VAL_SIGMA`, `TARGET_ACCEPT`, `N_CHAINS`, `N_ADAPT`,
`N_DRAWS`, ...), not the settings of the whole run (`PLOT_*`, `TABLE_SIGFIGS`,
`FIGURES_*`: `RUN_LEVEL_SETTINGS`), which are refused with an
[`InvalidSettingsError`](@ref) that names the setting and the model. An invalid or
unreadable file, a value out of its limits or a broken rule between settings fails the
run before any model starts, as an invalid `settings.json` does. A name that is no model
of the project is a note in the ERRORS section and is ignored. Each model's LOG has a row
`override<Setting>` for every setting it was given of its own, its `run.json` entry
`overrides` (the names), and the comparison draws every model over its own q range. The
file is copied into the run folder like the other inputs. The
log, the summary of each fit and the sampler's own output always go to stdout and stderr,
and are copied into `run.LOG`, which ends with a `--- result ---` block and, if
anything failed, an `=== ERRORS ===` section with each message and its stack.

**Failures do not stop the loop.** An exception while fitting a model (an unknown element
or radius, a residue that cannot be resolved, a run that did not converge, ...) is caught,
written to the ERRORS section, the model is `failed` in `run.json` and the next model
starts; the run ends `failed` if anything failed (an invalid input, such as a buffer or a
setting, fails the run before any model) and `done` if all models did. An
`InterruptException` (Ctrl-C), a SIGTERM (an exit hook: Julia prints a stack for the signal,
which is no error of the run) or, with `watchStdin`, the end of the standard input (the
caller closed or died: the process exits, none is left over) ends the run as `aborted`: the
model that was running is `aborted`, the rest `skipped`, the files are finished and nothing
more is done.

`run.json` is rewritten by this function alone, atomically (a temporary file
renamed over it), at every change and every `heartbeat` seconds (10 by default:
its `heartbeat` is the time of the last rewrite); a run counts as live while
`status` is `running` and the heartbeat is under a minute old. Without `runDir`
the folder is claimed here: a non-recursive `mkdir` of the stamp (when it exists,
the next millisecond), after a check that no run of the project is live. A caller
that claims the folder itself, under its own lock, passes it as `runDir`.

# Arguments
- `projectDir`: the project folder.

# Keywords
- `temperature::Real`: the buffer's temperature, °C (required; above absolute zero).
- `ui::Symbol = :cli`: `:cli` or `:tui`.
- `runDir = nothing`: an existing, already claimed run folder to use instead of claiming
    one.
- `nSamples`, `nAdapt`, `sigma`, `rngSeed`, `nChains`, `retry`: for
    [`runModel`](@ref); by default the settings `N_ADAPT + N_DRAWS`, `N_ADAPT`,
    `VAL_SIGMA`, `RNG_SEED` and `N_CHAINS` of the project's `settings.json`, and the
    default of `retry`. `rngSeed = :settings` (the default) takes the setting, an integer
    that value and `nothing` a fresh seed (which each model's LOG records).
- `addHydrogens = nothing`, `lMax = :settings`: for [`seedModel`](@ref); by default the
    settings `ADD_HYDROGENS` and `LMAX` of the project (`true`, automatic). A `Bool` and an
    integer (or `nothing`, automatic) override them.
- **Every other setting, as a keyword that overrides the project's
    `settings.json`** (all default to `nothing`: take the setting). The value is
    checked as [`loadSettings`](@ref) checks the setting (the relations between
    settings too), and the run fails before any model, with an `inputs` error, if
    it is not valid; a keyword that is no setting is an `ArgumentError` at once.
    - for [`seedModel`](@ref), the data and structure: `qMin`, `qMax` (`nothing`
        is no limit and clears a saved one; the default `:settings` takes the saved
        one), `sigmaScale`, `excludeQ`, `chains`, `model` (from the keywords only:
        the data of the project, `data.json`, does not hold them yet);
    - for [`seedModel`](@ref): `thickness`, `probe`, `κ_δρ₁₂`, `κ_δρ₃`,
        `pmvFallbackUncert`, `bounds_δρ₁₂`, `mode_δρ₁₂`, `φ_max`, `exclVolCorrBounds`,
        `exclVolCorrEps`, `shellAreaPerPoint`, `shellMinPoints`, `shellSample`,
        `sasaNOcc`, `beadRayRange`, `beadRayDirs` (the [`seedKeywords`](@ref));
    - for [`runModel`](@ref): `nDraws` (`N_DRAWS`; `nSamples` wins if given), `δ`,
        `retryNAdapt`, `retryNDraws`, `chainStartRadii`, `optimumChainCap`,
        `optimumMinChains`, `optimumChainRadius`, `optimumChainFraction`,
        `mapMaxIter`, `mapNStarts`, `mapFSuccessive`, `mapOptimaKept`,
        `mapJitterRadii`, `mapJitterDirections`, `mapJitterMaxOptima`,
        `mapJitterWithinNats`, `basinRestartNats`, `harvestCover`,
        `harvestDivergent` (the [`runKeywords`](@ref));
    - for [`results`](@ref): `tex`, `compile`, `formats`, `tableSigfigs`, `plotDir`
        (`FIGURES_DIR`: the figures of each model are also copied to
        `<plotDir>/<project>/<run>/<model>/`), `latexCompiler` (`FIGURES_COMPILER`) and
        `style`, a
        [`PlotStyle`](@ref) that replaces the one the `PLOT_*` settings describe (the
        [`resultsKeywords`](@ref));
    - for the run: `tableDir` (`TABLE_DIR`), a folder the workbooks and `compare.tsv`
        are also copied to when it is not empty (a taken name gets `-2`, `-3`, ...);
        `plotCompare` (`PLOT_COMPARE`), whether the combined comparison is made;
        its colours, markers and line width are the `style`'s `colorsCompare`,
        `markersCompare` and `lwCompare`; `plotTuiSizes` (`PLOT_TUI_SIZES`), the sizes
        of the terminal plots that `:tui` also writes, `((width, height), ...)` (checked as
        the setting is: each at least 24 by 3 and at most 400 by 100, growing in both).
- `modelSettings = nothing`: the settings of single models, a `Dict` or `NamedTuple`
    from a model name to a `Dict` or `NamedTuple` of the keywords above (see "Settings of
    single models").
- `watchStdin::Bool = (ui === :tui)`: end the run as aborted when `stdinIo` reaches its
    end. Off for `:cli`, where a terminal's end of file is a user's choice and a closed
    standard input (a service, `/dev/null`) must not stop a run.
- `stdinIo::IO = stdin`: the stream that `watchStdin` watches.
- `exitOnEof::Bool = true`: when that stream ends, finish the files as `aborted` and exit
    the process at once (code 130). `false` only stops the run after the model that is
    being fitted (a caller that is not a process of its own).
- `heartbeat::Real = $(RUN_HEARTBEAT_S)`: seconds between two heartbeats.
- `tee::Bool = true`: copy stdout and stderr into `run.LOG` (off, the log has the header
    and result only: for a caller that has redirected them itself).
- `fit::Function`: the function that fits one model and writes its folder (a seam for the
    tests; the default is the real fit). A `NamedTuple` with a `result` field that it
    returns is that model's result, which the comparison draws.

# Returns
- `(; dir, status, models)`: the run folder, the final status as a `Symbol` (`:done`,
    `:failed` or `:aborted`) and a `(name, status)` pair for each model.

# Exceptions
- `ArgumentError` for a missing `projectDir`, a `ui` that is neither `:cli` nor `:tui`, a
    `temperature` that is not above absolute zero, or a `runDir` that is not a folder; this
    before anything is written.
- `ArgumentError` also for a `modelSettings` that is not a table of tables or that names
    a keyword that is no setting's.
- `ErrorException` (`a run is in progress (pid N)`) when no `runDir` was given and a run of
    the project is live.
- `Base.IOError` when a run folder cannot be made. Nothing else escapes: the rest is in
    `run.json` and `run.LOG`.
"""
function runProject(
    projectDir::AbstractString;
    temperature::Real,
    ui::Symbol = :cli,
    runDir::Union{Nothing,AbstractString} = nothing,
    nSamples::Union{Nothing,Integer} = nothing,
    nAdapt::Union{Nothing,Integer} = nothing,
    sigma::Union{Nothing,Real} = nothing,
    rngSeed::Union{Nothing,Integer,Symbol} = :settings,
    nChains::Union{Nothing,Integer} = nothing,
    retry::Bool = Inference.RETRY,
    addHydrogens::Union{Nothing,Bool} = nothing,
    lMax = :settings,
    qMin = :settings,
    qMax = :settings,
    sigmaScale = nothing,
    excludeQ = nothing,
    chains = nothing,
    model = nothing,
    nDraws = nothing,
    δ = nothing,
    thickness = nothing,
    probe = nothing,
    κ_δρ₁₂ = nothing,
    κ_δρ₃ = nothing,
    pmvFallbackUncert = nothing,
    bounds_δρ₁₂ = nothing,
    mode_δρ₁₂ = nothing,
    φ_max = nothing,
    exclVolCorrBounds = nothing,
    exclVolCorrEps = nothing,
    shellAreaPerPoint = nothing,
    shellMinPoints = nothing,
    shellSample = nothing,
    sasaNOcc = nothing,
    beadRayRange = nothing,
    beadRayDirs = nothing,
    retryNAdapt = nothing,
    retryNDraws = nothing,
    chainStartRadii = nothing,
    optimumChainCap = nothing,
    optimumMinChains = nothing,
    optimumChainRadius = nothing,
    optimumChainFraction = nothing,
    mapMaxIter = nothing,
    mapNStarts = nothing,
    mapFSuccessive = nothing,
    mapOptimaKept = nothing,
    mapJitterRadii = nothing,
    mapJitterDirections = nothing,
    mapJitterMaxOptima = nothing,
    mapJitterWithinNats = nothing,
    basinRestartNats = nothing,
    harvestCover = nothing,
    harvestDivergent = nothing,
    tex = nothing,
    compile = nothing,
    formats = nothing,
    tableSigfigs = nothing,
    plotDir = nothing,
    latexCompiler = nothing,
    plotCompare = nothing,
    tableDir = nothing,
    plotTuiSizes = nothing,
    modelSettings = nothing,
    style::Union{Nothing,PlotStyle} = nothing,
    watchStdin::Bool = (ui === :tui),
    stdinIo::IO = stdin,
    exitOnEof::Bool = true,
    heartbeat::Real = RUN_HEARTBEAT_S,
    tee::Bool = true,
    fit::Function = _runModel!,
)
    isdir(projectDir) || throw(ArgumentError("the project folder $projectDir is missing"))
    ui in RUN_UI || throw(ArgumentError("ui must be :cli or :tui, got $(repr(ui))"))
    _need(isfinite(temperature) && temperature > -273.15,
        "temperature must be above absolute zero (°C)")
    _need(heartbeat > 0, "heartbeat must be positive")
    _need(
        nSamples === nothing || nDraws === nothing,
        "nSamples and nDraws both set the number of posterior draws: give one",
    )
    # the settings given as keywords, by the name of the setting (checked in the inputs
    # block below, with the settings file)
    given = (; addHydrogens, lMax, qMin, qMax, sigmaScale, excludeQ, chains, model,
        thickness, probe, κ_δρ₁₂, κ_δρ₃, pmvFallbackUncert, bounds_δρ₁₂,
        mode_δρ₁₂, φ_max, exclVolCorrBounds, exclVolCorrEps, shellAreaPerPoint,
        shellMinPoints, shellSample, sasaNOcc, beadRayRange, beadRayDirs,
        nDraws,
        δ, retryNAdapt, retryNDraws, chainStartRadii, optimumChainCap,
        optimumMinChains, optimumChainRadius, optimumChainFraction, mapMaxIter,
        mapNStarts, mapFSuccessive, mapOptimaKept, mapJitterRadii,
        mapJitterDirections, mapJitterMaxOptima, mapJitterWithinNats,
        basinRestartNats, harvestCover, harvestDivergent, tex, compile, formats,
        tableSigfigs, plotDir, latexCompiler, plotCompare, tableDir, plotTuiSizes,
    )
    # the settings of single models given as a keyword: the shape and the names are
    # checked at once, the values with the settings in the inputs block below
    modelTable = _modelKeywordTable(modelSettings)
    project = abspath(projectDir)
    runs = joinpath(project, RUN_FOLDER)
    if runDir === nothing
        pid = _liveRun(runs)
        pid === nothing || error("a run is in progress (pid $pid)")
        dir = _claimRunDir(runs)
    else
        isdir(runDir) || throw(ArgumentError("the run folder $runDir does not exist"))
        dir = abspath(runDir)
    end
    logs = dir          # the run folder is flat: the inputs and the logs are in it

    st = _RunState(
        dir, project, ui, time(), ReentrantLock(), _ModelRec[], String[], nothing,
        "running", nothing, false, false, nothing, nothing,
    )
    st.logio = open(joinpath(dir, "run.LOG"), "w")
    atexit(() -> st.finished || _finish!(st, "aborted"))      # SIGTERM: the hook runs
    _flushRun!(st)
    beat = Threads.@spawn :interactive begin
        while !st.finished
            sleep(heartbeat)
            st.finished || try
                _flushRun!(st)
            catch e
                e isa InterruptException && rethrow()
            end
        end
    end
    watcher = nothing
    if watchStdin
        watcher = Threads.@spawn :interactive begin
            try
                eof(stdinIo)
            catch e
                e isa InterruptException && rethrow()
            end
            if !st.finished
                # whoever started the run is gone: stop between models at the latest, and
                # by default at once (the files are finished, nothing is left running)
                st.abortRequested = true
                if exitOnEof
                    _finish!(st, "aborted")
                    exit(130)
                end
            end
        end
    end

    inputs = nothing
    cfg = nothing                       # the project's own, for the comparison
    plans = Dict{String,NamedTuple}()   # model name => (seedKw, cfg) of that model
    refs = Reference[]                  # the project's reference curves, from the snapshot
    dataFolder = ""                    # `TABLE_DIR`: where the data is also copied to
    status = "failed"
    try
        try
            models = _snapshotInputs(project, logs)
            for m in models
                push!(
                    st.models,
                    _ModelRec(
                        m.name,
                        m.path,
                        m.size,
                        m.sha256,
                        "pending",
                        nothing,
                        nothing,
                    ),
                )
            end
            settings = loadSettings(joinpath(logs, "settings.json"))
            _applyKeywords!(settings, given)
            dataFolder = settings[:TABLE_DIR]
            buffer = joinpath(logs, "buffer.json")
            solutes = loadBuffer(buffer)
            conditions = loadBufferPh(buffer)
            q, I, σ, energy = _readSnapshotData(logs)
            isempty(models) &&
                throw(ArgumentError("the project has no model (models/*.cif|pdb)"))
            seedKw = seedKeywords(settings)
            rows = _bufferObject(buffer, String[])[:solutes]
            snapshot = _solutesSnapshot(
                solutes, rows, conditions.pH, conditions.σ_pH, temperature,
                seedKw.pmvFallbackUncert,
            )
            _writeJsonAtomic(joinpath(logs, "solutes.json"), snapshot)
            inputsT = (; energy, q, I, σ, pH = conditions.pH, σ_pH = conditions.σ_pH,
                solutes, seedKw)
            # a bad reference file is a note in the ERRORS section and is skipped; it
            # neither fails the run nor changes its status
            refs, refProblems = _snapshotReferences(logs)
            for p in refProblems
                push!(st.errors, p)
                @warn p
            end
            st.rngSeed = rngSeed === :settings ? settings[:RNG_SEED] : rngSeed
            # what one fit is given: the settings of the project (the file, then the
            # keywords of this call) with the model's own on top (the file
            # `model-settings.json`, then the keyword `modelSettings`); a setting a
            # model gives is never overruled by the keywords of the project
            makeCfg = function (s, own)
                mine(names...) = any(in(own), names)
                nAdaptM =
                    mine(:N_ADAPT) ? s[:N_ADAPT] : something(nAdapt, s[:N_ADAPT])
                sigmaM =
                    mine(:VAL_SIGMA) ? s[:VAL_SIGMA] : something(sigma, s[:VAL_SIGMA])
                seedM =
                    mine(:RNG_SEED) || rngSeed === :settings ? s[:RNG_SEED] : rngSeed
                chainsM =
                    mine(:N_CHAINS) ? s[:N_CHAINS] : something(nChains, s[:N_CHAINS])
                nSamplesM =
                    mine(:N_ADAPT, :N_DRAWS) || nSamples === nothing ?
                    s[:N_ADAPT] + s[:N_DRAWS] : nSamples
                return (;
                    temperature = Float64(temperature),
                    nAdapt = nAdaptM, nSamples = nSamplesM, sigma = sigmaM,
                    δ = s[:TARGET_ACCEPT], rngSeed = seedM, retry,
                    nChains = chainsM, compare = s[:PLOT_COMPARE],
                    overrides = Pair{Symbol,Any}[n => s[n] for n in sort!(collect(own))],
                    runKw = merge(
                        runKeywords(s),
                        (; sigma = sigmaM, rngSeed = seedM, retry,
                            nChains = chainsM),
                    ),
                    resultsKw = merge(
                        resultsKeywords(s),
                        style === nothing ? (;) : (; style),
                    ),
                )
            end
            cfgT = makeCfg(settings, Set{Symbol}())
            file = joinpath(logs, MODEL_SETTINGS_FILE)
            fromFile =
                isfile(file) ? _readModelSettings(file) : Dict{String,Dict{Symbol,Any}}()
            fromKeyword = _checkModelKeywords(modelTable)
            for model in sort!(collect(union(keys(fromFile), keys(fromKeyword))))
                any(m -> m.name == model, st.models) && continue
                note =
                    "model settings: there is no model named $model (its settings " *
                    "are ignored)"
                push!(st.errors, note)
                @warn note
            end
            # the reference curve and χ² each model is given (`model-references.json`);
            # what is wrong with it is a note and the model has none
            refFile = joinpath(logs, MODEL_REFERENCES_FILE)
            ownRefs, refNotes =
                isfile(refFile) ? _readModelReferences(refFile) :
                (Dict{String,Dict{Symbol,Any}}(), String[])
            for model in sort!(collect(keys(ownRefs)))
                any(m -> m.name == model, st.models) && continue
                push!(
                    refNotes,
                    "model references: there is no model named $model (it is ignored)",
                )
            end
            qScale = _snapshotQScale(logs)
            for rec in st.models
                own = merge(
                    get(fromFile, rec.name, Dict{Symbol,Any}()),
                    get(fromKeyword, rec.name, Dict{Symbol,Any}()),
                )
                sM = _modelSettings(settings, own, "model $(rec.name)")
                rec.overrides = sort!(String.(collect(keys(own))))
                mref = _modelReference(
                    logs, rec.name, get(ownRefs, rec.name, Dict{Symbol,Any}()),
                    (q, I), qScale,
                )
                append!(refNotes, mref.problems)
                plans[rec.name] = (;
                    seedKw = seedKeywords(sM),
                    cfg = merge(
                        makeCfg(sM, keys(own)),
                        (; modelRef = (; mref.references, mref.refChi2)),
                    ),
                )
            end
            for note in refNotes
                push!(st.errors, note)
                @warn note
            end
            # only now is the run ready: a failure above leaves no model to start
            inputs, cfg = inputsT, cfgT
        catch e
            e isa InterruptException && rethrow()
            push!(st.errors, _errorText("inputs", e, catch_backtrace()))
            @error "the run cannot start: " * sprint(showerror, e)
        end

        # the header of run.LOG: the run and its conditions, as flat rows
        rows = [["datetime", _logStamp()], ["project", project],
            ["run", basename(dir)], ["ui", String(ui)],
            ["started", _isoUtc(st.started)],
            ["revision", _logRevision()], ["julia", string(VERSION)],
            ["baysol", _logVersion()], ["pid", string(getpid())],
            ["host", gethostname()], ["temperatureC", _logCell(Float64(temperature))]]
        if inputs !== nothing
            append!(
                rows,
                [["ph", _logCell(inputs.pH)], ["sigmaPh", _logCell(inputs.σ_pH)],
                    ["energyEv", _logCell(inputs.energy)],
                    ["models", string(length(st.models))],
                    ["rngSeed", string(cfg.rngSeed)]],
            )
        end
        _logAppend!(st, join(_tabLines(rows), "\n") * "\n\n--- output ---\n")
        _flushRun!(st)

        fitted = Pair{String,Any}[]      # the result of every model that finished
        function loop(tee)
            inputs === nothing && return nothing
            for rec in st.models
                st.abortRequested && throw(InterruptException())
                rec.status = "running"
                _flushRun!(st)
                t0 = time()
                println("=== model $(rec.name) ===")
                try
                    plan = plans[rec.name]
                    got = fit(
                        st, rec, merge(inputs, (; seedKw = plan.seedKw)), plan.cfg,
                        tee,
                    )
                    rec.plotSizes = _measuredPlotSizes(
                        st.dir, rec.name, plan.cfg.resultsKw.plotTuiSizes,
                    )
                    rec.status = "done"
                    # a fit that hands its result back is drawn into the comparison
                    got isa NamedTuple && haskey(got, :result) &&
                        push!(fitted, rec.name => got.result)
                catch e
                    e isa InterruptException && rethrow()
                    msg = sprint(showerror, e)
                    rec.status = "failed"
                    stage = joinpath(st.dir, ".stage-" * rec.name)
                    rm(stage; recursive = true, force = true)
                    rec.error = String(first(split(msg, '\n')))
                    text = _errorText("model $(rec.name)", e, catch_backtrace())
                    push!(st.errors, text)
                    println(stderr, "model $(rec.name) failed: " * _briefError(e))
                    try
                        _failedModelLog(
                            joinpath(st.dir, rec.name * ".LOG"), rec.name,
                            vcat(
                                [["temperatureC", _logCell(Float64(temperature))],
                                    ["ph", _logCell(inputs.pH)],
                                    ["sigmaPh", _logCell(inputs.σ_pH)],
                                    ["energyEv", _logCell(inputs.energy)]],
                                _overrideRows(plans[rec.name].cfg),
                            ), msg,
                        )
                    catch e2
                        e2 isa InterruptException && rethrow()
                    end
                end
                rec.seconds = time() - t0
                _flushRun!(st)
            end
            st.abortRequested && throw(InterruptException())
            cfg.compare && !isempty(fitted) &&
                _runCompare!(st, fitted, refs, (inputs.q, inputs.I, inputs.σ), cfg, tee)
            isempty(dataFolder) || _copyData!(st, dataFolder)
            return nothing
        end

        try
            tee ? _withTee(loop, st) : loop(nothing)
            status =
                any(m -> m.status == "failed", st.models) || inputs === nothing ?
                "failed" : "done"
        catch e
            e isa InterruptException || rethrow()
            status = "aborted"
        end
    catch e
        if e isa InterruptException       # in the inputs, or between two models
            status = "aborted"
        else
            # a bug of ours, not of a model: leave the files finished, then say what it was
            push!(st.errors, _errorText("runProject", e, catch_backtrace()))
            _finish!(st, "failed")
            rethrow()
        end
    finally
        st.finished || _finish!(st, st.abortRequested ? "aborted" : status)
    end
    return (; dir, status = Symbol(st.status),
        models = [(; name = m.name, status = Symbol(m.status)) for m in st.models])
end

end # module
