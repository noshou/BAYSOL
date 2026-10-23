# SPDX-License-Identifier: LGPL-3.0-or-later

# Exercises the lookup order of `component` for an id that is not in the bundled table
# (src/MolecularStructure/Components.jl): the cache directory first, then a download
# into it through the injectable hook `_COMPONENT_DOWNLOAD`. The hook is replaced by a
# fake here, so nothing touches the network. The component files come from
# test/fixtures/components/ (real RCSB files for PSU, 5MC and ATP) with the residue id
# rewritten to an id that is not in the table, so every case is a miss of the table.
# The cache directory is the real one (`_store_dir()/components`) and only files of
# the fake ids are created in it, and removed again.
include(joinpath(@__DIR__, "..", "testsetup.jl"))

# Everything below lives in a module of its own, so that the helpers and constants of this
# file cannot clash with those of another file when the aggregator includes them all into
# Main.
module NtTest_componentcache

using Test
using BAYSOL

using BAYSOL.MolecularStructure: component, is_nucleotide, ComponentError,
    _COMPONENT_DOWNLOAD, _COMPONENT_MEMO, _COMPONENT_TABLE, _ComponentNotFound,
    _component_path, _parse_component, _download_default, _store_dir,
    COMPONENT_CACHE_DIR, COMPONENT_URL
using BAYSOL.Runtime: force
using Downloads: Downloads, RequestError
using Sockets: Sockets

const _COMPONENT_FIXTURES = joinpath(@__DIR__, "..", "..", "fixtures", "components")

# the real file of a component, with its id rewritten to `id`
function _component_text(fixture::AbstractString, id::AbstractString)
    text = read(joinpath(_COMPONENT_FIXTURES, fixture * ".cif"), String)
    return replace(text, Regex("\\b" * fixture * "\\b") => id)
end

# ids that are in neither the table nor the Amber names, found deterministically
function _free_ids(n::Integer)
    table = force(_COMPONENT_TABLE)
    ids = String[]
    alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    for a in alphabet, b in alphabet
        id = "QQ" * a * b
        (haskey(table, id) || haskey(BAYSOL.MolecularStructure.AMBER_NUCLEIC_NAMES, id)) &&
            continue
        push!(ids, id)
        length(ids) == n && return ids
    end
    return ids
end

# A fake hook: records (url, dest) of every call (thread safe) and answers by `behavior`,
# a function (url, dest, id) -> nothing
mutable struct _FakeHook <: Function
    calls::Vector{Tuple{String,String}}
    lock::ReentrantLock
    behavior::Function
end
_FakeHook(behavior) = _FakeHook(Tuple{String,String}[], ReentrantLock(), behavior)
function (h::_FakeHook)(url::AbstractString, dest::AbstractString)
    @lock h.lock push!(h.calls, (String(url), String(dest)))
    id = splitext(basename(url))[1]
    return h.behavior(String(url), String(dest), id)
end
ncalls(h) = @lock h.lock length(h.calls)

_serve(fixture) = (url, dest, id) -> write(dest, _component_text(fixture, id))

@testset "component cache and download hook" begin
    cache_dir = joinpath(_store_dir(), COMPONENT_CACHE_DIR)
    ids = _free_ids(12)
    saved_hook = _COMPONENT_DOWNLOAD[]
    reset!() = empty!(_COMPONENT_MEMO)
    install!(h) = (_COMPONENT_DOWNLOAD[] = h; reset!(); h)
    cleanup!() = foreach(id -> rm(_component_path(id); force = true), ids)
    cleanup!()
    # the cache directory listing, to see that failures leave nothing behind
    listing() = isdir(cache_dir) ? sort(readdir(cache_dir)) : String[]
    before = listing()

    try
        @testset "the fake ids are unknown to the table" begin
            @test length(ids) == 12
            table = force(_COMPONENT_TABLE)
            @test all(id -> !haskey(table, id), ids)
            @test COMPONENT_CACHE_DIR == "components"
            @test _component_path(ids[1]) == joinpath(cache_dir, ids[1] * ".cif")
            @test occursin("{ID}", COMPONENT_URL)
        end

        @testset "a table hit never touches the cache or the hook" begin
            h = install!(_FakeHook((u, d, i) -> error("must not be called")))
            # a garbage file in the cache under a table id is never read either
            garbage = _component_path("PSU")
            existed = isfile(garbage)
            if !existed
                mkpath(dirname(garbage))
                write(garbage, "this is not a component file\n")
            end
            try
                psu = component("PSU")
                @test psu.source === :builtin && psu.class === :rna
                @test is_nucleotide("5MC") && !is_nucleotide("HOH")
                @test component("DA").source === :builtin
                @test component("RA").source === :builtin   # an Amber alias
                @test ncalls(h) == 0
            finally
                existed || rm(garbage; force = true)
            end
        end

        @testset "a cached file is used and the hook is never called" begin
            id = ids[1]
            h = install!(_FakeHook((u, d, i) -> error("must not be called")))
            mkpath(cache_dir)
            write(_component_path(id), _component_text("PSU", id))
            c = component(id)
            @test c.source === :cache && c.id == id
            @test c.class === :rna && c.type == "rna linking"
            @test c.parent == "U" && c.formula == "C9 H13 N2 O9 P" && c.n_hydrogens == 13
            @test c.base == "U" && c.base_source === :parent
            @test is_nucleotide(id)
            @test ncalls(h) == 0
            # a second lookup (from the memo) says the same
            @test component(id) == c
            @test ncalls(h) == 0
            # lower case reaches the same file
            reset!()
            @test component(lowercase(id)) == c
            @test ncalls(h) == 0
        end

        @testset "cached files of other kinds of component" begin
            h = install!(_FakeHook((u, d, i) -> error("must not be called")))
            mkpath(cache_dir)
            # a modified cytidine: the parent's base is the base
            write(_component_path(ids[2]), _component_text("5MC", ids[2]))
            c = component(ids[2])
            @test c.class === :rna && c.parent == "C" && c.base == "C" &&
                  c.n_hydrogens == 16
            # a ligand: not a nucleotide, no parent, no base
            write(_component_path(ids[3]), _component_text("ATP", ids[3]))
            a = component(ids[3])
            @test a.class === :other && a.parent === nothing && a.base === nothing
            @test a.base_source === :none && a.n_hydrogens == 16 && !is_nucleotide(ids[3])
            # a nucleotide without a declared parent has no base either
            txt = replace(
                _component_text("PSU", ids[4]),
                r"(_chem_comp.mon_nstd_parent_comp_id\s+)U" => s"\1?",
            )
            write(_component_path(ids[4]), txt)
            n = component(ids[4])
            @test n.class === :rna && n.parent === nothing && n.base === nothing
            @test n.base_source === :none && is_nucleotide(ids[4])
            # the id inside the file is matched case-insensitively
            write(_component_path(ids[5]), lowercase(_component_text("PSU", ids[5])))
            @test component(ids[5]).class === :rna
            @test ncalls(h) == 0
        end

        @testset "the fixture files agree with the table" begin
            for id in ("PSU", "5MC", "ATP")
                path = joinpath(_COMPONENT_FIXTURES, id * ".cif")
                @test isfile(path)
                f = _parse_component(id, path, :cache)
                t = component(id)
                @test (f.class, f.type, f.parent, f.formula, f.n_hydrogens) ==
                      (t.class, t.type, t.parent, t.formula, t.n_hydrogens)
                @test f.base == t.base && f.source === :cache
            end
        end

        @testset "a miss downloads into the cache, once" begin
            id = ids[6]
            h = install!(_FakeHook(_serve("PSU")))
            then = listing()
            @test !isfile(_component_path(id))
            c = component(id)
            @test c.source === :download && c.class === :rna && c.parent == "U"
            @test ncalls(h) == 1
            url, dest = only(h.calls)
            @test url == replace(COMPONENT_URL, "{ID}" => id)
            @test isfile(_component_path(id))
            # the hook wrote to a temporary file, not to the final path
            @test dest != _component_path(id) && basename(dest) == id * ".cif"
            @test !ispath(dest)
            # the file in the cache is the one the hook wrote
            @test read(_component_path(id), String) == _component_text("PSU", id)
            # later lookups never go back to the hook: the memo, then the cache
            @test component(id).source === :cache
            reset!()
            @test component(id).source === :cache
            @test ncalls(h) == 1
            # no stray temporary directory is left in the cache
            @test setdiff(listing(), then) == [id * ".cif"]
            # ids are matched case-insensitively and the file is named in upper case
            id2 = ids[7]
            h2 = install!(_FakeHook(_serve("5MC")))
            @test component(lowercase(id2)).id == id2
            @test isfile(_component_path(id2)) && ncalls(h2) == 1
            @test component(id2).base == "C"
            @test ncalls(h2) == 1
        end

        @testset "a failed download leaves nothing behind" begin
            base = listing()
            for (label, behavior) in (
                "offline" => (u, d, i) -> throw(ErrorException("could not resolve host")),
                "garbage" => (u, d, i) -> write(d, "<html>Service Unavailable</html>\n"),
                "empty" => (u, d, i) -> write(d, ""),
                "partial then error" =>
                    (u, d, i) -> (
                        write(d, first(_component_text("PSU", i), 300));
                        throw(ErrorException("connection reset"))
                    ),
                "another component" => (u, d, i) -> write(d, _component_text("PSU", "ZZ9")),
            )
                id = ids[8]
                h = install!(_FakeHook(behavior))
                @test_throws ComponentError component(id)
                @test ncalls(h) == 1
                @test !isfile(_component_path(id))
                @test listing() == base
            end
            # the error says what happened
            h = install!(
                _FakeHook((u, d, i) -> throw(ErrorException("could not resolve host"))),
            )
            e = try
                component(ids[8])
                nothing
            catch err
                err
            end
            @test e isa ComponentError
            msg = sprint(showerror, e)
            @test startswith(msg, "ComponentError: ")
            @test occursin("couldn't look up residue $(ids[8]); are you offline?", msg)
            @test occursin("could not resolve host", msg)
            # a failure is not remembered: the same id works once the network is back
            install!(_FakeHook(_serve("PSU")))
            @test component(ids[8]).source === :download
            @test isfile(_component_path(ids[8]))
        end

        @testset "a 404 means unknown residue, not an error" begin
            id = ids[9]
            h = install!(_FakeHook((u, d, i) -> throw(_ComponentNotFound(u))))
            then = listing()
            c = component(id)
            @test c.id == id && c.class === :other && c.type == "unknown"
            @test c.parent === nothing && c.formula == "" && c.n_hydrogens == 0
            @test c.base === nothing && c.base_source === :none
            @test c.source === :download
            @test !is_nucleotide(id)
            @test ncalls(h) == 1                 # remembered for the process
            @test !isfile(_component_path(id))   # nothing cached
            @test listing() == then
            # after a reset the question is asked again
            reset!()
            @test component(id).type == "unknown"
            @test ncalls(h) == 2
        end

        @testset "invalid ids are unknown, bad cached files are errors" begin
            h = install!(_FakeHook((u, d, i) -> error("must not be called")))
            # a name that cannot be a wwPDB id is an unknown residue, without any lookup
            for bad in ("", "  ", "TOOLONG", "AB-CD", "A B", "../X", "a/b", "K+")
                c = component(bad)
                @test c.class === :other && c.type == "unknown" && c.parent === nothing
                @test c.base === nothing && !is_nucleotide(bad)
            end
            @test ncalls(h) == 0
            @test ncalls(h) == 0
        end

        @testset "invalid cached files are ignored, removed and fetched again" begin
            mkpath(cache_dir)
            for (k, bad) in (
                (10, "not a cif at all\n"),
                (11, _component_text("PSU", "ZZ9")),                     # another component
                (12, first(_component_text("PSU", ids[12]), 300)),       # truncated
            )
                id = ids[k]
                h = install!(_FakeHook(_serve("PSU")))
                write(_component_path(id), bad)
                c = component(id)
                @test c.source === :download && c.class === :rna && c.parent == "U"
                @test ncalls(h) == 1
                @test read(_component_path(id), String) == _component_text("PSU", id)
            end
            # a file with the id but without type or formula is not usable either
            id = ids[9]
            h = install!(_FakeHook(_serve("PSU")))
            write(
                _component_path(id),
                replace(
                    _component_text("PSU", id),
                    r"_chem_comp.formula\s+\"[^\"]*\"" => "",
                ),
            )
            @test component(id).source === :download && ncalls(h) == 1
            # a download whose file is invalid is an error and nothing is cached
            cleanup!()
            for (label, behavior) in (
                "no formula" =>
                    (u, d, i) -> write(
                        d,
                        replace(
                            _component_text("PSU", i),
                            r"_chem_comp.formula\s+\"[^\"]*\"" => "",
                        )),
                "truncated" => (u, d, i) -> write(d, first(_component_text("PSU", i), 300)),
                "wrong id" => (u, d, i) -> write(d, _component_text("PSU", "ZZ9")),
            )
                h = install!(_FakeHook(behavior))
                base = listing()
                @test_throws ComponentError component(ids[10])
                @test ncalls(h) == 1
                @test !isfile(_component_path(ids[10])) && listing() == base
            end
        end

        @testset "concurrent callers fetch once" begin
            id = ids[12]
            gate = Base.Event()
            h = install!(
                _FakeHook((u, d, i) -> (wait(gate); write(d, _component_text("PSU", i)))),
            )
            tasks = [Threads.@spawn(component(id)) for _ in 1:8]
            yield()
            notify(gate)
            results = fetch.(tasks)
            @test ncalls(h) == 1
            @test all(r -> r.id == id && r.class === :rna, results)
            @test count(r -> r.source === :download, results) <= 1
            @test all(r -> r.source in (:download, :cache), results)
            @test component(id).source === :cache
            @test isfile(_component_path(id))
            # and for a failing id every caller gets the error
            cleanup!()
            reset!()
            h = install!(_FakeHook((u, d, i) -> throw(ErrorException("offline"))))
            tasks = [Threads.@spawn(try
                component(ids[12])
            catch e
                e
            end) for _ in 1:6]
            results = fetch.(tasks)
            @test all(r -> r isa ComponentError, results)
            @test !isfile(_component_path(ids[12]))
        end

        @testset "the default hook" begin
            # a file:// URL stands for a server answering 200
            dest = tempname()
            try
                src = joinpath(_COMPONENT_FIXTURES, "PSU.cif")
                @test _download_default("file://" * abspath(src), dest) === nothing
                @test read(dest, String) == read(src, String)
                # any other failure is rethrown as it is (not turned into "unknown")
                err = try
                    _download_default(
                        "file://" * joinpath(tempdir(), "no-such-file.cif"),
                        tempname())
                    nothing
                catch e
                    e
                end
                @test err !== nothing && !(err isa _ComponentNotFound)
            finally
                rm(dest; force = true)
            end
            # a loopback server answering one request: 200, 404 and 500
            for (status, body) in (
                (200, read(joinpath(_COMPONENT_FIXTURES, "5MC.cif"), String)),
                (404, ""), (500, "oops"),
            )
                server = Sockets.listen(Sockets.localhost, 0)
                port = Int(Sockets.getsockname(server)[2])
                task = @async begin
                    sock = Sockets.accept(server)
                    readuntil(sock, "\r\n\r\n")   # the request, up to its blank line
                    write(
                        sock,
                        "HTTP/1.1 $status X\r\nContent-Length: $(ncodeunits(body))\r\n" *
                        "Connection: close\r\n\r\n$body",
                    )
                    close(sock)
                end
                url = "http://127.0.0.1:$port/ligands/download/QQ0.cif"
                dest = tempname()
                try
                    if status == 200
                        @test _download_default(url, dest) === nothing
                        @test read(dest, String) == body
                    elseif status == 404
                        err = try
                            _download_default(url, dest)
                            nothing
                        catch e
                            e
                        end
                        @test err isa _ComponentNotFound && err.url == url
                    else
                        @test_throws RequestError _download_default(url, dest)
                    end
                    wait(task)
                finally
                    close(server)
                    rm(dest; force = true)
                end
            end
            @test _ComponentNotFound("u").url == "u"
            @test _COMPONENT_DOWNLOAD[] isa Function
        end
    finally
        _COMPONENT_DOWNLOAD[] = saved_hook
        empty!(_COMPONENT_MEMO)
        cleanup!()
    end
    # the cache directory is as it was
    @test listing() == before
end

end # module
