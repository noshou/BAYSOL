// SPDX-License-Identifier: LGPL-3.0-or-later

import { appendFileSync, existsSync } from "node:fs"
import { join } from "node:path"
import {
    copyOver,
    isDict,
    isFile,
    quarantine,
    readJson,
    withFileLock,
    writeAtomic,
    writeJson,
} from "../core/files.js"
import { ensureDir } from "../core/paths.js"
import { inProject } from "./projects.js"
import {
    defaultCatalog,
    type SettingDef,
    type SettingsCatalog,
    SettingsCatalogError,
    type SettingValue,
} from "./settings-defs.js"
import {
    catalogProblems,
    checkRelations,
    shortReason,
    validateValue,
} from "./settings-validate.js"

/**
 * The settings of the user: the application-wide `settings.json` in the BAYSOL folder and
 * the `settings.json` of each project, which starts as an exact copy of the global one.
 *
 * The file has the shape Julia reads (`BAYSOL.load_settings`): a map from the sheet ids
 * (`sampler`, `model`, `output`, `plots`) to an object from setting name to
 * `{"value": v}`, e.g. `{"sampler": {"N_ADAPT": {"value": 450}}}`. Only a saved setting
 * has an
 * entry; every other setting stands at its default.
 *
 * Nothing invalid is kept:
 * - Every load checks every saved value and the rules over all of them. A value that is
 *   not valid is wiped: the setting goes back to its default (a project's: to the global
 *   value), the file is rewritten without it, a line in `settings.log` says so, and the
 *   load reports a notice for it.
 * - A file that cannot be read at all is kept as `settings.json.corrupt` and replaced
 *   (by an empty one, or by a copy of the global file for a project).
 * - A change is checked before it is made ([[Settings.evaluate]]).
 * A save writes the file through a temporary one that replaces it in one step, so a
 * crash cannot leave half a file.
 */

/** The name of the settings file in a folder (Julia looks for the same name). */
const settingsFileName = "settings.json"

/** The name of the log of wiped values, next to the settings file. */
const settingsLogName = "settings.log"

/** The notice of a setting wiped back to its default. */
const noticeDefault = "reset to default"

/** The notice of a project setting wiped back to the global value. */
const noticeGlobal = "reset to global"

/**
 * The wipes a rule can cause one after another: wiping a value to its baseline may break
 * the same rule again, and then the next round sends it to the default. After this many
 * rounds the loop stops (it can only go on if the defaults themselves break a rule,
 * which `catalogProblems` rules out).
 */
const maxWipeRounds = 4

// --- the settings in memory

/**
 * The outcome of asking whether some values may be given to settings.
 *
 * @property ok - whether every one of them is valid and no rule breaks.
 * @property values - the valid ones, in the type of the setting.
 * @property errors - for each setting that cannot take its value: `message`, a
 *     sentence for a report, and `short`, the same for a narrow cell (at most 18
 *     characters for a rule about a number, 29 about a tuple).
 */
export type Evaluation = {
    ok: boolean
    values: Map<string, SettingValue>
    errors: Map<string, { message: string; short: string }>
}

/**
 * The settings of one folder: the saved values over the defaults. The program owns no
 * drafts; a sheet holds what the user is typing and asks [[Settings.evaluate]] whether
 * it may become a value.
 *
 * @param catalog - what the settings are.
 * @param dir - the folder of the settings file; [[Settings.save]] writes there.
 * @param saved - the values that are saved (they must be valid).
 * @param baseline - what a reset goes back to, setting name to value: the global values
 *     for a project's settings. `undefined` means the defaults.
 */
export class Settings {
    /** Why a setting was wiped at the load, setting name to message, until it is set. */
    readonly notices = new Map<string, string>()

    /**
     * The settings this copy changed since it loaded or last saved: [[save]] applies only
     * these over the file as it is then, so a copy of the program in another terminal
     * that changed other settings does not lose its work.
     */
    private readonly changed = new Set<string>()

    constructor(
        readonly catalog: SettingsCatalog,
        readonly dir: string,
        private readonly saved: Map<string, SettingValue> = new Map(),
        private readonly baseline?: ReadonlyMap<string, SettingValue>,
    ) {}

    /**
     * @param name - a setting.
     * @returns its value: the saved one, else the default.
     * @throws if there is no such setting.
     */
    get(name: string): SettingValue {
        return this.saved.get(name) ?? this.catalog.require(name).default
    }

    /**
     * @param name - a setting.
     * @returns whether it has a saved value (it may equal the default).
     */
    isSaved(name: string): boolean {
        return this.saved.has(name)
    }

    /**
     * @param name - a setting.
     * @returns what a reset sends it to: the default, or for a project's settings the
     *     global value.
     * @throws if there is no such setting.
     */
    resetValue(name: string): SettingValue {
        return this.baseline?.get(name) ?? this.catalog.require(name).default
    }

    /** @returns the value of every setting, by name. */
    values(): Record<string, SettingValue> {
        return Object.fromEntries(
            this.catalog.defs().map((d) => [d.name, this.get(d.name)]),
        )
    }

    /**
     * Asks whether values may be given to settings, changing nothing. Each value is
     * checked ([[validateValue]]), then the rules that tie settings together over the
     * values the settings would have; a rule that breaks is told to the settings of it
     * that are being changed.
     *
     * @param changes - setting name to the raw value (a number, a boolean, a string, a
     *     colour name, an array or an object for a tuple).
     * @returns the evaluation.
     */
    evaluate(changes: Record<string, unknown>): Evaluation {
        const values = new Map<string, SettingValue>()
        const errors = new Map<string, { message: string; short: string }>()
        for (const [name, raw] of Object.entries(changes)) {
            const def = this.catalog.get(name)
            const r = def === undefined ? undefined : validateValue(def, raw)
            if (r === undefined)
                errors.set(name, { message: "is not a setting", short: "not a setting" })
            else if (r.ok) values.set(name, r.value)
            else errors.set(name, { message: r.error, short: r.error })
        }
        const candidate = { ...this.values(), ...Object.fromEntries(values) }
        for (const { reason, relation } of checkRelations(
            this.catalog.relations,
            candidate,
        )) {
            for (const name of [relation.setting, relation.of]) {
                if (name !== undefined && values.has(name) && !errors.has(name))
                    errors.set(name, {
                        message: reason,
                        short: shortReason(relation, name),
                    })
            }
        }
        for (const name of errors.keys()) values.delete(name)
        return { ok: errors.size === 0, values, errors }
    }

    /**
     * Gives values to settings, in memory, if all of them may be given ([[evaluate]]);
     * otherwise nothing changes. The notices of the settings changed go.
     *
     * @param changes - as for [[evaluate]].
     * @returns the evaluation; the values are in place when `ok`.
     */
    set(changes: Record<string, unknown>): Evaluation {
        const ev = this.evaluate(changes)
        if (!ev.ok) return ev
        for (const [name, value] of ev.values) {
            this.saved.set(name, value)
            this.changed.add(name)
            this.notices.delete(name)
        }
        return ev
    }

    /**
     * Sends settings back to their reset value ([[resetValue]]): the saved value goes, or
     * for a project's settings becomes the global value. Nothing changes if that would
     * break a rule with a setting that is not reset.
     *
     * @param names - the settings.
     * @returns the evaluation of the reset values; they are in place when `ok`.
     */
    reset(names: readonly string[]): Evaluation {
        const ev = this.evaluate(
            Object.fromEntries(names.map((n) => [n, this.resetValue(n)])),
        )
        if (!ev.ok) return ev
        for (const name of names) {
            if (this.baseline?.has(name)) this.saved.set(name, this.resetValue(name))
            else this.saved.delete(name)
            this.changed.add(name)
            this.notices.delete(name)
        }
        return ev
    }

    /**
     * The text of the settings file for the saved values: the sheets in order, the
     * settings of each in the order of the sheet, shaped as Julia reads them.
     *
     * @returns the text (JSON; `{}` when nothing is saved).
     */
    toText(): string {
        return writeJson(sheetsOf(this.catalog, this.saved))
    }

    /**
     * Saves the settings this copy changed ([[set]], [[reset]]) into the file, taking
     * care of another copy of the program that may save the same file at the same time:
     * under a lock on the file, the file is read again, only the settings this copy
     * changed are applied to what is there, the result is checked as a load checks it
     * (a value or rule that is not valid is wiped and logged) and written through a
     * temporary file, and this copy takes over what was written. Two copies that changed
     * different settings both keep their changes; for one setting the last save wins. A
     * file that cannot be read is kept as `settings.json.corrupt`, never written over,
     * and replaced by all the settings this copy knows.
     *
     * @returns the path of the file.
     * @throws FileInUseError if another copy holds the lock for 3 s; ProjectGoneError for
     *     a project whose folder was deleted meanwhile (nothing is made); an error if the
     *     file cannot be written.
     */
    save(): string {
        const run = (): string =>
            withFileLock(settingsFile(this.dir), () => this.saveLocked(), this.folder)
        // A project's folder must exist: a deleted project is not made again.
        return this.baseline === undefined ? run() : inProject(this.dir, run)
    }

    /** Whether a write may make the folder: the global one, not a project's. */
    private get folder(): { createParents: boolean } {
        return { createParents: this.baseline === undefined }
    }

    /**
     * The work of [[save]], for a caller that holds the lock on the file already.
     *
     * @returns the path of the file.
     * @throws an error if the file cannot be written.
     */
    saveLocked(): string {
        const file = settingsFile(this.dir)
        const read = readSettingsFile(file)
        const wiped: Wipe[] = []
        let base: Map<string, SettingValue>
        if (read.state === "ok") {
            const disk = wipeInvalid(this.catalog, read.stored, this.baseline)
            wiped.push(...disk.wiped)
            base = disk.saved
            for (const name of this.changed) {
                const value = this.saved.get(name)
                if (value === undefined) base.delete(name)
                else base.set(name, value)
            }
        } else {
            if (read.state === "unreadable") {
                quarantine(file)
                logLines(this.dir, [
                    `${settingsFileName} could not be read; kept as ` +
                        `${settingsFileName}.corrupt, ` +
                        "replaced by the settings of this copy",
                ])
            }
            base = new Map(this.saved)
        }
        const final = wipeInvalid(
            this.catalog,
            sheetsOf(this.catalog, base),
            this.baseline,
        )
        wiped.push(...final.wiped)
        writeAtomic(file, writeJson(sheetsOf(this.catalog, final.saved)), this.folder)
        this.saved.clear()
        for (const [name, value] of final.saved) this.saved.set(name, value)
        this.changed.clear()
        logWipes(this, wiped, this.baseline === undefined ? "default" : "global value")
        return file
    }
}

/**
 * The saved values as the sheets of the file: the sheets in order, the settings of each
 * in the order of the sheet.
 *
 * @param catalog - what the settings are.
 * @param saved - setting name to value.
 * @returns sheet id to setting name to `{ value }`.
 */
function sheetsOf(
    catalog: SettingsCatalog,
    saved: ReadonlyMap<string, SettingValue>,
): Record<string, Record<string, { value: SettingValue }>> {
    const sheets: Record<string, Record<string, { value: SettingValue }>> = {}
    for (const def of catalog.defs()) {
        const value = saved.get(def.name)
        if (value === undefined) continue
        sheets[def.sheet] ??= {}
        sheets[def.sheet][def.name] = { value }
    }
    return sheets
}

/**
 * @param dir - a folder with settings (the BAYSOL folder or a project's).
 * @returns the path of its settings file.
 */
export function settingsFile(dir: string): string {
    return join(dir, settingsFileName)
}

// --- wiping what is not valid

/**
 * One saved value that was not kept.
 *
 * @property screen - the sheet of the setting.
 * @property setting - the setting.
 * @property value - what the file had for it (raw, as read).
 * @property reason - why it was not kept, e.g. `must be at least 1`.
 */
type Wipe = { screen: string; setting: string; value: unknown; reason: string }

/**
 * What [[wipeInvalid]] makes of a file.
 *
 * @property saved - the values kept (and, with a baseline, the values wiped values went
 *     back to), setting name to value.
 * @property wiped - what was not kept.
 * @property dropped - sentences about parts of the file that are no setting and were
 *     left out (a screen that is no map).
 */
export type Sanitized = {
    saved: Map<string, SettingValue>
    wiped: Wipe[]
    dropped: string[]
}

/**
 * Whether two values are the same: numbers as numbers, arrays and objects by content.
 *
 * @param a - a value.
 * @param b - a value.
 * @returns true if equal.
 */
export function sameValue(a: unknown, b: unknown): boolean {
    if (Array.isArray(a) && Array.isArray(b))
        return a.length === b.length && a.every((x, i) => sameValue(x, b[i]))
    if (typeof a === "object" && typeof b === "object" && a !== null && b !== null) {
        const ka = Object.keys(a)
        return (
            ka.length === Object.keys(b).length &&
            ka.every((k) => sameValue((a as never)[k], (b as never)[k]))
        )
    }
    return a === b
}

/**
 * Checks everything a settings file holds and keeps what is valid. Every saved value is
 * checked ([[validateValue]]); then the rules over all the values are checked, and the
 * saved values of the settings of a broken rule are wiped too. A setting that is no
 * setting is ignored; a screen that is no map and an entry that is no map are not kept.
 *
 * A wiped setting goes back to its default or, when `baseline` is given, to its value
 * there (the settings of a project go back to the global settings); a rule still broken
 * after that sends it to its default after all.
 *
 * @param catalog - what the settings are.
 * @param stored - the file's content as `readJson` gave it (a map of screens).
 * @param baseline - the values wiped settings go back to, or `undefined` for defaults.
 * @returns the values kept, the wipes and the parts left out.
 */
export function wipeInvalid(
    catalog: SettingsCatalog,
    stored: Record<string, unknown>,
    baseline?: ReadonlyMap<string, SettingValue>,
): Sanitized {
    const wiped: Wipe[] = []
    const dropped: string[] = []
    const saved = new Map<string, SettingValue>()
    const wipe = (def: SettingDef, value: unknown, reason: string): void => {
        wiped.push({ screen: def.sheet, setting: def.name, value, reason })
    }
    /** Puts a wiped setting back to its baseline (round `n`) or to its default. */
    const sendBack = (def: SettingDef, round: number): void => {
        const back = baseline?.get(def.name)
        if (back !== undefined && round < 2 && !sameValue(back, saved.get(def.name)))
            saved.set(def.name, back)
        else saved.delete(def.name)
    }

    // The entries of the file by setting name, whatever screen they are on.
    const entries = new Map<string, unknown>()
    for (const [screen, group] of Object.entries(stored)) {
        if (typeof group !== "object" || group === null || Array.isArray(group)) {
            dropped.push(`screen ${screen} is not a map of settings`)
            continue
        }
        for (const [name, entry] of Object.entries(group)) entries.set(name, entry)
    }
    for (const def of catalog.defs()) {
        if (!entries.has(def.name)) continue
        const entry = entries.get(def.name)
        if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
            wipe(def, entry, "its entry is not a map")
            sendBack(def, 0)
        } else if ("value" in entry) {
            const raw = (entry as { value: unknown }).value
            const r = validateValue(def, raw)
            if (r.ok) saved.set(def.name, r.value)
            else {
                wipe(def, raw, r.error)
                sendBack(def, 0)
            }
        }
    }

    // The rules over all the values: wipe the saved values of the settings of a broken
    // rule.
    const effective = (): Record<string, SettingValue> =>
        Object.fromEntries(
            catalog.defs().map((d) => [d.name, saved.get(d.name) ?? d.default]),
        )
    for (let round = 0; round < maxWipeRounds; round++) {
        const reasons = new Map<string, string>()
        for (const { relation, reason } of checkRelations(catalog.relations, effective())) {
            for (const name of [relation.setting, relation.of]) {
                if (name !== undefined && saved.has(name) && !reasons.has(name))
                    reasons.set(name, reason)
            }
        }
        if (reasons.size === 0) break
        for (const [name, reason] of reasons) {
            const def = catalog.require(name)
            wipe(def, saved.get(name), reason)
            sendBack(def, round)
        }
    }
    return { saved, wiped, dropped }
}

// --- loading and saving the files

/**
 * What a load of a settings file gives.
 *
 * @property settings - the settings, with the notices of this load set.
 * @property wiped - the saved values that were not valid and were wiped.
 * @property reset - whether the file could not be read at all: it was kept as
 *     `settings.json.corrupt` and replaced.
 * @property notices - one message for each wiped setting (`reset to default`, in a
 *     project `reset to global`), for the sheets to show until it is saved again.
 */
export type LoadResult = {
    settings: Settings
    wiped: Wipe[]
    reset: boolean
    notices: { setting: string; message: string }[]
}

/** What reading a settings file found. */
type FileState =
    | { state: "missing" }
    | { state: "unreadable" }
    | { state: "ok"; stored: Record<string, unknown> }

/**
 * Reads a settings file. A file that is empty, is not JSON, or holds anything but a map
 * is unreadable (Julia refuses it too).
 *
 * @param file - the path.
 * @returns what is there.
 */
function readSettingsFile(file: string): FileState {
    if (!existsSync(file)) return { state: "missing" }
    if (!isFile(file)) return { state: "unreadable" }
    // An empty file reads as `null`, which is no map: unreadable, as for Julia.
    const value = readJson<undefined>(file, undefined)
    return isDict(value) ? { state: "ok", stored: value } : { state: "unreadable" }
}

/**
 * Adds lines to `settings.log` in a folder, each with the time.
 *
 * @param dir - the folder.
 * @param lines - the lines.
 * @throws if the log cannot be written.
 */
function logLines(dir: string, lines: string[]): void {
    if (lines.length === 0) return
    const stamp = new Date().toISOString()
    appendFileSync(
        join(dir, settingsLogName),
        lines.map((l) => `${stamp} ${l}\n`).join(""),
        "utf-8",
    )
}

/**
 * The text of a value for the log, as JSON.
 *
 * @param value - a raw value or a setting value.
 * @returns the text, one line.
 */
function showValue(value: unknown): string {
    return JSON.stringify(value) ?? String(value)
}

/**
 * The bundled catalog, once its defaults are known to be sound.
 *
 * @returns the catalog.
 * @throws [[SettingsCatalogError]] if the bundled data is corrupt; the program cannot
 *     go on.
 */
export function soundCatalog(): SettingsCatalog {
    const catalog = defaultCatalog()
    if (!soundChecked.has(catalog)) {
        const problems = catalogProblems(catalog)
        if (problems.length > 0) throw new SettingsCatalogError(problems)
        soundChecked.add(catalog)
    }
    return catalog
}

/** The catalogs whose defaults have been checked. */
const soundChecked = new WeakSet<SettingsCatalog>()

/**
 * Adds a line to `settings.log` for each wiped value.
 *
 * @param settings - the settings after the wipe (where the values went back to).
 * @param wiped - what was wiped.
 * @param target - what a wiped value went back to (`default`, `global value`).
 */
function logWipes(settings: Settings, wiped: readonly Wipe[], target: string): void {
    logLines(
        settings.dir,
        wiped.map(
            (w) =>
                `${w.setting}: ${showValue(w.value)} is not valid (${w.reason}); ` +
                `reset to its ${target} ${showValue(settings.get(w.setting))}`,
        ),
    )
}

/**
 * Checks a folder's settings file and builds the settings from it: the common part of
 * a global and a project load. The file must exist and be readable. If anything is
 * wiped the file is rewritten and the wipes logged, so the caller must hold the lock on
 * the file then ([[withFileLock]]).
 *
 * @param catalog - what the settings are.
 * @param dir - the folder.
 * @param stored - the file's map.
 * @param baseline - as for [[wipeInvalid]].
 * @param target - what a wiped value went back to, for the log (`default`, `global value`).
 * @param message - the notice of a wiped setting.
 * @returns the load result, with the file rewritten and logged if anything was wiped.
 */
function loadChecked(
    catalog: SettingsCatalog,
    dir: string,
    stored: Record<string, unknown>,
    baseline: ReadonlyMap<string, SettingValue> | undefined,
    target: string,
    message: string,
): LoadResult {
    const { saved, wiped, dropped } = wipeInvalid(catalog, stored, baseline)
    const settings = new Settings(catalog, dir, saved, baseline)
    const notices = wiped.map((w) => ({ setting: w.setting, message }))
    for (const n of notices) settings.notices.set(n.setting, n.message)
    if (wiped.length > 0) {
        writeAtomic(settingsFile(dir), settings.toText(), {
            createParents: baseline === undefined,
        })
        logWipes(settings, wiped, target)
    }
    logLines(
        dir,
        dropped.map((d) => `${d}; left out`),
    )
    return { settings, wiped, reset: false, notices }
}

/**
 * The load of a file that needs no change: it reads and everything in it is valid. No
 * lock is needed to read (a file is only ever replaced whole).
 *
 * @param catalog - what the settings are.
 * @param dir - the folder.
 * @param baseline - as for [[wipeInvalid]].
 * @returns the load result, or `undefined` if the file is missing, unreadable or holds
 *     anything to wipe (the caller then redoes the load under the lock).
 */
function loadClean(
    catalog: SettingsCatalog,
    dir: string,
    baseline: ReadonlyMap<string, SettingValue> | undefined,
): LoadResult | undefined {
    const read = readSettingsFile(settingsFile(dir))
    if (read.state !== "ok") return undefined
    const { saved, wiped, dropped } = wipeInvalid(catalog, read.stored, baseline)
    if (wiped.length > 0 || dropped.length > 0) return undefined
    const settings = new Settings(catalog, dir, saved, baseline)
    return { settings, wiped: [], reset: false, notices: [] }
}

/**
 * Loads the global settings from the BAYSOL folder: the file is made first (empty: every
 * setting at its default) if it is missing; an invalid saved value is wiped to its
 * default and the file rewritten; a file that cannot be read is kept as
 * `settings.json.corrupt` and replaced. All of it is in `settings.log`.
 *
 * @param dir - the BAYSOL folder (made if there is none).
 * @param catalog - what the settings are (the bundled data by default).
 * @returns the settings and what was wiped.
 * @throws [[SettingsCatalogError]] if the bundled data is corrupt, or an error if a file
 *     cannot be written.
 */
export function loadGlobal(
    dir: string,
    catalog: SettingsCatalog = soundCatalog(),
): LoadResult {
    ensureDir(dir)
    const clean = loadClean(catalog, dir, undefined)
    if (clean) return clean
    // Something has to be written: make, rewrite or replace the file under the lock,
    // looking at the file again there (another copy may have done it meanwhile).
    return withFileLock(settingsFile(dir), () => {
        const read = readSettingsFile(settingsFile(dir))
        if (read.state === "ok")
            return loadChecked(
                catalog,
                dir,
                read.stored,
                undefined,
                "default",
                noticeDefault,
            )
        const settings = new Settings(catalog, dir)
        if (read.state === "unreadable") {
            quarantine(settingsFile(dir))
            logLines(dir, [
                `${settingsFileName} could not be read; kept as ` +
                    `${settingsFileName}.corrupt, replaced by the defaults`,
            ])
        }
        settings.saveLocked()
        return { settings, wiped: [], reset: read.state === "unreadable", notices: [] }
    })
}

/**
 * Loads the settings of a project, checked like the global ones but with the global
 * settings as the baseline: the project's file is made, as an exact copy of the global
 * `settings.json`, the first time; a saved value that is not valid goes back to its
 * global value, not to the default; and a reset goes back to the global value too. A
 * project's settings do not follow later changes of the global ones. An unreadable
 * project file is kept as `settings.json.corrupt` and replaced by a copy of the global
 * file.
 *
 * @param projectDir - the project's folder.
 * @param globalDir - the BAYSOL folder.
 * @param catalog - what the settings are (the bundled data by default).
 * @returns the project's settings and what was wiped; `reset` says the file was
 *     unreadable.
 * @throws [[SettingsCatalogError]] if the bundled data is corrupt; [[ProjectGoneError]]
 *     if the project's folder does not exist (nothing is made); an error if a file
 *     cannot be written.
 */
export function loadProject(
    projectDir: string,
    globalDir: string,
    catalog: SettingsCatalog = soundCatalog(),
): LoadResult {
    const global = loadGlobal(globalDir, catalog).settings
    const baseline = new Map(Object.entries(global.values()))
    const file = settingsFile(projectDir)
    // The project's folder must exist: opening a deleted project makes nothing.
    return inProject(projectDir, () => {
        const clean = loadClean(catalog, projectDir, baseline)
        if (clean) return clean
        return withFileLock(
            file,
            () => {
                const copyGlobal = (): string => copyOver(settingsFile(globalDir), file)
                let read = readSettingsFile(file)
                const reset = read.state === "unreadable"
                if (read.state === "missing") copyGlobal()
                if (read.state === "unreadable") {
                    quarantine(file)
                    copyGlobal()
                    logLines(projectDir, [
                        `${settingsFileName} could not be read; kept as ` +
                            `${settingsFileName}.corrupt, ` +
                            "replaced by a copy of the global settings",
                    ])
                }
                read = readSettingsFile(file)
                if (read.state !== "ok")
                    throw new Error(`${file} cannot be used after it was copied`)
                const loaded = loadChecked(
                    catalog,
                    projectDir,
                    read.stored,
                    baseline,
                    "global value",
                    noticeGlobal,
                )
                return { ...loaded, reset }
            },
            { createParents: false },
        )
    })
}
