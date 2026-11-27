# SPDX-License-Identifier: LGPL-3.0-or-later

"""
    Platform

Operating-system detection and the helpers that depend on it: `os`/`arch` and the
`is...` predicates, the executable name, the `PATH` separator, a `which` that sees
Windows app-execution aliases, the data, cache, config and runtime folders, the shell,
the library search variable and the user id.
"""
module Platform

"""
    iswindows() -> Bool

Whether this is Windows.
"""
iswindows() = Sys.iswindows()

"""
    ismacos() -> Bool

Whether this is macOS.
"""
ismacos() = Sys.isapple()

"""
    isx64() -> Bool

Whether this Julia is an x86_64 build, on any system (Intel and AMD processors, and an Apple
Silicon Mac running the x86_64 build under Rosetta 2).
"""
isx64() = Sys.ARCH === :x86_64

"""
    ismacosx64() -> Bool

Whether this is macOS on an x86_64 Julia: an Intel Mac, or an Apple Silicon Mac running the
x86_64 build under Rosetta 2.
"""
ismacosx64() = ismacos() && isx64()

"""
    isrosetta() -> Bool

Whether this process is an x86_64 program translated by Rosetta 2 on an Apple Silicon Mac
(the kernel's `sysctl.proc_translated` is 1). `false` on every other system, and on an
Intel Mac, where the x86_64 program is native.
"""
function isrosetta()::Bool
    ismacosx64() || return false
    translated = Ref{Cint}(0)
    size = Ref{Csize_t}(sizeof(Cint))
    status = ccall(:sysctlbyname, Cint,
        (Cstring, Ref{Cint}, Ref{Csize_t}, Ptr{Cvoid}, Csize_t),
        "sysctl.proc_translated", translated, size, C_NULL, 0)
    return status == 0 && translated[] == 1
end

"""
    islinux() -> Bool

Whether this is Linux.
"""
islinux() = Sys.islinux()

"""
    isunix() -> Bool

Whether this is a Unix-like system (Linux, macOS, BSD): POSIX signals and permissions,
sockets as files, symbolic links without privileges.
"""
isunix() = Sys.isunix()

"""
    os() -> Symbol

The system: `:windows`, `:macos`, `:linux` or `:other`.
"""
os() = iswindows() ? :windows : ismacos() ? :macos : islinux() ? :linux : :other

"""
    arch() -> Symbol

The processor architecture of this Julia (`:x86_64`, `:aarch64`, ...).
"""
arch() = Sys.ARCH

"""
    describe() -> String

The system and the Julia target triple for a log (`"Linux x86_64-linux-gnu"`).
"""
describe() = string(Sys.KERNEL, " ", Sys.MACHINE)

"""
    exe(name) -> String

The file name of the executable `name`: `name.exe` on Windows, `name` elsewhere.
"""
exe(name::AbstractString) = iswindows() ? string(name, ".exe") : String(name)

"The separator of the entries of `PATH` and the like: `;` on Windows, `:` elsewhere."
const PATH_SEP = iswindows() ? ';' : ':'

"The characters that separate folders in a path as a user types it."
const DIR_SEPARATORS = iswindows() ? ['/', '\\'] : ['/']

"""
    which(name) -> Union{String,Nothing}

The path of the program `name` on the `PATH`, or `nothing`. `Sys.which` cannot see the
programs that Windows runs through an app-execution alias (juliaup's `julia.exe` in
`...\\Microsoft\\WindowsApps` is one: it is a reparse point, not a file), so on Windows a
name that `Sys.which` misses is looked up in the listing of every `PATH` folder.
"""
function which(name::AbstractString)::Union{String,Nothing}
    found = Sys.which(name)
    found === nothing || return found
    iswindows() || return nothing
    return _find_listed(split(get(ENV, "PATH", ""), PATH_SEP; keepempty = false), name)
end

# The file `name` in the listing of one of `dirs`, matched without regard to case (a Windows
# file system ignores it). A name without an extension also matches `name.exe`, `name.cmd`
# and `name.bat`, in that order, so that the `npm.cmd` beside the extensionless `npm` shell
# script (which Windows cannot start) is the one found. Windows only; `nothing` elsewhere.
function _find_listed(dirs, name::AbstractString)::Union{String,Nothing}
    iswindows() || return nothing
    basename(name) == name || return nothing
    lower = lowercase(name)
    wanted =
        any(endswith(lower, e) for e in (".exe", ".cmd", ".bat", ".com")) ? [lower] :
        [lower * ".exe", lower * ".cmd", lower * ".bat"]
    for dir in dirs
        isdir(dir) || continue
        entries = try
            readdir(dir)
        catch
            continue
        end
        for file in wanted
            i = findfirst(e -> lowercase(e) == file, entries)
            i === nothing || return joinpath(dir, entries[i])
        end
    end
    return nothing
end

"""
    tool_dirs(; env = ENV) -> Vector{String}

The folders in which an installer puts a developer tool without adding the folder to the
`PATH`, the ones that exist: on Windows the `7-Zip` and `LLVM/bin` folders of the Program
Files folders (`ProgramFiles`, `ProgramW6432` and `ProgramFiles(x86)`), on macOS Homebrew's
`bin` folders and its `llvm` one; none on Linux (the package managers there use the `PATH`).
"""
function tool_dirs(; env = ENV)::Vector{String}
    dirs = String[]
    if iswindows()
        for var in ("ProgramFiles", "ProgramW6432", "ProgramFiles(x86)")
            base = get(env, var, "")
            isempty(base) && continue
            append!(dirs, (joinpath(base, "7-Zip"), joinpath(base, "LLVM", "bin")))
        end
    elseif ismacos()
        append!(
            dirs,
            ("/opt/homebrew/bin", "/usr/local/bin", "/opt/homebrew/opt/llvm/bin",
                "/usr/local/opt/llvm/bin"),
        )
    end
    return unique(filter(isdir, dirs))
end

"""
    find_tool(names...; dirs = tool_dirs()) -> Union{String,Nothing}

The path of the first of the programs `names` that is on the `PATH` (see [`which`](@ref)),
else the first found in `dirs` (see [`tool_dirs`](@ref)); `nothing` if none. For the
tools the developer tools run by their full path, so that an installed 7-Zip or LLVM that
is not on the `PATH` still works. Use `which` where being on the `PATH` is the question.
"""
function find_tool(names::AbstractString...; dirs = tool_dirs())::Union{String,Nothing}
    for name in names
        found = which(name)
        found === nothing || return found
    end
    for name in names, dir in dirs
        for candidate in (exe(name), name)
            path = joinpath(dir, candidate)
            isfile(path) && return path
        end
    end
    return nothing
end

"""
    utc_offset(t = time()) -> Int

The offset of this machine's time zone from UTC, in seconds (east is positive), at the Unix
time `t`, daylight saving included. It is worked out here and not asked of the C library,
whose `strftime` `%z` prints the NAME of the zone on Windows ("Eastern Standard Time"), not
`-0500`: the local calendar fields of `t` (`Libc.TmStruct`), read as if they were UTC,
minus `t` itself (days from the civil date: Howard Hinnant's algorithm). The same on every
system.
"""
function utc_offset(t::Real = time())::Int
    ft = floor(Int, t)
    tm = Libc.TmStruct(ft)
    m = Int(tm.month) + 1
    y = Int(tm.year) + 1900 - (m <= 2)
    era = fld(y, 400)
    yoe = y - 400era
    doy = fld(153 * (m > 2 ? m - 3 : m + 9) + 2, 5) + Int(tm.mday) - 1
    days = 146097era + 365yoe + fld(yoe, 4) - fld(yoe, 100) + doy - 719468
    return 86400days + 3600Int(tm.hour) + 60Int(tm.min) + Int(tm.sec) - ft
end

"""
    utc_offset_text(t = time()) -> String

[`utc_offset`](@ref) as `+HHMM` or `-HHMM` (such as `-0500`), to the minute, the form the
logs and reports stamp their times with.
"""
function utc_offset_text(t::Real = time())::String
    minutes = round(Int, utc_offset(t) / 60)
    return string(minutes < 0 ? '-' : '+', lpad(abs(minutes) ÷ 60, 2, '0'),
        lpad(abs(minutes) % 60, 2, '0'))
end

# An absolute value of an environment variable, else `nothing`.
function _abs(env, name)
    v = strip(get(env, name, ""))
    return isabspath(v) ? String(v) : nothing
end

"""
    data_home(; env = ENV, home = homedir()) -> String

The folder of the system for application data: `%LOCALAPPDATA%` on Windows,
`~/Library/Application Support` on macOS, `\$XDG_DATA_HOME` or `~/.local/share` elsewhere.
A variable that is not an absolute path counts as unset.
"""
function data_home(; env = ENV, home = homedir(), system::Symbol = os())::String
    system === :windows && return something(_abs(env, "LOCALAPPDATA"),
        joinpath(home, "AppData", "Local"))
    system === :macos && return joinpath(home, "Library", "Application Support")
    return something(_abs(env, "XDG_DATA_HOME"), joinpath(home, ".local", "share"))
end

"""
    cache_home(; env = ENV, home = homedir()) -> String

The cache folder of the system: `%LOCALAPPDATA%` on Windows, `~/Library/Caches` on macOS,
`\$XDG_CACHE_HOME` or `~/.cache` elsewhere.
"""
function cache_home(; env = ENV, home = homedir(), system::Symbol = os())::String
    system === :windows && return something(_abs(env, "LOCALAPPDATA"),
        joinpath(home, "AppData", "Local"))
    system === :macos && return joinpath(home, "Library", "Caches")
    return something(_abs(env, "XDG_CACHE_HOME"), joinpath(home, ".cache"))
end

"""
    within(path, dir) -> Bool

Whether `path` is `dir` or inside it (compared on normal paths, any case on Windows).
"""
function within(path::AbstractString, dir::AbstractString)
    fold(s) = iswindows() ? lowercase(s) : String(s)
    p = rstrip(fold(normpath(path)), DIR_SEPARATORS)
    d = rstrip(fold(normpath(dir)), DIR_SEPARATORS)
    return p == d || startswith(p, d * Base.Filesystem.path_separator)
end

"""
    cache_dir(; env = ENV, home = homedir()) -> String

THE folder that holds BAYSOL's caches (`_structures`, and `_cache` for the developer tools;
see [`structure_cache`](@ref) and [`default_cache`](@ref)): `baysol` in the cache folder of
the system. Where the system has one folder for data and caches (Windows: `%LOCALAPPDATA%`)
that would lie inside the projects folder (`<data folder>/baysol`) and be swept up with the
work, so the caches go to the sibling `<data folder>/baysol-cache`. The TypeScript twin is
`cacheFolder` in `tui/src/core/environment.ts`; both tests pin the same paths.
"""
function cache_dir(; env = ENV, home = homedir(), system::Symbol = os())::String
    caches = joinpath(cache_home(; env, home, system), "baysol")
    projects = joinpath(data_home(; env, home, system), "baysol")
    return within(caches, projects) ? projects * "-cache" : caches
end

"""
    default_cache(; env = ENV, home = homedir()) -> String

The cache of the developer tools: `<cache_dir>/_cache`, where the unpacked test
fixtures live (its `fixtures` folder). Not read by the app, and not in
`install.json` (which has no `cache` field any more). Not changed by `BAYSOL_CACHE`.
"""
default_cache(; kw...)::String = joinpath(cache_dir(; kw...), "_cache")

"""
    default_structure_cache(; env = ENV, home = homedir()) -> String

The default cache: `<cache_dir>/_structures` (what `install.json`
calls `structureCache` and the setup wizard calls the cache
folder). Ignores `BAYSOL_CACHE`; see [`structure_cache`](@ref).
"""
default_structure_cache(; kw...)::String = joinpath(cache_dir(; kw...), "_structures")

"""
    structure_cache(; env = ENV, home = homedir()) -> String

The folder the fit reads as `BAYSOL_CACHE` (downloaded and generated structures,
components): `\$BAYSOL_CACHE` when that is an absolute path, else
[`default_structure_cache`](@ref). The launcher exports `install.json`'s `structureCache`
as `BAYSOL_CACHE`, which is this same folder for a default install.
"""
function structure_cache(; env = ENV, home = homedir(), system::Symbol = os())::String
    return something(_abs(env, "BAYSOL_CACHE"),
        default_structure_cache(; env, home, system))
end

"""
    tmp_dir(; base = tempdir()) -> String

THE folder of every temporary file BAYSOL makes: `baysol` in the temporary folder of the
system (the system wipes that on its own schedule; nothing in it must matter after the
program ends). One folder per process lies below it, see [`tmp_process_dir`](@ref); the
TUI sweeps the folders of dead processes at start. The TypeScript twin is `tmpFolder` in
`tui/src/core/environment.ts`; both tests pin the same names.
"""
tmp_dir(; base::AbstractString = tempdir())::String = joinpath(base, "baysol")

"""
    tmp_process_dir(pid = getpid(); base = tempdir()) -> String

The folder of one process below [`tmp_dir`](@ref): `<tmp_dir>/<pid>`. Not made here.
"""
tmp_process_dir(pid::Integer = getpid(); kw...)::String =
    joinpath(tmp_dir(; kw...), string(pid))

"""
    config_home(; env = ENV, home = homedir()) -> String

The configuration folder of the system: `%APPDATA%` on Windows,
`~/Library/Application Support` on macOS, `\$XDG_CONFIG_HOME` or `~/.config` elsewhere.
"""
function config_home(; env = ENV, home = homedir())::String
    iswindows() && return something(_abs(env, "APPDATA"),
        joinpath(home, "AppData", "Roaming"))
    ismacos() && return joinpath(home, "Library", "Application Support")
    return something(_abs(env, "XDG_CONFIG_HOME"), joinpath(home, ".config"))
end

"""
    runtime_home(; env = ENV, home = homedir()) -> String

Where a program keeps what lives as long as a login session (a daemon's state and
socket): `%LOCALAPPDATA%` on Windows, `\$TMPDIR` (else `/tmp`) on macOS,
`\$XDG_RUNTIME_DIR` (else `/tmp`) elsewhere.
"""
function runtime_home(; env = ENV, home = homedir())::String
    iswindows() && return data_home(; env, home)
    ismacos() && return get(env, "TMPDIR", "/tmp")
    return get(env, "XDG_RUNTIME_DIR", "/tmp")
end

"""
    user_id() -> String

An identifier of the current user that is safe in a file name: `%USERNAME%` on Windows,
the numeric user id elsewhere.
"""
user_id()::String =
    iswindows() ? get(ENV, "USERNAME", "user") : string(ccall(:getuid, Cuint, ()))

"""
    shell(; env = ENV) -> String

The user's command interpreter: `%COMSPEC%` (else `cmd.exe`) on Windows, `\$SHELL` (else
`/bin/sh`) elsewhere. A variable that is not an absolute path counts as unset.
"""
function shell(; env = ENV)::String
    iswindows() && return something(_abs(env, "COMSPEC"), "cmd.exe")
    return something(_abs(env, "SHELL"), "/bin/sh")
end

"""
    free_memory() -> Int

The memory, in bytes, that a program can still take without the system swapping out others.
`Sys.free_memory()`, except on macOS: there it counts only the pages that hold nothing at
all, a few per cent of the memory of any machine that has been up for a while, because
the system keeps the contents of files until someone asks for the memory. The macOS value
adds the inactive pages, but no more of them than there are file-backed pages
(`host_statistics64`): an anonymous page is only freed by compressing or swapping it.
`Sys.free_memory()` when the call fails.
"""
function free_memory()::Int
    ismacos() && return something(_mac_available_memory(), Int(Sys.free_memory()))
    return Int(Sys.free_memory())
end

# Free plus reclaimable memory of macOS in bytes; `nothing` when the kernel call fails.
function _mac_available_memory()::Union{Int,Nothing}
    ismacos() || return nothing
    # vm_statistics64 in 32-bit words (from 1): free_count 1, inactive_count 3,
    # speculative_count 24 (file-backed, and part of free_count already),
    # external_page_count 35
    info = zeros(UInt32, 64)
    count = Ref{Cuint}(38)                      # HOST_VM_INFO64_REV1_COUNT
    host = ccall(:mach_host_self, Cuint, ())
    status = ccall(:host_statistics64, Cint, (Cuint, Cint, Ptr{UInt32}, Ref{Cuint}),
        host, 4, info, count)                   # HOST_VM_INFO64
    status == 0 || return nothing
    files = max(Int(info[35]) - Int(info[24]), 0)
    pages = Int(info[1]) + min(Int(info[3]), files)
    # the kernel's page size, not `getpagesize()`: a process translated by Rosetta 2 is told
    # 4096 while the counts above are in the 16384-byte pages of the Apple Silicon kernel
    size = Ref{Csize_t}(0)
    ccall(:host_page_size, Cint, (Cuint, Ref{Csize_t}), host, size) == 0 || return nothing
    return pages * Int(size[])
end

"""
    library_path_variable() -> String

The environment variable the system's dynamic loader searches for shared libraries:
`PATH` on Windows, `DYLD_FALLBACK_LIBRARY_PATH` on macOS, `LD_LIBRARY_PATH` elsewhere.
"""
library_path_variable() =
    iswindows() ? "PATH" : ismacos() ? "DYLD_FALLBACK_LIBRARY_PATH" : "LD_LIBRARY_PATH"

end # module Platform
