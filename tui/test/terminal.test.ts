// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of `core/terminal.ts`: text in terminal cells, numbers and opening a terminal.

import assert from "node:assert/strict"
import { mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import type { System } from "../src/core/environment.js"
import {
    displayWidth,
    formatNumber,
    inDirectoryCommand,
    macTerminalCommand,
    numberText,
    openTerminalCommand,
    padWidth,
    parseNumber,
    plainNumber,
    programCommand,
    shellQuote,
    startAction,
    takeWidth,
    terminalCandidates,
    terminalCommand,
    truncate,
    windowsTerminalCommand,
} from "../src/core/terminal.js"

test("numberText takes a decimal number as typed and nothing else", () => {
    for (const [text, x] of [
        ["5", 5],
        ["-2.5", -2.5],
        ["+.5", 0.5],
        ["1e-3", 0.001],
        ["7.", 7],
    ] as const)
        assert.equal(numberText(text), x, text)
    const bad = ["", " 5", "5 ", "0x10", "NaN", "Infinity", "1e999", "1,5", "--1"]
    for (const text of bad)
        assert.equal(numberText(text), undefined, JSON.stringify(text))
})

test("plainNumber writes no exponent", () => {
    assert.equal(plainNumber(22), "22")
    assert.equal(plainNumber(1e21), "1000000000000000000000")
    assert.equal(plainNumber(1.5e21), "1500000000000000000000")
    assert.equal(plainNumber(1e-7), "0.0000001")
    assert.equal(plainNumber(1.25e-7), "0.000000125")
})

test("formatNumber is plain text, empty for none", () => {
    assert.equal(formatNumber(200), "200")
    assert.equal(formatNumber(1e-5), "0.00001")
    assert.equal(formatNumber(null), "")
    assert.equal(formatNumber(undefined), "")
})

test("parseNumber: the rules are what a cell accepts", () => {
    assert.deepEqual(parseNumber(" -2.5 "), { value: -2.5 })
    assert.deepEqual(parseNumber(""), { error: "a number, please" })
    assert.deepEqual(parseNumber("1e999"), { error: "a number, please" })
    // blank is a value of an optional cell
    assert.deepEqual(parseNumber("  ", { blank: true }), { value: null })
    // limits: above is strict, at least is not
    const above = { above: { limit: 0, message: "too low" } }
    assert.deepEqual(parseNumber("0", above), { error: "too low" })
    assert.deepEqual(parseNumber("0.1", above), { value: 0.1 })
    const least = { atLeast: { limit: 0, message: "below 0" } }
    assert.deepEqual(parseNumber("0", least), { value: 0 })
    assert.deepEqual(parseNumber("-1", least), { error: "below 0" })
    // whole numbers: unsigned unless allowed, digits counted without leading zeros
    const notWhole = { error: "a whole number, please" }
    assert.deepEqual(parseNumber("2.5", { whole: true }), notWhole)
    assert.deepEqual(parseNumber("-2", { whole: true }), notWhole)
    assert.deepEqual(parseNumber("-2", { whole: true, signed: true }), { value: -2 })
    const cap = { whole: true, maxDigits: 3 }
    assert.deepEqual(parseNumber("0123", cap), { value: 123 })
    assert.deepEqual(parseNumber("1234", cap), { error: "a whole number, please" })
    assert.deepEqual(parseNumber("1234", { ...cap, digitsMessage: "3 digits" }), {
        error: "3 digits",
    })
})

test("countZeros counts leading zeros too (the custom Z cells)", () => {
    const rules = { whole: true, maxDigits: 9, countZeros: true }
    assert.ok("value" in parseNumber("123456789", rules))
    assert.ok("error" in parseNumber("0000000005", rules))
    // without it, leading zeros are free
    assert.ok("value" in parseNumber("0000000005", { whole: true, maxDigits: 9 }))
})

test("displayWidth measures the way Ink does, ambiguous width included", async () => {
    // Ink lays text out with `string-width`'s defaults, so the text helpers must give the
    // same cells for every character the screens use, or a line is cut or padded wrongly
    const { default: inkWidth } = await import("string-width")
    const samples = ["σ", "±", "Å", "°", "α", "μ", "ρ", "δ", "·", "…", "⏎", "↑↓", "⌫", "×"]
    for (const c of [...samples, "pH σ: ^g"])
        assert.equal(displayWidth(c), inkWidth(c), c)
    for (const c of ["σ", "±", "Å", "°", "μ", "·", "…"]) assert.equal(displayWidth(c), 1, c)
    // truncating and padding agree with that measure
    assert.equal(truncate("pH ± σ pH ± σ", 6), "pH ± …")
    assert.equal(displayWidth(padWidth("σ", 4)), 4)
    assert.equal(takeWidth("σσσσ", 3), "σσσ")
})

const system = (os: NodeJS.Platform, env: Record<string, string>): System => ({
    os,
    env,
    home: "/home/u",
    cwd: "/work",
})

/** A new folder holding an executable file for each name. */
function binWith(...names: string[]): string {
    const dir = mkdtempSync(join(tmpdir(), "baysol-test-"))
    for (const n of names) writeFileSync(join(dir, n), "#!/bin/sh\n", { mode: 0o755 })
    return dir
}

const script = 'cd "$1" && shift && exec "$@"'

test("candidates are ordered by who chose them", () => {
    const first = (env: Record<string, string>, n: number): string[] =>
        terminalCandidates(system("linux", env)).slice(0, n)
    assert.deepEqual(first({ TERMINAL: "kitty", XDG_CURRENT_DESKTOP: "KDE" }, 5), [
        "kitty",
        "xdg-terminal-exec",
        "konsole",
        "x-terminal-emulator",
        "ptyxis",
    ])
    assert.deepEqual(first({ XDG_CURRENT_DESKTOP: "ubuntu:GNOME" }, 5), [
        "xdg-terminal-exec",
        "ptyxis",
        "kgx",
        "gnome-terminal",
        "x-terminal-emulator",
    ])
    assert.deepEqual(first({ XDG_CURRENT_DESKTOP: "XFCE" }, 3), [
        "xdg-terminal-exec",
        "xfce4-terminal",
        "x-terminal-emulator",
    ])
    assert.deepEqual(first({ TERMINAL: "  " }, 3), [
        "xdg-terminal-exec",
        "x-terminal-emulator",
        "ptyxis",
    ])
    assert.deepEqual(first({ TERMINAL: "xterm", XDG_CURRENT_DESKTOP: "X-Cinnamon" }, 4), [
        "xterm",
        "xdg-terminal-exec",
        "gnome-terminal",
        "x-terminal-emulator",
    ])
    const all = terminalCandidates(
        system("linux", { TERMINAL: "konsole", XDG_CURRENT_DESKTOP: "KDE" }),
    )
    assert.equal(all.length, new Set(all).size)
})

test("terminals take a command in their own way", () => {
    assert.deepEqual(terminalCommand("konsole", ["prog", "a b"]), [
        "konsole",
        "-e",
        "prog",
        "a b",
    ])
    assert.deepEqual(terminalCommand("/usr/bin/gnome-terminal", ["prog"]), [
        "/usr/bin/gnome-terminal",
        "--",
        "prog",
    ])
    assert.deepEqual(terminalCommand("xfce4-terminal", ["prog"]), [
        "xfce4-terminal",
        "-x",
        "prog",
    ])
    assert.deepEqual(terminalCommand("xdg-terminal-exec", ["prog"]), [
        "xdg-terminal-exec",
        "prog",
    ])
    assert.deepEqual(terminalCommand("kitty", ["prog"]), ["kitty", "prog"])
    assert.deepEqual(terminalCommand("wezterm", ["prog"]), [
        "wezterm",
        "start",
        "--",
        "prog",
    ])
    assert.deepEqual(terminalCommand("alacritty", ["prog"]), ["alacritty", "-e", "prog"])
})

test("a command is run in a folder without quoting", () => {
    assert.deepEqual(inDirectoryCommand("/d e", ["node", "-r", "a:b"]), [
        "sh",
        "-c",
        script,
        "sh",
        "/d e",
        "node",
        "-r",
        "a:b",
    ])
})

test("shellQuote wraps one word", () => {
    assert.equal(shellQuote("a b"), "'a b'")
    assert.equal(shellQuote(""), "''")
    assert.equal(shellQuote("it's"), "'it'\\''s'")
    assert.equal(shellQuote("a'b'c"), "'a'\\''b'\\''c'")
})

test("macOS and Windows command lines", () => {
    assert.deepEqual(
        macTerminalCommand("/Users/u/my dir", ["/usr/bin/node", "-r", "a:b", "main"]),
        [
            "osascript",
            "-e",
            "on run argv",
            "-e",
            'tell application "Terminal" to do script (item 1 of argv)',
            "-e",
            'tell application "Terminal" to activate',
            "-e",
            "end run",
            "cd '/Users/u/my dir' && exec '/usr/bin/node' '-r' 'a:b' 'main'",
        ],
    )
    assert.deepEqual(windowsTerminalCommand(true, "C:\\proj", ["node", "x"]), [
        "wt.exe",
        "-d",
        "C:\\proj",
        "node",
        "x",
    ])
    assert.deepEqual(windowsTerminalCommand(false, "C:\\proj", ["node", "x"]), [
        "cmd.exe",
        "/c",
        "start",
        "BAYSOL",
        "/D",
        "C:\\proj",
        "node",
        "x",
    ])
})

test("openTerminalCommand per system", () => {
    const bin = binWith("konsole", "kitty")
    assert.deepEqual(openTerminalCommand(system("linux", { PATH: bin }), ["prog"]), {
        command: [join(bin, "konsole"), "-e", "sh", "-c", script, "sh", "/work", "prog"],
    })
    assert.deepEqual(
        openTerminalCommand(system("linux", { PATH: bin, TERMINAL: "kitty" }), ["prog"]),
        {
            command: [join(bin, "kitty"), "sh", "-c", script, "sh", "/work", "prog"],
        },
    )
    assert.deepEqual(openTerminalCommand(system("linux", { PATH: "" }), ["prog"]), {
        problem: "No supported Linux terminal emulator found",
    })
    const mac = openTerminalCommand(system("darwin", {}), ["node"])
    assert.ok("command" in mac && mac.command[0] === "osascript")
    const wt = binWith("wt.exe")
    assert.deepEqual(openTerminalCommand(system("win32", { PATH: wt }), ["node"]), {
        command: ["wt.exe", "-d", "/work", "node"],
    })
    assert.deepEqual(openTerminalCommand(system("win32", { PATH: "" }), ["node"]), {
        command: ["cmd.exe", "/c", "start", "BAYSOL", "/D", "/work", "node"],
    })
    assert.deepEqual(openTerminalCommand(system("plan9" as NodeJS.Platform, {}), ["x"]), {
        problem: "Unsupported operating system: plan9",
    })
})

test("the program runs itself again with the same runtime and arguments", () => {
    assert.deepEqual(
        programCommand(
            "/usr/bin/node",
            ["--import", "tsx"],
            ["/usr/bin/node", "src/main.tsx", "--x"],
        ),
        ["/usr/bin/node", "--import", "tsx", "src/main.tsx", "--x"],
    )
})

test("start-up: run in a terminal, else relaunch once, else fail", () => {
    assert.equal(startAction(true, system("linux", {})), "run")
    assert.equal(startAction(true, system("linux", { BAYSOL_IN_TERMINAL: "1" })), "run")
    assert.equal(startAction(false, system("linux", {})), "relaunch")
    assert.equal(startAction(false, system("linux", { BAYSOL_IN_TERMINAL: "1" })), "fail")
})
