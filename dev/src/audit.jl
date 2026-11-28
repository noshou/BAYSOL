# SPDX-License-Identifier: LGPL-3.0-or-later

# The audit of a built bundle: every executable and shared library in a folder, the
# shared libraries each one imports, and where a loader would find them. The headers
# of PE (Windows), ELF (Linux) and Mach-O (macOS) files are read in pure Julia, so no
# `objdump`, `readelf`, `otool` or `dumpbin` is needed, the same code reads all three
# formats on every system, and the tests run it on real files of any system's Julia
# or Node. The allowlists belong to the FORMAT of the file, not to the system the
# audit runs on (a Windows bundle audited on Linux is judged by the Windows list).
module Audit

using ..Common

const WHO = "bysl audit"

const USAGE = """
Audits a built bundle: the shared libraries its programs and libraries need.

    bysl audit DIR [--search DIR]... [--files] [--strict]

    DIR         the bundle (the folder `bysl pkg` stages as baysol/)
    --search    one more folder the launcher puts on the loader's search path (repeat it)
    --files     also list, for every binary, each library it needs and its status
    --strict    a library that relies on the system fails the audit too

Every PE (.exe, .dll), ELF (.so) and Mach-O (.dylib) file under DIR is read from its
headers, and each library it imports gets one status:

    bundle      found in the bundle where the loader of that format looks: beside the
                file, the bundle root and julia/ (PE), the RUNPATH or RPATH (ELF),
                @rpath, @loader_path and @executable_path (Mach-O)
    system      always present on a clean install of the system (kernel32, api-ms-win-*
                and the like; libc, libm and the dynamic loader; /usr/lib and
                /System/Library on macOS)
    relies      not carried and not always there: libstdc++, libgcc_s, libgomp,
                libatomic, libgfortran and libquadmath on Linux, the Visual C++ runtime
                (vcruntime140, msvcp140, ...) on Windows; the bundle depends on the
                machine having it
    MISSING     none of the above (the MinGW runtime of Julia on Windows, libgcc_s_seh-1,
                libgfortran-5, libstdc++-6, libwinpthread-1 and libquadmath-0, is
                always reported on its own: it is not a Windows system file)

Exit status 1 if anything is MISSING or a file cannot be read, 2 for a wrong command line.
"""

# --- reading headers

# `n` bytes at `off`.
function rd(io::IO, off::Integer, n::Integer)
    seek(io, off)
    b = read(io, n)
    length(b) == n || error("the file ends inside its headers")
    return b
end

# The unsigned integer of `n` bytes at `off`.
function uint(io::IO, off::Integer, n::Integer; be::Bool = false)::Int
    b = rd(io, off, n)
    be && reverse!(b)
    v = zero(UInt64)
    for i in n:-1:1
        v = v << 8 | b[i]
    end
    return Int(v)
end

# The NUL-terminated string at `off`.
cstr(io::IO, off::Integer) = (seek(io, off); String(readuntil(io, 0x00)))

"""
What a binary needs: the `format` (`:pe`, `:elf` or `:macho`), the names of the libraries
it imports (`needed`), the `rpaths` its loader searches (ELF `RUNPATH`/`RPATH`, Mach-O
`LC_RPATH`; empty for PE) and the `id` of a library (ELF SONAME, Mach-O install name).
"""
struct Needs
    format::Symbol
    needed::Vector{String}
    rpaths::Vector{String}
    id::String
end

# The imports of a PE file: the import table and the delay-load table.
function parse_pe(io::IO)::Union{Needs,Nothing}
    lfa = uint(io, 0x3c, 4)
    rd(io, lfa, 4) == UInt8[0x50, 0x45, 0, 0] || return nothing
    nsec = uint(io, lfa + 6, 2)
    osize = uint(io, lfa + 20, 2)
    opt = lfa + 24
    magic = uint(io, opt, 2)
    magic in (0x10b, 0x20b) || return nothing
    plus = magic == 0x20b
    ndd = uint(io, opt + (plus ? 108 : 92), 4)
    dd = opt + (plus ? 112 : 96)
    sections = map(0:(nsec-1)) do i
        s = opt + osize + 40i
        (va = uint(io, s + 12, 4), size = max(uint(io, s + 8, 4), uint(io, s + 16, 4)),
            raw = uint(io, s + 20, 4))
    end
    function offset(rva)
        for s in sections
            s.va <= rva < s.va + s.size && return rva - s.va + s.raw
        end
        error("an RVA outside every section")
    end
    names = String[]
    function walk(index, step, name_at)
        index < ndd || return
        rva = uint(io, dd + 8index, 4)
        rva == 0 && return
        o = offset(rva)
        for _ in 1:8192
            name = uint(io, o + name_at, 4)
            name == 0 && return
            push!(names, cstr(io, offset(name)))
            o += step
        end
    end
    walk(1, 20, 12)     # import directory
    walk(13, 32, 4)     # delay-load directory
    return Needs(:pe, unique(names), String[], "")
end

# The DT_NEEDED, RUNPATH/RPATH and SONAME entries of an ELF file.
function parse_elf(io::IO)::Union{Needs,Nothing}
    id = rd(io, 0, 16)
    id[5] in (1, 2) || return nothing
    wide = id[5] == 2
    be = id[6] == 2
    u(off, n) = uint(io, off, n; be)
    w = wide ? 8 : 4
    phoff = wide ? u(0x20, 8) : u(0x1c, 4)
    phentsize = u(wide ? 0x36 : 0x2a, 2)
    phnum = u(wide ? 0x38 : 0x2c, 2)
    loads = NamedTuple{(:vaddr, :size, :offset),NTuple{3,Int}}[]
    dynamic = nothing
    for i in 0:(phnum-1)
        p = phoff + i * phentsize
        type = u(p, 4)
        off, va, size =
            wide ? (u(p + 8, 8), u(p + 16, 8), u(p + 32, 8)) :
            (u(p + 4, 4), u(p + 8, 4), u(p + 16, 4))
        type == 1 && push!(loads, (vaddr = va, size = size, offset = off))
        type == 2 && (dynamic = (offset = off, size = size))
    end
    dynamic === nothing && return Needs(:elf, String[], String[], "")
    needed, runpath, rpath, soname = Int[], nothing, nothing, nothing
    strtab = nothing
    for i in 0:(dynamic.size÷(2w)-1)
        tag = u(dynamic.offset + 2w * i, w)
        val = u(dynamic.offset + 2w * i + w, w)
        tag == 0 && break
        tag == 1 && push!(needed, val)
        tag == 5 && (strtab = val)
        tag == 14 && (soname = val)
        tag == 15 && (rpath = val)
        tag == 29 && (runpath = val)
    end
    isempty(needed) && runpath === nothing && rpath === nothing && soname === nothing &&
        return Needs(:elf, String[], String[], "")
    strtab === nothing && error("a dynamic section without a string table")
    base = nothing
    for l in loads
        l.vaddr <= strtab < l.vaddr + l.size && (base = strtab - l.vaddr + l.offset)
    end
    base === nothing && error("a string table outside every segment")
    str(v) = cstr(io, base + v)
    # glibc ignores RPATH when RUNPATH is there
    path = runpath !== nothing ? str(runpath) : rpath !== nothing ? str(rpath) : ""
    return Needs(:elf, str.(needed), String.(filter(!isempty, split(path, ':'))),
        soname === nothing ? "" : str(soname))
end

const MACHO_LOAD = (0x0000000c, 0x00000020, 0x8000001f, 0x80000023)  # not the weak one
const MACHO_RPATH = 0x8000001c
const MACHO_ID = 0x0000000d

# The load commands of one Mach-O image that starts at `base`.
function parse_macho_at(io::IO, base::Int)
    magic = uint(io, base, 4)
    header = magic == 0xfeedfacf ? 32 : 28
    ncmds = uint(io, base + 16, 4)
    needed, rpaths, id = String[], String[], ""
    p = base + header
    for _ in 1:ncmds
        cmd = uint(io, p, 4)
        size = uint(io, p + 4, 4)
        size >= 12 || error("a damaged load command")
        name() = cstr(io, p + uint(io, p + 8, 4))
        cmd in MACHO_LOAD && push!(needed, name())
        cmd == MACHO_RPATH && push!(rpaths, name())
        cmd == MACHO_ID && (id = name())
        p += size
    end
    return needed, rpaths, id
end

# A Mach-O file: one image, or a fat file (every architecture's imports together).
function parse_macho(io::IO, magic::Int)::Needs
    bases = if magic in (0xcafebabe, 0xcafebabf)
        n = uint(io, 4, 4; be = true)
        step = magic == 0xcafebabe ? 20 : 32
        [
            uint(io, 8 + step * i + 8, magic == 0xcafebabe ? 4 : 8; be = true) for
            i in 0:(n-1)
        ]
    else
        [0]
    end
    parts = [parse_macho_at(io, b) for b in bases]
    return Needs(:macho, unique(reduce(vcat, first.(parts); init = String[])),
        unique(reduce(vcat, getindex.(parts, 2); init = String[])),
        isempty(parts) ? "" : parts[1][3])
end

"""
    binary_needs(io) -> Union{Needs,Nothing}

What the PE, ELF or Mach-O file in `io` needs; `nothing` for any other file. An error
(with a message) for a file that has the signature of one but a damaged header.
"""
function binary_needs(io::IO)::Union{Needs,Nothing}
    seekend(io)
    position(io) >= 64 || return nothing
    magic = rd(io, 0, 4)
    magic[1:2] == UInt8[0x4d, 0x5a] && return parse_pe(io)
    magic == UInt8[0x7f, 0x45, 0x4c, 0x46] && return parse_elf(io)
    le = uint(io, 0, 4)
    le in (0xfeedface, 0xfeedfacf) && return parse_macho(io, le)
    be = uint(io, 0, 4; be = true)
    # 0xcafebabe is also a Java class file: its next field is a version, not an image count
    be == 0xcafebabe && uint(io, 4, 4; be = true) < 32 && return parse_macho(io, be)
    be == 0xcafebabf && return parse_macho(io, be)
    return nothing
end

"The needs of the file `path`, or `nothing` if it is no binary."
binary_needs(path::AbstractString) = open(binary_needs, path)

# --- the allowlists (by format)

"The MinGW runtime of Julia on Windows: not a system file, the bundle must carry it."
const MINGW_RUNTIME = [
    "libgcc_s_seh-1.dll", "libgfortran-5.dll", "libstdc++-6.dll", "libwinpthread-1.dll",
    "libquadmath-0.dll"]

# Windows 10 and 11 always have these (System32, and the Universal C Runtime, which is part
# of the system since Windows 10). Lower case.
const WINDOWS_SYSTEM = Set(
    string.(
        [
            "kernel32", "kernelbase", "user32", "gdi32", "gdi32full", "win32u",
            "advapi32",
            "sechost", "ws2_32", "wsock32", "mswsock", "ntdll", "msvcrt", "ucrtbase",
            "shell32",
            "shlwapi", "ole32", "oleaut32", "combase", "comctl32", "comdlg32",
            "crypt32",
            "bcrypt", "bcryptprimitives", "ncrypt", "secur32", "sspicli", "userenv",
            "version",
            "winmm", "iphlpapi", "dbghelp", "dbgcore", "psapi", "imm32", "setupapi",
            "cfgmgr32",
            "rpcrt4", "normaliz", "wldap32", "dnsapi", "netapi32", "powrprof", "shcore",
            "uxtheme", "dwmapi", "msimg32", "wintrust", "cabinet", "nsi", "winhttp",
            "wininet",
            "urlmon", "wevtapi", "pdh", "mpr", "dxgi", "d3d11", "d3d12", "dwrite",
            "d2d1",
            "opengl32", "glu32", "hid", "avrt", "credui", "winspool", "userenv",
            "ntmarta",
            "mscoree", "propsys"], ".dll"),
)

# The Visual C++ redistributable: a part of Windows only if some other program installed it.
const WINDOWS_REDIST = Set(
    string.(
        [
            "vcruntime140", "vcruntime140_1", "msvcp140", "msvcp140_1", "msvcp140_2",
            "msvcp140_atomic_wait", "msvcp140_codecvt_ids", "concrt140", "vcomp140",
            "vccorlib140"], ".dll"),
)

# glibc, always there; matched on the file name.
const LINUX_SYSTEM = r"""
    ^(libc|libm|libdl|libpthread|librt|libutil|libresolv|libanl)\.so\.\d+$
    |^ld-linux[-\w.]*\.so\.\d+$
    |^ld64\.so\.\d+$
    |^linux-vdso
    """x

# Compiler runtimes that most desktop installs have and a minimal one lacks.
const LINUX_RELIES = r"""
    ^(libstdc\+\+\.so\.6|libgcc_s\.so\.1|libgomp\.so\.1|libatomic\.so\.1
    |libgfortran\.so\.\d+|libquadmath\.so\.\d+)$
    """x

"""
    system_class(format, lib) -> Symbol

`:system` (always present on a clean install), `:relies` (usually present, not
guaranteed) or `:unknown` for the library `lib` imported by a binary of `format`.
"""
function system_class(format::Symbol, lib::AbstractString)::Symbol
    if format == :pe
        l = lowercase(lib)
        (
            l in WINDOWS_SYSTEM || startswith(l, "api-ms-win-") ||
            startswith(l, "ext-ms-win-")
        ) &&
            return :system
        l in WINDOWS_REDIST && return :relies
    elseif format == :elf
        b = basename(lib)
        occursin(LINUX_SYSTEM, b) && return :system
        occursin(LINUX_RELIES, b) && return :relies
    elseif format == :macho
        (startswith(lib, "/usr/lib/") || startswith(lib, "/System/Library/")) &&
            return :system
    end
    return :unknown
end

# --- resolution

"""
A function `has(path, ci)` telling whether a file exists; `ci` asks for a case-insensitive
name match (PE: the file system of Windows ignores case, the loader too).
"""
function make_has()
    listings = Dict{String,Set{String}}()
    return function (path, ci)
        ci || return isfile(path)
        dir = dirname(path)
        names = get!(listings, dir) do
            isdir(dir) ? Set(lowercase.(readdir(dir))) : Set{String}()
        end
        return lowercase(basename(path)) in names
    end
end

# `$ORIGIN` and `\${ORIGIN}` of an ELF path, `@loader_path` and `@executable_path` of a
# Mach-O one.
function expand_path(p, loader_dir, exe_dir)
    p = replace(p, "\$ORIGIN" => loader_dir, "\${ORIGIN}" => loader_dir,
        "@loader_path" => loader_dir, "@executable_path" => exe_dir)
    return normpath(p)
end

"""
    candidates(needs, lib, file, root, search; inherited = String[]) -> Vector{String}

The full paths where the loader of the format of `needs` would look for `lib`, imported by
the `file` of the bundle `root`; `search` are extra folders for the loader. `inherited` are
folders of the `LC_RPATH` entries of the programs of the bundle, already expanded: dyld
resolves an `@rpath/` import with the rpaths of the whole chain of images that loaded the
file, up to the main executable, not with the file's own alone (a dylib of the bundle that
has no rpath of its own is found through the executable's).
"""
function candidates(
    n::Needs,
    lib,
    file,
    root,
    search;
    inherited = String[],
)::Vector{String}
    here = dirname(file)
    out = String[]
    if n.format == :pe
        dirs = [here, root, joinpath(root, "julia")]
        append!(out, joinpath.(dirs, lib))
    elseif n.format == :elf
        if occursin('/', lib)
            push!(out, lib)
        else
            append!(out, joinpath.(expand_path.(n.rpaths, here, root), lib))
        end
    else
        if startswith(lib, "@rpath/")
            rest = lib[8:end]
            append!(out, joinpath.(expand_path.(n.rpaths, here, root), rest))
            append!(out, joinpath.(inherited, rest))
        elseif startswith(lib, "@")
            push!(out, expand_path(lib, here, root))
        else
            push!(out, lib)
        end
    end
    # a bare name (or @rpath/name) is also looked up in the folders the launcher adds
    (!occursin('/', lib) || startswith(lib, "@rpath/")) &&
        append!(out, joinpath.(search, basename(lib)))
    return out
end

"One import of one binary: the `file` (relative to the bundle), its `format`, the `lib`."
struct Entry
    file::String
    format::Symbol
    lib::String
    status::Symbol          # :bundle, :system, :relies, :missing
    where::String           # the bundle path it was found at ("" otherwise)
end

"""
    classify(needs, lib, file, root; search = String[], has = make_has()) -> (status, where)

The status of the import `lib` of `file` (an absolute path in the bundle `root`): `:bundle`
with the path relative to the root (or the absolute path in a `search` folder), `:system`,
`:relies` or `:missing`.
"""
function classify(
    n::Needs,
    lib,
    file,
    root;
    search = String[],
    has = make_has(),
    inherited = String[],
)
    root = normpath(root)
    inside(c) =
        any(d -> startswith(normpath(c), normpath(d) * Base.Filesystem.path_separator),
            vcat([root], search))
    for c in candidates(n, lib, file, root, search; inherited)
        inside(c) && has(c, n.format == :pe) || continue
        startswith(normpath(c), root) &&
            return (:bundle, replace(relpath(c, root), '\\' => '/'))
        return (:bundle, c)
    end
    class = system_class(n.format, lib)
    class == :system && return (:system, "")
    class == :relies && return (:relies, "")
    return (:missing, "")
end

"""
    inherited_rpaths(root, items) -> Vector{String}

The folders of the `LC_RPATH` entries of the Mach-O programs of `items` (the files with no
install name, `@executable_path` and `@loader_path` being the program's own folder),
expanded: the `@rpath` search path every library it loads inherits.
"""
function inherited_rpaths(root, items)::Vector{String}
    dirs = String[]
    for (rel, n) in items
        (n.format == :macho && isempty(n.id)) || continue
        here = dirname(joinpath(root, rel))
        append!(dirs, expand_path.(n.rpaths, here, here))
    end
    return unique(dirs)
end

"""
    audit_imports(root, items; search = String[], has = make_has()) -> Vector{Entry}

Classifies every import of `items` (pairs of a file path relative to `root` and its
[`Needs`](@ref)). The imports of a file come in the order of its headers.
"""
function audit_imports(root, items; search = String[], has = make_has())
    entries = Entry[]
    inherited = inherited_rpaths(root, items)
    for (rel, n) in items
        file = joinpath(root, rel)
        for lib in n.needed
            status, where = classify(n, lib, file, root; search, has, inherited)
            push!(entries, Entry(rel, n.format, lib, status, where))
        end
    end
    return entries
end

"""
    scan(root) -> (items, unreadable)

Every binary under `root` as `rel => Needs` (sorted, `/` separators), and the files that
look like one but cannot be read as `rel => message`.
"""
function scan(root::AbstractString)
    items = Pair{String,Needs}[]
    unreadable = Pair{String,String}[]
    for (dir, _, files) in walkdir(root)
        for f in files
            path = joinpath(dir, f)
            isfile(path) || continue
            rel = replace(relpath(path, root), '\\' => '/')
            try
                n = binary_needs(path)
                n === nothing || push!(items, rel => n)
            catch err
                err isa Union{ErrorException,BoundsError,InexactError,ArgumentError,
                    EOFError,Base.IOError} || rethrow()
                push!(unreadable, rel => sprint(showerror, err))
            end
        end
    end
    return sort!(items; by = first), sort!(unreadable; by = first)
end

# --- the report

const ORDER = Dict(:missing => 1, :relies => 2, :bundle => 3, :system => 4)
const LABEL = Dict(:missing => "MISSING", :relies => "relies", :bundle => "bundle",
    :system => "system")

"""
    summary(entries) -> Vector{NamedTuple}

One row per library name (a name is compared as a file name: case-insensitive for PE): the
worst `status` over its importers, where it was `found`, and the importing `files`.
"""
function summary(entries)
    rows = Dict{String,Any}()
    for e in entries
        key = e.format == :pe ? lowercase(e.lib) : e.lib
        row = get!(rows, key,
            (lib = e.lib, status = e.status, found = e.where, files = String[]))
        row =
            ORDER[e.status] < ORDER[row.status] ?
            (lib = e.lib, status = e.status, found = e.where, files = row.files) : row
        push!(row.files, e.file)
        rows[key] = row
    end
    return sort!(collect(values(rows)); by = r -> (ORDER[r.status], lowercase(r.lib)))
end

# "a, b and 3 more", all of them when `all`.
function names_line(files, all)
    files = unique(files)
    (all || length(files) <= 3) && return join(files, ", ")
    return join(files[1:3], ", ") * " and $(length(files) - 3) more"
end

"""
    report(io, root, items, entries, unreadable; files = false, strict = false) -> Int

Prints the audit and returns its exit status: 1 for a MISSING library (with `strict`, a
library that relies on the system too) or an unreadable file, else 0.
"""
function report(io::IO, root, items, entries, unreadable; files = false, strict = false)
    counts = Dict{Symbol,Int}()
    for (_, n) in items
        counts[n.format] = get(counts, n.format, 0) + 1
    end
    kinds = join(
        [
            "$(counts[f]) $(uppercasefirst(string(f)))" for f in
            (:pe, :elf, :macho) if haskey(counts, f)
        ], ", ")
    println(io, "audit of ", root, ": ", length(items), " binaries",
        isempty(kinds) ? "" : " ($kinds)", ", ", length(entries), " imports")
    rows = summary(entries)
    if !isempty(rows)
        println(io)
        w = max(7, maximum(length(r.lib) for r in rows))
        wh = max(5, maximum(length(r.found) for r in rows))
        println(io, rpad("LIBRARY", w), "  ", rpad("STATUS", 7), "  ", rpad("FOUND", wh),
            "  NEEDED BY")
        for r in rows
            println(io, rpad(r.lib, w), "  ", rpad(LABEL[r.status], 7), "  ",
                rpad(r.found, wh), "  ",
                names_line(r.files, r.status in (:missing, :relies)))
        end
    end
    if any(((_, n),) -> n.format == :pe, items)
        println(io, "\nMinGW runtime (Julia on Windows; not a Windows system file):")
        for lib in MINGW_RUNTIME
            users = unique([e.file for e in entries if lowercase(e.lib) == lib])
            carried = any(((f, _),) -> lowercase(basename(f)) == lib, items)
            println(io, "  ", rpad(lib, 20), " imported by ", rpad(length(users), 4),
                " carried by the bundle: ", carried ? "yes" : "NO")
        end
    end
    if files
        for (rel, n) in items
            println(io, "\n", rel, "  (", n.format, ")")
            for e in filter(e -> e.file == rel, entries)
                println(io, "    ", rpad(LABEL[e.status], 7), " ", e.lib,
                    isempty(e.where) ? "" : "  -> " * e.where)
            end
        end
    end
    missing_n = count(r -> r.status == :missing, rows)
    relies_n = count(r -> r.status == :relies, rows)
    for (rel, msg) in unreadable
        println(io, "\nUNREADABLE ", rel, ": ", msg)
    end
    println(io, "\n", missing_n, " missing, ", relies_n, " rely on the system, ",
        length(unreadable), " unreadable")
    failed = missing_n > 0 || !isempty(unreadable) || (strict && relies_n > 0)
    return failed ? 1 : 0
end

"The tool's main program for the argument list `argv`; returns the exit status."
function run(argv::Vector{String})::Int
    if isempty(argv) || any(a -> a in ("--help", "-h"), argv)
        usage(USAGE)
        return isempty(argv) ? 2 : 0
    end
    a = split_args(WHO, ["--search"], ["--files", "--strict"], argv)
    length(a.specs) == 1 || fail(WHO, "give exactly one folder")
    # a trailing separator (`dir/` from a shell completion) would break the folder tests
    bare(p) = (q = abspath(p); length(q) > 3 ? rstrip(q, ['/', '\\']) : q)
    root = bare(a.specs[1])
    isdir(root) || fail(WHO, "no folder $root")
    search = [bare(v) for (k, v) in a.opts if k == "--search"]
    items, unreadable = scan(root)
    isempty(items) && fail(WHO, "no executable or library under $root")
    entries = audit_imports(root, items; search)
    return report(stdout, root, items, entries, unreadable; files = "--files" in a.flags,
        strict = "--strict" in a.flags)
end

end
