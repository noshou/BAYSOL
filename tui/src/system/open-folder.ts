// SPDX-License-Identifier: LGPL-3.0-or-later

import { spawn, spawnSync } from "node:child_process"
import { findExecutable, isLinux, isMac, isWindows, type System } from "../core/system.js"

/**
 * "Open" for the projects folder: the desktop's file manager is tried, and a shell is
 * started in the folder with the terminal of this program. The macOS and Windows
 * commands come from documentation and are untested.
 */

/** How long to wait for the file manager's command to fail before assuming it worked, in
 * milliseconds: a file manager keeps running, so only a quick failure is a failure. */
const fileManagerWaitMs = 2000

/**
 * The commands to try, in order, to open a folder in the desktop's file manager.
 *
 * @param system - the machine.
 * @param dir - the folder.
 * @returns the command lines; empty for an unknown system.
 */
export function fileManagerCommands(system: System, dir: string): string[][] {
    if (isLinux(system))
        return [
            ["xdg-open", dir],
            ["gio", "open", dir],
        ]
    if (isMac(system)) return [["open", dir]]
    if (isWindows(system)) return [["explorer", dir]]
    return []
}

/**
 * The command that starts the user's shell: `$SHELL` (else `/bin/sh`) on Linux and
 * macOS, `%COMSPEC%` (else `cmd.exe`) on Windows.
 *
 * @param system - the machine.
 * @returns the command line.
 */
export function subshellCommand(system: System): string[] {
    if (isWindows(system)) return [system.env.COMSPEC || "cmd.exe"]
    return [system.env.SHELL || "/bin/sh"]
}

/**
 * Tries to open a folder in the file manager. Its output is discarded and it is never
 * killed; on Windows its exit code is ignored, because `explorer` returns 1 even when it
 * works.
 *
 * @param system - the machine.
 * @param dir - the folder.
 * @returns `undefined` if it worked, or a short reason if not.
 */
export function openFileManager(system: System, dir: string): Promise<string | undefined> {
    const command = fileManagerCommands(system, dir).find(([program]) =>
        findExecutable(system, program ?? ""),
    )
    if (!command) return Promise.resolve("no file manager command found")
    const [program, ...args] = command as [string, ...string[]]
    return new Promise((resolve) => {
        const child = spawn(program, args, { stdio: "ignore", detached: true })
        const timer = setTimeout(() => {
            child.unref()
            resolve(undefined)
        }, fileManagerWaitMs)
        child.once("error", (error) => {
            clearTimeout(timer)
            resolve(`could not start ${program}: ${error.message}`)
        })
        child.once("exit", (code) => {
            clearTimeout(timer)
            resolve(
                code === 0 || code === null || isWindows(system)
                    ? undefined
                    : `${program} exited with ${code}`,
            )
        })
    })
}

/**
 * Starts the user's shell in a folder, with this program's terminal, and waits for it.
 * The terminal must already be back to normal (the screen closed).
 *
 * @param system - the machine.
 * @param dir - the folder the shell starts in.
 * @returns a problem text if the shell could not be started, else `undefined`.
 */
export function runShellIn(system: System, dir: string): string | undefined {
    const [program, ...args] = subshellCommand(system) as [string, ...string[]]
    console.log(`BAYSOL: shell in ${dir} (type exit to return)`)
    const result = spawnSync(program, args, { cwd: dir, stdio: "inherit" })
    return result.error ? `could not start a shell: ${result.error.message}` : undefined
}

/**
 * The whole of "Open": the file manager is tried (a failure is reported through
 * `warn`), then a shell runs in the folder until the user leaves it.
 *
 * @param system - the machine.
 * @param dir - the projects folder.
 * @param warn - receives a warning text.
 * @returns a problem text if the shell could not be started, else `undefined`.
 */
export async function openFolder(
    system: System,
    dir: string,
    warn: (text: string) => void,
): Promise<string | undefined> {
    const reason = await openFileManager(system, dir)
    if (reason !== undefined) warn(`could not open the file manager: ${reason}`)
    return runShellIn(system, dir)
}
