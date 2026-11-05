// SPDX-License-Identifier: LGPL-3.0-or-later

import { accessSync, constants, statSync } from "node:fs"
import { homedir } from "node:os"
import { delimiter, join } from "node:path"

/**
 * The facts about this machine and this run, read once. Every function of the
 * program that needs to know about the machine takes one of these, so it stays pure
 * and a test can pass a hand-made one.
 *
 * @property os - the platform (`"linux"`, `"darwin"`, `"win32"`, ...).
 * @property env - the environment variables.
 * @property home - the home folder of the user.
 * @property cwd - the working directory.
 */
export type System = {
    os:   NodeJS.Platform
    env:  Record<string, string | undefined>
    home: string
    cwd:  string
}

/**
 * Reads the facts about this machine.
 *
 * @returns the [[System]] of the running process.
 */
export function readSystem(): System {
    return { os: process.platform, env: process.env, home: homedir(), cwd: process.cwd() }
}

/** @returns `true` if `system` is a Windows. */
export const isWindows = (system: System): boolean => system.os === "win32"

/** @returns `true` if `system` is a Mac. */
export const isMac = (system: System): boolean => system.os === "darwin"

/** @returns `true` if `system` is a Linux. */
export const isLinux = (system: System): boolean => system.os === "linux"

/**
 * Finds a program the way a shell would.
 *
 * @param system - the machine; its `PATH` is searched (on Windows the extensions
 *     `.exe`, `.cmd` and `.bat` are tried too).
 * @param program - a name looked up on the `PATH`, or a path (anything with a `/`).
 * @returns the absolute path of the executable file, or `undefined` if there is none.
 */
export function findExecutable(system: System, program: string): string | undefined {
    const extensions = isWindows(system) ? ["", ".exe", ".cmd", ".bat"] : [""]
    const dirs = program.includes("/")
        ? [""]
        : (system.env.PATH ?? "").split(delimiter).filter((d) => d !== "")
    for (const dir of dirs) {
        for (const extension of extensions) {
            const file = join(dir, program + extension)
            try {
                accessSync(file, constants.X_OK)
                if (statSync(file).isFile()) return file
            } catch {
                // not here; try the next candidate
            }
        }
    }
    return undefined
}
