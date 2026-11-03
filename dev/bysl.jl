#!/usr/bin/env -S julia --startup-file=no -O0 --compile=min
# SPDX-License-Identifier: LGPL-3.0-or-later

# The launcher of the dev tools, one script for Linux, macOS and Windows:

using Sockets
using SHA

const HERE = dirname(abspath(@__FILE__))
const ROOT = dirname(HERE)
const PKG = HERE
const JULIA_EXE = get(ENV, "JULIA", "julia")

# One daemon per checkout and user: its state folder and socket are named after both.
const KEY = bytes2hex(sha256(ROOT))[1:12]
const USER =
    Sys.iswindows() ? get(ENV, "USERNAME", "user") :
    string(ccall(:getuid, Cuint, ()))
const STATE_DIR = if Sys.iswindows()
    joinpath(
        get(
            ENV,
            "LOCALAPPDATA",
            joinpath(
                homedir(),
                "AppData",
                "Local",
            ),
        ),
        "bysl",
        KEY,
    )
elseif Sys.isapple()
    joinpath(get(ENV, "TMPDIR", "/tmp"), "bysl-$USER-$KEY")
else
    joinpath(get(ENV, "XDG_RUNTIME_DIR", "/tmp"), "bysl-$USER-$KEY")
end
const SOCKET =
    Sys.iswindows() ? "\\\\.\\pipe\\bysl-$USER-$KEY" :
    joinpath(STATE_DIR, "sock")
const STARTED_FILE = joinpath(STATE_DIR, "started")
const LOG_FILE = joinpath(STATE_DIR, "log")

# The tools that start long Julia processes run in a process of their own.
const OWN_PROCESS = ("fits", "docs", "unit", "test", "precommit", "vis")

# Runs the tool in a fresh Julia process, with this terminal, and exits with its status.
function run_direct(args)
    expr = "using Dev; exit(Dev.main(ARGS[1], ARGS[2:end]))"
    cmd = `$JULIA_EXE --startup-file=no --project=$PKG -e $expr $args`
    exit(run(ignorestatus(cmd)).exitcode)
end

# The daemon's reply to `message` (a line), or "" when it does not answer within `timeout`
# seconds.
function ask(message::String; timeout = 3.0)
    reply = Channel{String}(1)
    @async try
        s = Sockets.connect(SOCKET)
        println(s, message)
        put!(reply, readline(s))
        close(s)
    catch
        put!(reply, "")
    end
    timedwait(() -> isready(reply), timeout; pollint = 0.002) === :ok ? take!(reply) : ""
end

alive() = ask("PING") == "pong"

# Has a tool source changed since the daemon started?
function stale()
    isfile(STARTED_FILE) || return false
    started = mtime(STARTED_FILE)
    for target in (joinpath(PKG, "src"), joinpath(PKG, "Project.toml"))
        if isdir(target)
            for (dir, _, files) in walkdir(target), f in files
                mtime(joinpath(dir, f)) > started && return true
            end
        elseif isfile(target) && mtime(target) > started
            return true
        end
    end
    return false
end

function stop_daemon()
    alive() && ask("STOP"; timeout = 1.0)
    for _ in 1:50
        alive() || return true
        sleep(0.1)
    end
    return false
end

function start_daemon()
    mkpath(STATE_DIR)
    Sys.iswindows() || chmod(STATE_DIR, 0o700)
    idle  = get(ENV, "BYSL_IDLE", "28800")
    expr1 = "using Dev;"
    expr2 = " Dev.Server.serve(ARGS[1], ARGS[2]; idle = parse(Int, ARGS[3]))"
    expr  = expr1 * expr2
    cmd   = `$JULIA_EXE --startup-file=no --project=$PKG -e $expr $STATE_DIR $SOCKET $idle`
    log   = open(LOG_FILE, "w")
    # `detach` puts the daemon in a process group of its own, so a Ctrl-C meant for a
    # command does not reach it and it outlives the terminal
    run(pipeline(detach(cmd); stdout = log, stderr = log); wait = false)
    close(log)
    for _ in 1:600
        alive() && return true
        sleep(0.1)
    end
    println(stderr, "bysl: the daemon did not start (see $LOG_FILE)")
    return false
end

# Sends the command to the daemon, relays its output and returns its exit status.
function run_in_daemon(args)
    id = string(getpid(), ".", rand(1:32767))
    env = [
        "$v=$(ENV[v])" for
        v in ("BAYSOL_ROOT", "JULIA", "BIOME", "NO_COLOR") if haskey(ENV, v)
    ]
    # stderr travels on a connection of its own, stdout on the command's
    err = Sockets.connect(SOCKET)
    println(err, "ERR ", id)
    relay_err = @async try
        while !eof(err)
            write(stderr, readavailable(err))
        end
    catch e
        e isa Base.IOError || rethrow()
    end
    out = Sockets.connect(SOCKET)
    io = IOBuffer()
    println(io, "bysl1\n", id, "\n", pwd(), "\n", length(env))
    foreach(line -> println(io, line), env)
    println(io, length(args))
    foreach(a -> println(io, a), args)
    write(out, take!(io))
    # a reader that has gone away (`| head`) ends
    # the relay; the command finishes in the daemon
    try
        while !eof(out)
            write(stdout, readavailable(out))
        end
    catch e
        e isa Base.IOError || rethrow()
    end
    wait(relay_err)
    close(out)
    close(err)
    status_file = joinpath(STATE_DIR, "status.$id")
    isfile(status_file) || return 1
    status = parse(Int, strip(read(status_file, String)))
    rm(status_file; force = true)
    return status
end

function manage_daemon(sub)
    if sub == "start"
        alive() ? println("bysl: daemon already running") :
        start_daemon() && println("bysl: daemon running")
    elseif sub == "stop"
        stop_daemon() && println("bysl: daemon stopped")
    elseif sub == "restart"
        stop_daemon()
        start_daemon() && println("bysl: daemon running")
    elseif sub == "status"
        println(alive() ? "bysl: daemon running ($STATE_DIR)" : "bysl: no daemon")
    else
        println(stderr, "usage: bysl daemon start|stop|status|restart")
        exit(2)
    end
    exit(0)
end

function main(args)
    isempty(args) && (args = ["help"])
    args[1] == "daemon" && manage_daemon(get(args, 2, "status"))
    (haskey(ENV, "BYSL_DIRECT") || args[1] in OWN_PROCESS) && run_direct(args)
    for a in args
        if '\n' in a
            println(stderr, "bysl: an argument holds a newline")
            exit(2)
        end
    end
    if alive()
        if stale()
            (stop_daemon() && start_daemon()) || run_direct(args)
        end
    else
        start_daemon() || run_direct(args)
    end
    status = try
        run_in_daemon(args)
    catch
        # the daemon went away mid-command: run it here instead
        run_direct(args)
    end
    exit(status)
end

main(ARGS)
