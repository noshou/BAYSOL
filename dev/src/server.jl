# SPDX-License-Identifier: LGPL-3.0-or-later

# The daemon behind the launcher `dev/bysl.jl`: a Julia process that stays alive with the
# tools compiled, so a command costs milliseconds instead of a start-up and a compile.
module Server

using Sockets

using ..Dev
using ..Common: clear_cache!

"The environment variables a client passes on to the command it runs."
const PASSED_ENV = ("BAYSOL_ROOT", "JULIA", "BIOME", "NO_COLOR")

# The stderr connections waiting for their command, by id.
const ERR_SOCKETS = Dict{String,IO}()
const ERR_LOCK = ReentrantLock()
const WORK = ReentrantLock()

function read_request(sock)
    id = readline(sock)
    cwd = readline(sock)
    env = [readline(sock) for _ in 1:parse(Int, readline(sock))]
    args = [readline(sock) for _ in 1:parse(Int, readline(sock))]
    return id, cwd, env, args
end

function take_err(id)
    waited = timedwait(() -> lock(() -> haskey(ERR_SOCKETS, id), ERR_LOCK), 3.0)
    waited === :ok || return nothing
    return lock(() -> pop!(ERR_SOCKETS, id), ERR_LOCK)
end

function run_command(sock, state)
    id, cwd, env, args = read_request(sock)
    err = take_err(id)
    status = 1
    try
        lock(WORK) do
            pairs = [Pair(split(e, '='; limit = 2)...) for e in env]
            withenv(pairs...) do
                cd(cwd) do
                    redirect_stdout(sock) do
                        redirect_stderr(something(err, sock)) do
                            status = try
                                Dev.main(first(args), args[2:end])
                            catch e
                                showerror(stderr, e, catch_backtrace())
                                println(stderr)
                                1
                            end
                        end
                    end
                end
            end
        end
    finally
        write(joinpath(state, "status.$id"), string(status))
        err === nothing || close(err)
        close(sock)
    end
end

"""
    serve(state, socket; idle = 8 * 3600)

Runs the daemon on `socket` (a socket path, or a pipe name on Windows), keeping its start
stamp `state/started` and the status files of the commands in the directory `state`; it
stops on `STOP` or after `idle` seconds without a command (0: never; a dev session can be
much longer than half an hour, so the default is 8 hours).
"""
function serve(state::AbstractString, socket::AbstractString; idle::Real = 8 * 3600)
    mkpath(state)
    Sys.iswindows() || rm(socket; force = true)
    server = listen(socket)
    Sys.iswindows() || chmod(socket, 0o600)
    write(joinpath(state, "started"), string(getpid()))
    last = Ref(time())
    @async while isopen(server)
        sleep(5)
        (idle > 0 && time() - last[] > idle && !islocked(WORK)) && close(server)
    end
    try
        while true
            sock = accept(server)
            @async try
                last[] = time()
                head = readline(sock)
                if startswith(head, "ERR ")
                    lock(() -> ERR_SOCKETS[head[5:end]] = sock, ERR_LOCK)
                elseif head == "bysl1"
                    run_command(sock, state)
                elseif head == "PING"
                    println(sock, "pong")
                    close(sock)
                elseif head == "STOP"
                    close(sock)
                    close(server)
                else
                    close(sock)
                end
                last[] = time()
            catch e
                e isa Union{EOFError,Base.IOError} || @error "request failed" exception = e
                isopen(sock) && close(sock)
            end
        end
    catch e
        e isa Union{Base.IOError,EOFError} || rethrow()
    finally
        isopen(server) && close(server)
        Sys.iswindows() || rm(socket; force = true)
        rm(joinpath(state, "started"); force = true)
        # what the programs it ran created in the cache goes with it, but for the
        # structures and components (see `clear_cache!`)
        n = clear_cache!()
        println(stderr, "bysl daemon: cleared ", n, " cache files")
    end
    return nothing
end

end
