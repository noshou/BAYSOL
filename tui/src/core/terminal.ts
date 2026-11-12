// SPDX-License-Identifier: LGPL-3.0-or-later

// Terminal: text as the terminal draws it (cell widths, truncating, wrapping, numbers),
// whether there is a terminal and how to open one.
//
// Contents:
//   1. Text: cell widths, truncating, wrapping and number parsing
//   2. Terminal: whether there is one
//   3. Launch: opening a terminal emulator that runs a command

import { spawn } from "node:child_process"
import { basename } from "node:path"
import stringWidth from "string-width"
import wrapAnsi from "wrap-ansi"
import { findExecutable, isLinux, isMac, isWindows, type System } from "./environment.js"

// ========================================================================================
// 1. Text: cell widths, truncating, wrapping and number parsing
// ========================================================================================

/**
 * Text measured in terminal cells, not in characters: a wide character (CJK, most
 * emoji) takes two cells, a combining mark none. Cut text gets `…`, and a wide
 * character is never split.
 */

/** What marks text that was cut. */
const ellipsis = "…"

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" })

/** The cells a text takes. */
export function displayWidth(text: string): number {
    return stringWidth(text)
}

/**
 * The longest start of a text that fits in some cells.
 *
 * @returns the start of `text` at most `cells` wide, cut at a character boundary.
 */
export function takeWidth(text: string, cells: number): string {
    let out = ""
    let used = 0
    for (const { segment } of graphemes.segment(text)) {
        const w = stringWidth(segment)
        if (used + w > cells) break
        out += segment
        used += w
    }
    return out
}

/** Cuts a text to some cells, ending in `…` if it had to be cut. */
export function truncate(text: string, cells: number): string {
    if (cells <= 0) return ""
    if (stringWidth(text) <= cells) return text
    return takeWidth(text, cells - 1) + ellipsis
}

/**
 * Cuts a text to some cells from the front, keeping its end (a path that is too long
 * shows where it ends).
 */
export function truncateStart(text: string, cells: number): string {
    if (cells <= 0) return ""
    if (stringWidth(text) <= cells) return text
    const parts = [...graphemes.segment(text)].map((s) => s.segment)
    let out = ""
    let used = 1
    for (let i = parts.length - 1; i >= 0; i--) {
        const w = stringWidth(parts[i])
        if (used + w > cells) break
        out = parts[i] + out
        used += w
    }
    return ellipsis + out
}

/** Pads a text with spaces on the right to some cells. */
export function padWidth(text: string, cells: number): string {
    const cut = truncate(text, cells)
    return cut + " ".repeat(Math.max(0, cells - stringWidth(cut)))
}

/** Breaks a text into lines of at most some cells, at spaces where it can. */
export function wrapText(text: string, cells: number): string[] {
    return wrapAnsi(text, Math.max(1, cells), { hard: true, trim: true }).split("\n")
}

/**
 * One output line as the rows of a panel: a line that is too wide is wrapped at spaces
 * (never cut with an ellipsis), the continuation rows indented two cells further than
 * the line itself, so nothing of what Julia printed is lost off the right edge.
 *
 * @param line - the line.
 * @param columns - the cells of a row.
 * @returns the rows, at least one.
 */
export function wrapLine(line: string, columns: number): string[] {
    if (displayWidth(line) <= columns) return [line]
    const lead = line.length - line.trimStart().length
    const room = Math.max(4, columns - lead - 2)
    const pieces = wrapText(line.trimStart(), room)
    return pieces.map((piece, i) => " ".repeat(lead + (i === 0 ? 0 : 2)) + piece)
}

/**
 * The note that tells a cap was reached while typing a `what` (`name`, `text`). The one
 * place the wording lives.
 */
export function tooLong(what: string, max: number): string {
    return `${what} too long (${max} at most)`
}

/** The problem of a name that is blank (the wording of every name prompt). */
export const NAME_BLANK = "type a name first!"

/** The problem of a name with a control character in it. */
export const NAME_CONTROL = "no control characters"

/** The problem of a name that another entry has. */
export const NAME_IN_USE = "name in use"

/** The text the way names are compared: trimmed and lower-cased. */
export function fold(text: string | null | undefined): string {
    return (text ?? "").trim().toLowerCase()
}

/**
 * Orders two texts without regard to case, by code unit (never by locale, which would
 * depend on the machine).
 */
export function compareNoCase(a: string, b: string): number {
    const [x, y] = [a.toLowerCase(), b.toLowerCase()]
    return x < y ? -1 : x > y ? 1 : 0
}

/**
 * An index kept inside a list.
 *
 * @param index - the wanted index.
 * @param count - the number of entries.
 * @returns `index` clamped to `0 ... count - 1` (`-1` for an empty list).
 */
export function clampIndex(index: number, count: number): number {
    return Math.min(Math.max(index, 0), count - 1)
}

// --- numbers typed by the user

/** A decimal number as typed: sign, digits with a point, exponent (no hex, no NaN). */
const DECIMAL = /^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?$/

/** The finite number a text is. */
export function numberText(text: string): number | undefined {
    if (!DECIMAL.test(text)) return undefined
    const x = Number(text)
    return Number.isFinite(x) ? x : undefined
}

/**
 * A number as text with no exponent and no `.0` on a whole number (`1e6` is
 * `1000000`).
 */
export function plainNumber(v: number): string {
    const text = String(v)
    const match = /^(-?)(\d+)(?:\.(\d+))?e([+-]\d+)$/.exec(text)
    if (!match) return text
    // JavaScript only switches to an exponent for very large or very small numbers.
    const [, sign, whole, fraction = "", exponent] = match
    const digits = whole + fraction
    const point = whole.length + Number(exponent)
    if (point <= 0) return `${sign}0.${"0".repeat(-point)}${digits}`
    if (point >= digits.length) return sign + digits + "0".repeat(point - digits.length)
    return `${sign}${digits.slice(0, point)}.${digits.slice(point)}`
}

/** A number for a summary: five significant digits, no exponent for ordinary sizes. */
export const shortNumber = (x: number): string => plainNumber(Number(x.toPrecision(5)))

/** A number as plain decimal text for a cell that shows it. */
export function formatNumber(x: number | null | undefined): string {
    return x === null || x === undefined ? "" : plainNumber(x)
}

/**
 * What typed text comes to: the value, or a short message for the cell.
 */
export type Parsed<T> = { value: T } | { error: string }

/** What [[parseNumber]] says of text that is no number. */
const NOT_A_NUMBER = "a number, please"

/** What [[parseNumber]] says of text that is no whole number. */
const NOT_A_WHOLE_NUMBER = "a whole number, please"

/** A whole number as typed: digits, a sign only when [[NumberRules.signed]]. */
const WHOLE_UNSIGNED = /^\d+$/
const WHOLE_SIGNED = /^[+-]?\d+$/

/**
 * What a number cell accepts. Every field is optional; with none, any finite number
 * (negative too) is taken. The checks run in the order of the fields below, after the
 * text is known to be a number.
 *
 * @property whole - only whole numbers (`a whole number, please` otherwise).
 * @property signed - with `whole`: a leading `+` or `-` is allowed (a decimal always
 *     allows one).
 * @property maxDigits - with `whole`: the most digits; more is refused with
 *     `digitsMessage`, or with the not-whole message when that is left out. Leading
 *     zeros are not counted unless `countZeros` is set.
 * @property countZeros - with `maxDigits`: count every digit typed, leading zeros too
 *     (the custom Z cells, as before).
 * @property digitsMessage - what is said of too many digits.
 * @property blank - blank text is the value `null` (the cell is optional), not an error.
 * @property above - the number must be above `limit`, else `message`.
 * @property atLeast - the number must be `limit` or more, else `message`.
 */
export type NumberRules = {
    whole?:         boolean
    signed?:        boolean
    maxDigits?:     number
    countZeros?:    boolean
    digitsMessage?: string
    blank?:         boolean
    above?:         { limit: number; message: string }
    atLeast?:       { limit: number; message: string }
}

/**
 * What the text typed in a number cell comes to. The one parser of every number the user
 * types (a concentration, a Z, a setting): the three families differ only in `rules`.
 * The text is trimmed first; a number with an exponent or past the range of a double
 * (`1e999`) is no number.
 *
 * @returns `{ value }` (`null` for blank text when `rules.blank`), or `{ error }`: `a
 *     number, please`, `a whole number, please`, the digits message, or the message of
 *     the limit that failed.
 */
export function parseNumber(
    text: string,
    rules: NumberRules & { blank: true },
): Parsed<number | null>
export function parseNumber(text: string, rules?: NumberRules): Parsed<number>
export function parseNumber(text: string, rules: NumberRules = {}): Parsed<number | null> {
    const t = text.trim()
    if (t === "" && rules.blank) return { value: null }
    let x: number
    if (rules.whole) {
        if (!(rules.signed ? WHOLE_SIGNED : WHOLE_UNSIGNED).test(t)) {
            return { error: NOT_A_WHOLE_NUMBER }
        }
        const leading = rules.countZeros ? /^[+-]/ : /^[+-]?0*/
        const stripped = t.replace(leading, "")
        const digits = stripped.length
        if (rules.maxDigits !== undefined && digits > rules.maxDigits) {
            return { error: rules.digitsMessage ?? NOT_A_WHOLE_NUMBER }
        }
        x = Number(t)
    } else {
        const n = numberText(t)
        if (n === undefined) return { error: NOT_A_NUMBER }
        x = n
    }
    if (rules.above && !(x > rules.above.limit)) return { error: rules.above.message }
    if (rules.atLeast && x < rules.atLeast.limit) return { error: rules.atLeast.message }
    return { value: x }
}

// ========================================================================================
// 2. Terminal: whether there is one
// ========================================================================================

/**
 * @returns `true` if standard input and output are a terminal. (`TERM` says nothing
 *     about it: programs without a terminal inherit it.)
 */
export function hasTerminal(): boolean {
    return Boolean(process.stdin.isTTY && process.stdout.isTTY)
}

/**
 * Writes a raw sequence to the terminal (the clipboard's OSC 52), beside what Ink draws;
 * nothing without a terminal.
 *
 * @param sequence - what to write.
 * @returns `true` when it was written.
 */
export function writeTerminal(sequence: string): boolean {
    if (!process.stdout.isTTY) return false
    process.stdout.write(sequence)
    return true
}

// ========================================================================================
// 3. Launch: opening a terminal emulator that runs a command
// ========================================================================================

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
const inTerminalVar = "BAYSOL_IN_TERMINAL"

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
        if (!terminal) return { problem: "No supported Linux terminal emulator found" }
        return {
            command: terminalCommand(terminal, inDirectoryCommand(system.cwd, command)),
        }
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
async function launchDetached(
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
