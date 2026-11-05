// SPDX-License-Identifier: LGPL-3.0-or-later

import { spawn } from "node:child_process"
import { findExecutable, isLinux, isMac, isWindows, type System } from "../core/system.js"

/**
 * The desktop's own file picker, to choose structure files (`.cif`, `.pdb`), several at
 * once: `zenity` or `kdialog` on Linux, AppleScript on macOS, PowerShell's open dialog on
 * Windows. The program is asked for the paths and prints them, one to a line. Only the
 * Linux commands have been run; the macOS and Windows ones come from the programs'
 * documentation and are untested.
 *
 * A picker is a window of its own, so it needs a desktop: without one (no `DISPLAY` or
 * `WAYLAND_DISPLAY` on Linux) or without any of the programs there is a short reason to
 * show instead. Programs are started with argument arrays, never through a shell.
 */

/**
 * What a picker asks for.
 *
 * @property title - the title of the window.
 * @property label - the name of the file filter.
 * @property exts - the extensions that are shown (lower case, no dot).
 * @property multiple - `true` if several files may be chosen.
 */
export type PickerSpec = {
    title: string
    label: string
    exts: string[]
    multiple: boolean
}

/** The pickers by kind: the models (several `.cif` and `.pdb` files) and the buffer's
 * DNA, RNA and protein sequence file (ONE file, FASTA or FASTQ). */
export const pickerSpecs = {
    structure: {
        title: "Choose models",
        label: "Structure files",
        exts: ["cif", "pdb"],
        multiple: true,
    },
    sequence: {
        title: "Choose a sequence file",
        label: "Sequence files",
        exts: ["fasta", "fa", "fna", "faa", "fastq", "fq"],
        multiple: false,
    },
} satisfies Record<string, PickerSpec>

/** The kinds of picker. */
export type PickerKind = keyof typeof pickerSpecs

/** The result of [[pick]]: the files chosen (none if the window was closed), or why no
 * picker could be shown. */
export type PickResult = { files: string[] } | { problem: string }

/**
 * The patterns of the extensions of a spec, in lower and upper case: `*.cif *.CIF`.
 *
 * @param spec - the picker.
 * @param separator - what goes between the patterns.
 * @returns the joined patterns.
 */
function globs(spec: PickerSpec, separator: string): string {
    return spec.exts.flatMap((e) => [`*.${e}`, `*.${e.toUpperCase()}`]).join(separator)
}

/** @returns the `zenity` command that picks files, starting in a folder. */
function zenityCommand(startDir: string, spec: PickerSpec): string[] {
    return [
        "zenity",
        "--file-selection",
        ...(spec.multiple ? ["--multiple"] : []),
        `--title=${spec.title}`,
        `--filename=${startDir}/`,
        "--separator=\n",
        `--file-filter=${spec.label} | ${globs(spec, " ")}`,
    ]
}

/** @returns the `kdialog` command that picks files, starting in a folder. */
function kdialogCommand(startDir: string, spec: PickerSpec): string[] {
    return [
        "kdialog",
        ...(spec.multiple ? ["--multiple", "--separate-output"] : []),
        "--title",
        spec.title,
        "--getopenfilename",
        startDir,
        `${globs(spec, " ")}|${spec.label}`,
    ]
}

/** @returns the `osascript` command that picks files (untested). */
function macCommand(spec: PickerSpec): string[] {
    const types = spec.exts.map((e) => `"${e}"`).join(", ")
    const choose =
        `set fs to choose file with prompt "${spec.title}" of type {${types}}` +
        (spec.multiple ? " with multiple selections allowed" : "\nset fs to {fs}")
    return [
        "osascript",
        "-e",
        choose,
        "-e",
        'set out to ""',
        "-e",
        "repeat with f in fs",
        "-e",
        "set out to out & POSIX path of f & linefeed",
        "-e",
        "end repeat",
        "-e",
        "return out",
    ]
}

/** @returns the PowerShell command that picks files, starting in a folder (untested). */
function windowsCommand(startDir: string, spec: PickerSpec): string[] {
    const filter = spec.exts.map((e) => `*.${e}`).join(";")
    return [
        "powershell",
        "-NoProfile",
        "-Command",
        "Add-Type -AssemblyName System.Windows.Forms; " +
            "$d = New-Object System.Windows.Forms.OpenFileDialog; " +
            `$d.Multiselect = ${spec.multiple ? "$true" : "$false"}; ` +
            `$d.Title = '${spec.title}'; ` +
            `$d.Filter = '${spec.label}|${filter}'; ` +
            `$d.InitialDirectory = '${startDir.replaceAll("'", "''")}'; ` +
            "if ($d.ShowDialog() -eq 'OK') { $d.FileNames -join \"`n\" }",
    ]
}

/**
 * The commands to try, in order, to pick files.
 *
 * @param system - the machine; on Linux `kdialog` comes first on a KDE desktop and
 *     `zenity` first anywhere else.
 * @param startDir - the folder the dialog starts in.
 * @param spec - what to pick (the structure files by default).
 * @returns the command lines; empty for an unknown system.
 */
export function pickerCommands(
    system: System,
    startDir: string,
    spec: PickerSpec = pickerSpecs.structure,
): string[][] {
    if (isLinux(system)) {
        const kde = (system.env.XDG_CURRENT_DESKTOP ?? "").toLowerCase().includes("kde")
        const both = [zenityCommand(startDir, spec), kdialogCommand(startDir, spec)]
        return kde ? both.reverse() : both
    }
    if (isMac(system)) return [macCommand(spec)]
    if (isWindows(system)) return [windowsCommand(startDir, spec)]
    return []
}

/**
 * The paths in the output of a picker.
 *
 * @param text - what the picker printed.
 * @returns its non-blank lines, trimmed of the line ends only (a name may have spaces).
 */
export function parsePickerOutput(text: string | undefined): string[] {
    return (text ?? "")
        .split(/\r?\n/)
        .map((line) => line.replace(/[\r\n]+$/, ""))
        .filter((line) => line.trim() !== "")
}

/**
 * @param system - the machine.
 * @returns `true` if its desktop can show a window (on Linux; elsewhere always).
 */
function hasDisplay(system: System): boolean {
    return (
        !isLinux(system) ||
        Boolean(system.env.DISPLAY) ||
        Boolean(system.env.WAYLAND_DISPLAY)
    )
}

/**
 * Runs a command and collects what it prints on standard output. Its input is closed
 * and its errors thrown away, so nothing of it reaches the terminal the TUI draws on.
 *
 * @param command - the program and its arguments.
 * @returns the output, once the window has closed.
 * @throws if the program cannot be started.
 */
function runCommand(command: string[]): Promise<string> {
    const [program, ...args] = command as [string, ...string[]]
    return new Promise((resolve, reject) => {
        const child = spawn(program, args, { stdio: ["ignore", "pipe", "ignore"] })
        const chunks: Buffer[] = []
        child.stdout.on("data", (chunk: Buffer) => chunks.push(chunk))
        child.once("error", reject)
        child.once("close", () => resolve(Buffer.concat(chunks).toString("utf8")))
    })
}

/**
 * Opens the desktop's file picker and waits for it.
 *
 * @param system - the machine.
 * @param startDir - the folder the dialog starts in.
 * @param kind - which picker (a key of [[pickerSpecs]]).
 * @returns the files picked (empty if the window was closed without a choice), or a
 *     short reason when no picker could be shown.
 */
export async function pick(
    system: System,
    startDir: string,
    kind: PickerKind = "structure",
): Promise<PickResult> {
    const command = pickerCommands(system, startDir, pickerSpecs[kind]).find(
        ([program]) => findExecutable(system, program ?? "") !== undefined,
    )
    if (!hasDisplay(system)) return { problem: "no desktop: cannot show a picker" }
    if (!command) return { problem: "no file picker (zenity or kdialog)" }
    try {
        return { files: parsePickerOutput(await runCommand(command)) }
    } catch (error) {
        return { problem: `picker failed: ${(error as Error).message}` }
    }
}
