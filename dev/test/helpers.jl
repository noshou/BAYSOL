# SPDX-License-Identifier: LGPL-3.0-or-later

# Helpers shared by the test-*.jl files (loaded by runtests.jl).
module Helpers

using Dev
using Dev.Common

export run_tool, run_tool_call,
    scratch_dir, write_file, says, repo_dir, data_dir, capture_stdout, git_history

const repo_dir = Common.root()
const data_dir = joinpath(repo_dir, "dev", "test", "data")

"""
    run_tool(task, args...) -> (status, out)

Runs the tool `task` in this process with `args` and returns its exit status and its
stdout and stderr together.
"""
run_tool(task, args...) =
    run_tool_call(() -> Dev.main(task, String[string(a) for a in args]))

# Runs `f()` with stdout and stderr captured: (its value, the output).
function run_tool_call(f)
    path, io = mktemp()
    status = -1
    try
        redirect_stdio(stdout = io, stderr = io) do
            status = f()
        end
        close(io)
        return status, read(path, String)
    finally
        isopen(io) && close(io)
        rm(path; force = true)
    end
end

"""
    capture_stdout(f) -> String

What `f()` prints on stdout.
"""
function capture_stdout(f)
    path, io = mktemp()
    try
        redirect_stdout(f, io)
        close(io)
        return read(path, String)
    finally
        isopen(io) && close(io)
        rm(path; force = true)
    end
end

"Is the history of the fixed revisions of the golden files present?"
git_history() = all(
    rev -> success(
        pipeline(
            `git -C $repo_dir cat-file -e $(rev * "^{commit}")`; stdout = devnull,
            stderr = devnull),
    ),
    ["30f55ea", "81cf301", "24af397"])

"A fresh scratch directory (under the system temp folder; the caller removes it)."
scratch_dir() = mktempdir(; prefix = "cltests-", cleanup = true)

"Writes `text` to `path`, creating the folders."
function write_file(path, text)
    mkpath(dirname(path))
    write(path, text)
    return path
end

"Does the output `out` hold every one of `parts`?"
says(out, parts...) = all(p -> occursin(p, out), parts)

end
