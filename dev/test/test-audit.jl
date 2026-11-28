# SPDX-License-Identifier: LGPL-3.0-or-later

# Tests of `bysl audit`: the header parsers (on real files of this machine and on small
# files built here), the allowlists, the search of the loaders (with injected file
# lists) and the report with its exit status.

using Test
using Dev
using Dev: Platform
using .Main.Helpers

const A = Dev.Audit

# --- files built here: the smallest ELF, Mach-O and PE files that carry imports

le(v, n) = UInt8[(v >> 8i) & 0xff for i in 0:(n-1)]
be(v, n) = reverse(le(v, n))
zeros_(n) = zeros(UInt8, n)

function fake_elf(needed; runpath = "", soname = "")
    strs = UInt8[0]
    add(s) = (o = length(strs); append!(strs, codeunits(s), 0x00); o)
    entries = Pair{Int,Int}[1 => add(n) for n in needed]
    isempty(runpath) || push!(entries, 29 => add(runpath))
    isempty(soname) || push!(entries, 14 => add(soname))
    dyn_at = 64 + 2 * 56
    str_at = dyn_at + 16 * (length(entries) + 2)
    base = 0x400000
    push!(entries, 5 => base + str_at, 0 => 0)
    total = str_at + length(strs)
    phdr(type, off, size) = vcat(le(type, 4), le(0, 4), le(off, 8), le(base + off, 8),
        le(base + off, 8), le(size, 8), le(size, 8), le(8, 8))
    return vcat(UInt8[0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0], zeros_(8), le(3, 2), le(62, 2),
        le(1, 4), le(0, 8), le(64, 8), le(0, 8), le(0, 4), le(64, 2), le(56, 2), le(2, 2),
        le(64, 2), le(0, 2), le(0, 2), phdr(1, 0, total),
        phdr(2, dyn_at, 16length(entries)),
        reduce(vcat, [vcat(le(k, 8), le(v, 8)) for (k, v) in entries]), strs)
end

function fake_macho(needed; rpaths = String[], id = "", weak = String[], fat = false)
    pad(s) = vcat(codeunits(s), zeros_(8 - length(codeunits(s)) % 8))
    dylib(c, s) = vcat(le(c, 4), le(24 + length(pad(s)), 4), le(24, 4), le(0, 4), le(0, 4),
        le(0, 4), pad(s))
    rpath(s) = vcat(le(0x8000001c, 4), le(12 + length(pad(s)), 4), le(12, 4), pad(s))
    cmds = UInt8[]
    foreach(n -> append!(cmds, dylib(0x0c, n)), needed)
    foreach(n -> append!(cmds, dylib(0x80000018, n)), weak)
    foreach(p -> append!(cmds, rpath(p)), rpaths)
    isempty(id) || append!(cmds, dylib(0x0d, id))
    n = length(needed) + length(weak) + length(rpaths) + !isempty(id)
    image = vcat(le(0xfeedfacf, 4), le(0x0100000c, 4), le(0, 4), le(2, 4), le(n, 4),
        le(length(cmds), 4), le(0, 4), le(0, 4), cmds)
    fat || return image
    return vcat(be(0xcafebabe, 4), be(1, 4), be(0x0100000c, 4), be(0, 4), be(32, 4),
        be(length(image), 4), be(14, 4), zeros_(4), image)
end

# A PE32+ file with one section at RVA 0x1000 (file offset 0x400): the import table at
# its start (20-byte descriptors), the delay-load table at +0x80 (32 bytes), the names at
# +0x100 (64 bytes apart).
function fake_pe(imports; delay = String[])
    sec = zeros(UInt8, 0x400)
    put(off, bytes) = (sec[(off+1):(off+length(bytes))] = bytes)
    for (i, n) in enumerate(vcat(imports, delay))
        rva = 0x1100 + 64(i - 1)
        put(rva - 0x1000, vcat(codeunits(n), 0x00))
        i <= length(imports) ? put(20(i - 1) + 12, le(rva, 4)) :
        put(0x80 + 32(i - length(imports) - 1) + 4, le(rva, 4))
    end
    dirs = vcat(zeros_(8), le(0x1000, 4), le(40, 4), zeros_(11 * 8), le(0x1080, 4),
        le(64, 4), zeros_(2 * 8))
    opt = vcat(le(0x20b, 2), zeros_(106), le(16, 4), dirs)
    opt = vcat(opt, zeros_(240 - length(opt)))
    section = vcat(codeunits(".idata\0\0"), le(0x400, 4), le(0x1000, 4), le(0x400, 4),
        le(0x400, 4), zeros_(16))
    head = vcat(codeunits("MZ"), zeros_(58), le(64, 4), codeunits("PE\0\0"), le(0x8664, 2),
        le(1, 2), zeros_(12), le(240, 2), le(0x2022, 2), opt, section)
    return vcat(head, zeros_(0x400 - length(head)), sec)
end

parse_bytes(bytes) = A.binary_needs(IOBuffer(bytes))

@testset "parsers on files built here" begin
    n = parse_bytes(
        fake_elf(["libc.so.6", "libfoo.so.1"];
            runpath = "\$ORIGIN:\$ORIGIN/julia", soname = "libme.so.1"),
    )
    @test n.format == :elf && n.needed == ["libc.so.6", "libfoo.so.1"]
    @test n.rpaths == ["\$ORIGIN", "\$ORIGIN/julia"] && n.id == "libme.so.1"
    @test parse_bytes(fake_elf(String[])).needed == String[]

    m = parse_bytes(
        fake_macho(["/usr/lib/libSystem.B.dylib", "@rpath/libx.dylib"];
            rpaths = ["@loader_path/../lib"], id = "@rpath/liby.dylib",
            weak = ["/opt/weak.dylib"]),
    )
    @test m.format == :macho
    @test m.needed == ["/usr/lib/libSystem.B.dylib", "@rpath/libx.dylib"]
    @test m.rpaths == ["@loader_path/../lib"] && m.id == "@rpath/liby.dylib"
    f = parse_bytes(fake_macho(["@rpath/libx.dylib"]; fat = true))
    @test f.format == :macho && f.needed == ["@rpath/libx.dylib"]

    p = parse_bytes(fake_pe(["KERNEL32.dll", "libfoo.dll"]; delay = ["WINHTTP.dll"]))
    @test p.format == :pe && p.needed == ["KERNEL32.dll", "libfoo.dll", "WINHTTP.dll"]

    text = codeunits("just a text file, long enough to pass the size check " ^ 3)
    @test parse_bytes(text) === nothing
    @test parse_bytes(UInt8[1, 2, 3]) === nothing
    @test_throws ErrorException parse_bytes(fake_elf(["libc.so.6"])[1:100])
end

@testset "parsers on real files of this machine" begin
    julia = joinpath(Sys.BINDIR, Platform.exe("julia"))
    n = A.binary_needs(julia)
    @test n !== nothing
    @test n.format == (Platform.iswindows() ? :pe : Platform.ismacos() ? :macho : :elf)
    @test any(l -> occursin("libjulia", l), n.needed)
    Platform.islinux() && @test !isempty(n.rpaths)
    Platform.iswindows() && @test any(l -> lowercase(l) == "kernel32.dll", n.needed)
    node = Platform.which("node")
    if node !== nothing
        nn = A.binary_needs(node)
        @test nn !== nothing && !isempty(nn.needed)
        Platform.iswindows() && @test any(l -> lowercase(l) == "kernel32.dll", nn.needed)
    end
    # the shared libraries of Julia are read too
    for dir in (Sys.BINDIR, joinpath(Sys.BINDIR, "..", "lib"))
        isdir(dir) || continue
        for f in
            filter(f -> occursin(r"^libjulia\.(dll|dylib|so(\.[\d.]+)?)$", f), readdir(dir))
            path = joinpath(dir, f)
            isfile(path) && !islink(path) && @test A.binary_needs(path) !== nothing
        end
    end
    @test A.binary_needs(@__FILE__) === nothing
end

@testset "system lists" begin
    sc = A.system_class
    @test sc(:pe, "KERNEL32.dll") == :system
    @test sc(:pe, "api-ms-win-crt-runtime-l1-1-0.dll") == :system
    @test sc(:pe, "ucrtbase.dll") == :system && sc(:pe, "WS2_32.dll") == :system
    @test sc(:pe, "VCRUNTIME140.dll") == :relies && sc(:pe, "msvcp140.dll") == :relies
    for lib in A.MINGW_RUNTIME
        @test sc(:pe, lib) == :unknown
    end
    @test sc(:pe, "python312.dll") == :unknown
    @test sc(:pe, "PROPSYS.dll") == :system
    @test sc(:elf, "libc.so.6") == :system && sc(:elf, "libm.so.6") == :system
    @test sc(:elf, "ld-linux-x86-64.so.2") == :system
    @test sc(:elf, "libpthread.so.0") == :system
    @test sc(:elf, "/lib64/ld-linux-x86-64.so.2") == :system
    @test sc(:elf, "libstdc++.so.6") == :relies && sc(:elf, "libgcc_s.so.1") == :relies
    @test sc(:elf, "libz.so.1") == :unknown && sc(:elf, "libcurl.so.4") == :unknown
    @test sc(:macho, "/usr/lib/libSystem.B.dylib") == :system
    @test sc(:macho, "/System/Library/Frameworks/CoreFoundation.framework/X") == :system
    @test sc(:macho, "/opt/homebrew/lib/libx.dylib") == :unknown
    @test sc(:macho, "@rpath/libx.dylib") == :unknown
end

# The `has` of a made-up bundle: the files are given, nothing is read from disk.
fake_has(files) = (path, ci) -> begin
    p = replace(path, '\\' => '/')
    ci ? lowercase(p) in lowercase.(files) : p in files
end

@testset "Mach-O: @rpath resolves through the rpaths of the executable" begin
    root = abspath(joinpath(tempdir(), "bundle"))
    r(p...) = replace(joinpath(root, p...), '\\' => '/')
    files = ["baysol", "julia/julia/libz.1.dylib", "lib/pytools/libpython3.12.dylib",
        "lib/pytools/baysol-pytools"]
    items = [
        "baysol" => A.Needs(:macho, ["@rpath/libz.1.dylib"],
            ["@executable_path/julia", "@executable_path/julia/julia"], ""),
        # a dylib without a rpath of its own asks for a sibling through the executable's
        "julia/julia/libcurl.4.dylib" =>
            A.Needs(:macho, ["@rpath/libz.1.dylib"], String[], "@rpath/libcurl.4.dylib"),
        "lib/pytools/baysol-pytools" =>
            A.Needs(:macho,
                ["@rpath/libpython3.12.dylib", "/usr/lib/libSystem.B.dylib"],
                ["@executable_path"], ""),
        "julia/julia/libz.1.dylib" =>
            A.Needs(:macho, String[], String[], "@rpath/libz.1.dylib"),
    ]
    @test A.inherited_rpaths(root, items) ==
          [joinpath(root, "julia"), joinpath(root, "julia", "julia"),
        joinpath(root, "lib", "pytools")]
    entries = A.audit_imports(root, items; has = fake_has(r.(files)))
    status = Dict((e.file, e.lib) => e.status for e in entries)
    @test status[("baysol", "@rpath/libz.1.dylib")] == :bundle
    @test status[("julia/julia/libcurl.4.dylib", "@rpath/libz.1.dylib")] == :bundle
    @test status[("lib/pytools/baysol-pytools", "@rpath/libpython3.12.dylib")] == :bundle
    @test status[("lib/pytools/baysol-pytools", "/usr/lib/libSystem.B.dylib")] == :system
    # a library nowhere on any rpath is still missing
    gone = A.audit_imports(root, items; has = fake_has(["baysol"]))
    @test any(e -> e.status == :missing && e.lib == "@rpath/libz.1.dylib", gone)
end

@testset "search of the loaders" begin
    root = abspath(joinpath(tempdir(), "bundle"))
    r(p...) = replace(joinpath(root, p...), '\\' => '/')
    cls(n, lib, file, files; search = String[]) =
        A.classify(n, lib, joinpath(root, file), root; search, has = fake_has(r.(files)))

    elf = A.Needs(:elf, String[], ["\$ORIGIN", "\$ORIGIN/julia"], "")
    files = ["baysol", "julia/libjulia.so.1", "julia/libstdc++.so.6", "lib/libz.so.1"]
    @test cls(elf, "libjulia.so.1", "baysol", files) == (:bundle, "julia/libjulia.so.1")
    @test cls(elf, "libc.so.6", "baysol", files) == (:system, "")
    @test cls(elf, "libstdc++.so.6", "baysol", files) == (:bundle, "julia/libstdc++.so.6")
    @test cls(elf, "libstdc++.so.6", "baysol", ["baysol"]) == (:relies, "")
    @test cls(elf, "libgcc_s.so.1", "baysol", ["baysol"]) == (:relies, "")
    @test cls(elf, "libfoo.so", "baysol", files) == (:missing, "")
    # ELF does not look beside the file unless the RUNPATH says so, nor in lib/
    none = A.Needs(:elf, String[], String[], "")
    @test cls(none, "libjulia.so.1", "baysol", files) == (:missing, "")
    @test cls(elf, "libz.so.1", "baysol", files) == (:missing, "")
    @test cls(elf, "libz.so.1", "baysol", files; search = [r("lib")]) ==
          (:bundle, "lib/libz.so.1")
    @test cls(elf, "libq.so", "baysol", ["baysol"]; search = [tempdir()]) == (:missing, "")
    # $ORIGIN is the folder of the file that imports
    up = A.Needs(:elf, String[], ["\$ORIGIN/.."], "")
    @test cls(up, "libz.so.1", "lib/x.so", ["lib/x.so", "libz.so.1"]) ==
          (:bundle, "libz.so.1")
    # a library outside the bundle does not count
    elsewhere = joinpath(tempdir(), "elsewhere")
    outside = A.Needs(:elf, String[], [elsewhere], "")
    @test cls(outside, "libq.so", "baysol", [elsewhere * "/libq.so"]) == (:missing, "")

    pe = A.Needs(:pe, String[], String[], "")
    pfiles = ["baysol.exe", "julia/libjulia.dll", "julia/libstdc++-6.dll",
        "libgcc_s_seh-1.dll"]
    @test cls(pe, "libjulia.dll", "baysol.exe", pfiles) == (:bundle, "julia/libjulia.dll")
    @test lowercase(cls(pe, "LIBJULIA.DLL", "baysol.exe", pfiles)[2]) ==
          "julia/libjulia.dll"
    @test cls(pe, "libgcc_s_seh-1.dll", "julia/libjulia.dll", pfiles) ==
          (:bundle, "libgcc_s_seh-1.dll")
    @test cls(pe, "KERNEL32.dll", "baysol.exe", pfiles) == (:system, "")
    @test cls(pe, "vcruntime140.dll", "baysol.exe", pfiles) == (:relies, "")
    @test cls(pe, "libwinpthread-1.dll", "baysol.exe", pfiles) == (:missing, "")

    mac = A.Needs(:macho, String[], ["@loader_path/../lib", "@executable_path/julia"], "")
    mfiles = ["baysol", "lib/libx.dylib", "julia/liby.dylib", "bin/helper"]
    @test cls(mac, "@rpath/libx.dylib", "bin/helper", mfiles) == (:bundle, "lib/libx.dylib")
    @test cls(mac, "@rpath/liby.dylib", "bin/helper", mfiles) ==
          (:bundle, "julia/liby.dylib")
    @test cls(mac, "@rpath/libz.dylib", "bin/helper", mfiles) == (:missing, "")
    @test cls(mac, "@loader_path/helper", "bin/x", mfiles) == (:bundle, "bin/helper")
    @test cls(mac, "@executable_path/lib/libx.dylib", "bin/helper", mfiles) ==
          (:bundle, "lib/libx.dylib")
    @test cls(mac, "/usr/lib/libSystem.B.dylib", "baysol", mfiles) == (:system, "")
    @test cls(mac, "/opt/homebrew/lib/libq.dylib", "baysol", mfiles) == (:missing, "")
end

@testset "report and exit status" begin
    root = abspath(joinpath(tempdir(), "bundle"))
    items = [
        "baysol" =>
            A.Needs(:elf, ["libc.so.6", "libgcc_s.so.1", "libfoo.so"], String[], ""),
        "app.dll" =>
            A.Needs(:pe, ["KERNEL32.dll", "libgcc_s_seh-1.dll", "msvcp140.dll"],
                String[], "")]
    entries = A.audit_imports(root, items; has = fake_has(String[]))
    status = Dict((e.file, e.lib) => e.status for e in entries)
    @test status[("baysol", "libc.so.6")] == :system
    @test status[("baysol", "libgcc_s.so.1")] == :relies
    @test status[("baysol", "libfoo.so")] == :missing
    @test status[("app.dll", "libgcc_s_seh-1.dll")] == :missing
    @test status[("app.dll", "msvcp140.dll")] == :relies
    out = IOBuffer()
    @test A.report(out, root, items, entries, Pair{String,String}[]) == 1
    text = String(take!(out))
    @test says(text, "2 binaries (1 Pe, 1 Elf)", "libfoo.so", "MISSING", "relies", "system",
        "libgcc_s_seh-1.dll   imported by 1", "carried by the bundle: NO",
        "2 missing, 2 rely on the system, 0 unreadable")
    # the worst status leads the table
    @test findfirst("MISSING", text).start < findfirst("relies", text).start <
          findfirst("system", text).start

    items2 = ["baysol" => A.Needs(:elf, ["libc.so.6", "libgcc_s.so.1"], String[], "")]
    entries2 = A.audit_imports(root, items2; has = fake_has(String[]))
    none = Pair{String,String}[]
    @test A.report(IOBuffer(), root, items2, entries2, none) == 0
    @test A.report(IOBuffer(), root, items2, entries2, none; strict = true) == 1
    @test A.report(IOBuffer(), root, items2, entries2, ["x.so" => "broken"]) == 1
    out = IOBuffer()
    A.report(out, root, items2, entries2, none; files = true)
    @test says(String(take!(out)), "baysol  (elf)", "system  libc.so.6",
        "relies  libgcc_s.so.1")
end

@testset "bysl audit on folders" begin
    @test run_tool("audit")[1] == 2
    @test run_tool("audit", "--help")[1] == 0
    @test run_tool("audit", "--bogus", "x")[1] == 2
    @test run_tool("audit", joinpath(tempdir(), "no such folder zzz"))[1] == 2
    dir = scratch_dir()
    @test run_tool("audit", dir)[1] == 2     # nothing to audit
    write_file(joinpath(dir, "baysol"),
        fake_elf(["libc.so.6", "libfoo.so"]; runpath = "\$ORIGIN"))
    status, out = run_tool("audit", dir)
    @test status == 1 && says(out, "libfoo.so", "MISSING", "1 missing")
    write_file(joinpath(dir, "libfoo.so"), fake_elf(["libc.so.6"]; soname = "libfoo.so"))
    status, out = run_tool("audit", dir)
    @test status == 0 && says(out, "2 binaries", "0 missing")
    # a trailing separator on the folder (shell completion) changes nothing
    status, out = run_tool("audit", dir * "/")
    @test status == 0 && says(out, "2 binaries", "0 missing")
    # a library the launcher puts on the loader's path: --search
    other = scratch_dir()
    write_file(joinpath(other, "libbar.so"), fake_elf(String[]))
    write_file(joinpath(dir, "baysol"), fake_elf(["libbar.so"]; runpath = "\$ORIGIN"))
    @test run_tool("audit", dir)[1] == 1
    @test run_tool("audit", dir, "--search", other)[1] == 0
    write_file(joinpath(dir, "broken.so"), fake_elf(["libc.so.6"])[1:100])
    status, out = run_tool("audit", dir, "--search", other)
    @test status == 1 && says(out, "UNREADABLE broken.so")
    # a Windows bundle, audited on any system
    pdir = scratch_dir()
    write_file(joinpath(pdir, "baysol.exe"),
        fake_pe(["KERNEL32.dll", "libgcc_s_seh-1.dll", "VCRUNTIME140.dll"]))
    status, out = run_tool("audit", pdir)
    @test status == 1 &&
          says(out, "libgcc_s_seh-1.dll", "VCRUNTIME140.dll", "relies", "MinGW runtime")
    write_file(joinpath(pdir, "libgcc_s_seh-1.dll"), fake_pe(["KERNEL32.dll"]))
    @test run_tool("audit", pdir)[1] == 0
    @test run_tool("audit", pdir, "--strict")[1] == 1
    # the programs and libraries of Julia on this system
    status, out = run_tool("audit", Sys.BINDIR)
    @test status in (0, 1) && says(out, "audit of", "imports")
    Platform.iswindows() && @test status == 0
end
