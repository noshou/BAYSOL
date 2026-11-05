// SPDX-License-Identifier: LGPL-3.0-or-later

import { spawn } from "node:child_process"
import { basename } from "node:path"
import { findExecutable, isLinux, isMac, isWindows, type System } from "../core/system.js"

/**
 * Opening a terminal emulator that runs a command, for a program started without a
 * terminal (from a desktop icon, say): which emulator to use on Linux (the user's
 * choice, the desktop's, then every known one), how each is told to run a command, and
 * the command lines for each system. The Linux command lines have been checked only as
 * far as they are built; the macOS and Windows ones come from documentation and are
 * untested.
 */

/** The environment variable set in a terminal this program opened, so that the copy
 * running there never opens another one if it still finds no terminal. */
export const inTerminalVar = "BAYSOL_IN_TERMINAL"

/** The terminal emulators tried when nothing says which to use, in this order. */
const genericTerminals = [
    // GNOME
    "ptyxis",
    "kgx",
    "gnome-terminal",
    // KDE
    "konsole",
    // XFCE, MATE
    "xfce4-terminal",
    "mate-terminal",
    // Other desktop environments
    "tilix",
    "deepin-terminal",
    "lxterminal",
    "qterminal",
    "terminology",
    "cosmic-term", // COSMIC
    "io.elementary.terminal", // elementary OS (Pantheon)
    "pantheon-terminal", // older name of the same
    // Popular GTK / Qt / lightweight terminals
    "terminator",
    "sakura",
    "roxterm",
    "lilyterm",
    "mlterm",
    "zutty",
    "termite", // no longer developed, still installed on older systems
    // Standalone / Wayland / X11 terminals
    "ghostty",
    "kitty",
    "wezterm",
    "alacritty",
    "foot",
    "contour",
    "rio",
    "xterm",
    "uxterm",
    "urxvt",
    "rxvt",
    "st",
]

/**
 * The terminals that belong to a desktop environment, by the lower-case parts of
 * `XDG_CURRENT_DESKTOP` (for example `ubuntu:GNOME` gives `ubuntu` and `gnome`).
 */
const desktopTerminals: Record<string, string[]> = {
    kde: ["konsole"],
    gnome: ["ptyxis", "kgx", "gnome-terminal"],
    unity: ["gnome-terminal"],
    "x-cinnamon": ["gnome-terminal"],
    cinnamon: ["gnome-terminal"],
    xfce: ["xfce4-terminal"],
    mate: ["mate-terminal"],
    lxqt: ["qterminal"],
    lxde: ["lxterminal"],
    cosmic: ["cosmic-term"],
    pantheon: ["io.elementary.terminal", "pantheon-terminal"],
    deepin: ["deepin-terminal"],
    enlightenment: ["terminology"],
}

/**
 * How a terminal emulator is told to run a command instead of a shell: the arguments
 * that go between its name and the command. `-e` is the convention of xterm and most
 * others follow it, so it is the default. Verified in the Clojure version: konsole
 * (`-e`); the rest is from the programs' documentation and untested.
 */
const execFlags: Record<string, string[]> = {
    "xdg-terminal-exec": [], // takes the command directly
    "gnome-terminal": ["--"],
    "xfce4-terminal": ["-x"],
    "mate-terminal": ["-x"],
    terminator: ["-x"],
    kitty: [],
    foot: [],
    wezterm: ["start", "--"],
}

/** The flag of a terminal that is not in [[execFlags]]. */
const defaultExecFlags = ["-e"]

/** The title of the console window that Windows opens when there is no Windows Terminal. */
const windowsTitle = "BAYSOL"

/** The shell script that runs `"$@"` in the folder `$1` (nothing is spliced in). */
const inDirectoryScript = 'cd "$1" && shift && exec "$@"'

/**
 * The terminal emulators to try on Linux, most wanted first: the user's own choice
 * (`$TERMINAL`), the freedesktop default (`xdg-terminal-exec`), the terminals of the
 * current desktop (`XDG_CURRENT_DESKTOP`), the distribution's default
 * (`x-terminal-emulator`), then every other known terminal.
 *
 * @param system - the machine; its environment is read.
 * @returns the names, without repeats.
 */
export function terminalCandidates(system: System): string[] {
    const own = (system.env.TERMINAL ?? "").trim()
    const desktops = (system.env.XDG_CURRENT_DESKTOP ?? "")
        .split(":")
        .map((d) => d.toLowerCase())
    const all = [
        ...(own !== "" ? [own] : []),
        "xdg-terminal-exec",
        ...desktops.flatMap((d) => desktopTerminals[d] ?? []),
        "x-terminal-emulator",
        ...genericTerminals,
    ]
    return [...new Set(all)]
}

/**
 * The command line that opens a terminal running a command.
 *
 * @param terminal - the terminal, a name or a path.
 * @param command - the command and its arguments.
 * @returns the terminal, its flags for running a command, then the command.
 */
export function terminalCommand(terminal: string, command: string[]): string[] {
    const flags = execFlags[basename(terminal)] ?? defaultExecFlags
    return [terminal, ...flags, ...command]
}

/**
 * The command that runs another one from a folder, on Linux and macOS. The arguments of
 * `sh -c` are passed, not spliced into a string, so no quoting is needed.
 *
 * @param dir - the folder.
 * @param command - the command and its arguments.
 * @returns the `sh -c` command line.
 */
export function inDirectoryCommand(dir: string, command: string[]): string[] {
    return ["sh", "-c", inDirectoryScript, "sh", dir, ...command]
}

/**
 * A string as one word for a Unix shell: in single quotes, with each single quote
 * inside written as `'\''`.
 *
 * @param s - the string.
 * @returns the quoted word.
 */
export function shellQuote(s: string): string {
    return `'${s.replaceAll("'", "'\\''")}'`
}

/**
 * The command line that opens Terminal.app on macOS running a command in a folder: an
 * AppleScript, with the shell line given as an argument of the script. Untested.
 *
 * @param dir - the folder.
 * @param command - the command and its arguments.
 * @returns the `osascript` command line.
 */
export function macTerminalCommand(dir: string, command: string[]): string[] {
    return [
        "osascript",
        "-e",
        "on run argv",
        "-e",
        'tell application "Terminal" to do script (item 1 of argv)',
        "-e",
        'tell application "Terminal" to activate',
        "-e",
        "end run",
        `cd ${shellQuote(dir)} && exec ${command.map(shellQuote).join(" ")}`,
    ]
}

/**
 * The command line that opens a terminal on Windows running a command in a folder.
 * Untested.
 *
 * @param windowsTerminal - `true` if Windows Terminal (`wt.exe`) is installed.
 * @param dir - the folder.
 * @param command - the command and its arguments.
 * @returns Windows Terminal if it is installed, otherwise a new console window through
 *     `cmd`.
 */
export function windowsTerminalCommand(
    windowsTerminal: boolean,
    dir: string,
    command: string[],
): string[] {
    return windowsTerminal
        ? ["wt.exe", "-d", dir, ...command]
        : ["cmd.exe", "/c", "start", windowsTitle, "/D", dir, ...command]
}

/**
 * The outcome of looking for a way to open a terminal: the command line, or why there
 * is none.
 */
export type TerminalChoice = { command: string[] } | { problem: string }

/**
 * The command line that opens a terminal emulator running a command, from the working
 * directory of the machine, on its operating system.
 *
 * @param system - the machine (`cwd` is where the command runs; `PATH` is searched).
 * @param command - the command and its arguments.
 * @returns the command line, or a problem: no installed Linux terminal, or an
 *     unsupported system.
 */
export function openTerminalCommand(system: System, command: string[]): TerminalChoice {
    if (isLinux(system)) {
        const terminal = terminalCandidates(system)
            .map((name) => findExecutable(system, name))
            .find((path) => path !== undefined)
        return terminal
            ? {
                  command: terminalCommand(
                      terminal,
                      inDirectoryCommand(system.cwd, command),
                  ),
              }
            : { problem: "No supported Linux terminal emulator found" }
    }
    if (isMac(system)) return { command: macTerminalCommand(system.cwd, command) }
    if (isWindows(system)) {
        const wt = findExecutable(system, "wt.exe") !== undefined
        return { command: windowsTerminalCommand(wt, system.cwd, command) }
    }
    return { problem: `Unsupported operating system: ${system.os}` }
}

/**
 * The command that runs this program again, with the same runtime and arguments.
 *
 * @param execPath - the runtime (`process.execPath`).
 * @param execArgv - its own arguments (`process.execArgv`, such as the loader of `tsx`).
 * @param argv - the program's `process.argv` (the script and its arguments follow the
 *     runtime).
 * @returns the command line.
 */
export function programCommand(
    execPath: string,
    execArgv: string[],
    argv: string[],
): string[] {
    return [execPath, ...execArgv, ...argv.slice(1)]
}

/** What the entry point does at start: see [[startAction]]. */
export type StartAction = "run" | "relaunch" | "fail"

/**
 * What to do at start-up: run here if there is a terminal; else, unless this already is
 * the copy a terminal emulator was opened for, open one; else fail.
 *
 * @param hasTerminal - `true` if standard input and output are a terminal.
 * @param system - the machine; `BAYSOL_IN_TERMINAL` is read.
 * @returns `"run"`, `"relaunch"` or `"fail"` (the copy with the variable set and still
 *     no terminal prints an error and exits with 1, so it never opens a second one).
 */
export function startAction(hasTerminal: boolean, system: System): StartAction {
    if (hasTerminal) return "run"
    return system.env[inTerminalVar] ? "fail" : "relaunch"
}

/**
 * Starts a command without waiting for it: output discarded, detached from this
 * process, with extra environment variables.
 *
 * @param command - the command and its arguments; an empty one does nothing.
 * @param system - the machine whose environment the process gets.
 * @param extraEnv - variables added to it.
 * @returns a problem text if it could not be started, else `undefined`.
 */
export async function launchDetached(
    command: string[],
    system: System,
    extraEnv: Record<string, string> = {},
): Promise<string | undefined> {
    const [program, ...args] = command
    if (program === undefined) return "no command to launch"
    return new Promise((resolve) => {
        const child = spawn(program, args, {
            detached: true,
            stdio: "ignore",
            env: { ...system.env, ...extraEnv },
        })
        child.once("error", (error) =>
            resolve(`could not start ${program}: ${error.message}`),
        )
        child.once("spawn", () => {
            child.unref()
            resolve(undefined)
        })
    })
}

/**
 * Opens a terminal emulator that runs this program again (with `BAYSOL_IN_TERMINAL=1`).
 *
 * @param system - the machine.
 * @param program - the command that runs this program (see [[programCommand]]).
 * @returns a problem text, or `undefined` if the terminal was started.
 */
export async function relaunchInTerminal(
    system: System,
    program: string[],
): Promise<string | undefined> {
    const choice = openTerminalCommand(system, program)
    if ("problem" in choice) return choice.problem
    return launchDetached(choice.command, system, { [inTerminalVar]: "1" })
}

/**
 * @returns `true` if standard input and output are a terminal. (`TERM` says nothing
 *     about it: programs without a terminal inherit it.)
 */
export function hasTerminal(): boolean {
    return Boolean(process.stdin.isTTY && process.stdout.isTTY)
}
