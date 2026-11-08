// SPDX-License-Identifier: LGPL-3.0-or-later

// Settings store: the settings files of the user, their scopes, and the theme preference.
//
// Contents:
//   1. Store: `Settings`, loading and saving the global and project files under locks
//   2. Model settings: the overrides of one model (`model-settings.json`)
//   3. Scope: whose settings a screen shows (global, one project or one model)
//   4. Theme preference: the one theme name kept in `theme.json`
//
// The definitions and the validation of the settings are in `settings.ts`.

import { appendFileSync, existsSync } from "node:fs"
import { join } from "node:path"
import { appDir, ensureDir } from "../core/environment.js"
import {
    copyOver,
    isDict,
    isFile,
    quarantine,
    readJson,
    withFileLock,
    writeAtomic,
    writeJson,
} from "../core/file-system.js"
import { inProject, lockedIn, type ProjectRef } from "./projects.js"
import {
    checkRelations,
    defaultCatalog,
    isRunLevel,
    reasonFor,
    type SettingDef,
    type SettingsCatalog,
    type SettingValue,
    validateValue,
} from "./settings.js"

// ========================================================================================
// 1. Store
// ========================================================================================

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
 *   value), the file is rewritten without it, a line in `settings.log` beside it says
 *   what was wiped and why, and the load reports a notice for it.
 * - A file that cannot be read at all is kept as `settings.json.corrupt` and replaced
 *   (by an empty one, or by a copy of the global file for a project).
 * - A change is checked before it is made ([[Settings.evaluate]]).
 * A save writes the file through a temporary one that replaces it in one step, so a
 * crash cannot leave half a file.
 */

/** The name of the settings file in a folder (Julia looks for the same name). */
const settingsFileName = "settings.json"

/** The log beside a settings file that says which saved values a load wiped. */
const settingsLogName = "settings.log"

/** The notice of a setting wiped back to its default. */
const noticeDefault = "reset to default"

/** The notice of a project setting wiped back to the global value. */
const noticeGlobal = "reset to global"

/**
 * The wipes a rule can cause one after another: wiping a value to its baseline may break
 * the same rule again, and then the next round sends it to the default. After this many
 * rounds the loop stops (it can only go on if the defaults themselves break a rule,
 * which the unit tests rule out).
 */
const maxWipeRounds = 4

// --- the settings in memory

/**
 * The outcome of asking whether some values may be given to settings.
 *
 * @property ok - whether every one of them is valid and no rule breaks.
 * @property values - the valid ones, in the type of the setting.
 * @property errors - for each setting that cannot take its value, a sentence that says
 *     why (`must be at least 1`).
 */
type Evaluation = {
    ok: boolean
    values: Map<string, SettingValue>
    errors: Map<string, string>
}

/**
 * The settings of one folder: the saved values over the defaults. The program owns no
 * drafts; a sheet holds what the user is typing and asks [[Settings.evaluate]] whether
 * it may become a value.
 *
 * @param dir - the folder of the settings file; [[Settings.save]] writes there.
 * @param baseline - what a reset goes back to, setting name to value: the global values
 *     for a project's settings. `undefined` means the defaults.
 */
class Settings {
    /** Why a setting was wiped at the load, setting name to message, until it is set. */
    readonly notices = new Map<string, string>()

    /**
     * The settings this copy changed since it loaded or last saved: [[save]] applies only
     * these over the file as it is then, so a copy of the program in another terminal
     * that changed other settings does not lose its work.
     */
    protected readonly changed = new Set<string>()

    constructor(
        readonly catalog: SettingsCatalog,
        readonly dir: string,
        protected readonly saved: Map<string, SettingValue> = new Map(),
        protected readonly baseline?: ReadonlyMap<string, SettingValue>,
    ) {}

    /**
     * @param name - a setting.
     * @returns its value: the saved one, else the default.
     * @throws if there is no such setting.
     */
    get(name: string): SettingValue {
        const saved = this.saved.get(name)
        return saved !== undefined ? saved : this.catalog.require(name).default
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
     */
    evaluate(changes: Record<string, unknown>): Evaluation {
        const values = new Map<string, SettingValue>()
        const errors = new Map<string, string>()
        for (const [name, raw] of Object.entries(changes)) {
            const def = this.catalog.get(name)
            const r = def === undefined ? undefined : validateValue(def, raw)
            if (r === undefined)
                errors.set(name, "is not a setting")
            else if (r.ok) values.set(name, r.value)
            else errors.set(name, r.error)
        }
        const candidate = { ...this.values(), ...Object.fromEntries(values) }
        for (const broken of checkRelations(this.catalog.relations, candidate)) {
            for (const name of [broken.relation.setting, broken.relation.of]) {
                if (name !== undefined && values.has(name) && !errors.has(name))
                    errors.set(name, reasonFor(broken, name))
            }
        }
        for (const name of errors.keys()) values.delete(name)
        return { ok: errors.size === 0, values, errors }
    }

    /**
     * Gives values to settings, in memory, if all of them may be given ([[evaluate]]);
     * otherwise nothing changes. The notices of the settings changed go.
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
     * @throws an error if the file cannot be written.
     */
    saveLocked(): string {
        const file = settingsFile(this.dir)
        const read = readSettingsFile(file)
        if (read.state === "unreadable") quarantine(file)
        // the file as it is with this copy's changes over it (every saved value when
        // there is no readable file), checked once
        let stored: Record<string, unknown>
        if (read.state === "ok") {
            stored = structuredClone(read.stored)
            for (const name of this.changed) {
                const def = this.catalog.require(name)
                for (const group of Object.values(stored))
                    if (isDict(group)) delete group[name]
                const value = this.saved.get(name)
                if (value === undefined) continue
                if (!isDict(stored[def.sheet])) stored[def.sheet] = {}
                ;(stored[def.sheet] as Record<string, unknown>)[name] = { value }
            }
        } else stored = sheetsOf(this.catalog, this.saved)
        const final = wipeInvalid(this.catalog, stored, this.baseline)
        writeAtomic(file, writeJson(sheetsOf(this.catalog, final.saved)), this.folder)
        this.saved.clear()
        for (const [name, value] of final.saved) this.saved.set(name, value)
        this.changed.clear()
        return file
    }
}

/**
 * The saved values as the sheets of the file: the sheets in order, the settings of each
 * in the order of the sheet.
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
 */
export type Sanitized = {
    saved: Map<string, SettingValue>
    wiped: Wipe[]
}

/** Whether two values are the same: numbers as numbers, arrays and objects by content. */
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
 * How the table of one model is checked (see [[wipeInvalid]]).
 *
 * @property inherited - the project's value of every setting: what the model has without
 *     an override, which the rules between settings are checked over.
 * @property refuse - why a setting may not be in the table (`undefined`: it may).
 */
export type ModelRules = {
    inherited: ReadonlyMap<string, SettingValue>
    refuse: (name: string) => string | undefined
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
 * @param stored - the file's content as `readJson` gave it (a map of screens).
 * @param baseline - the values wiped settings go back to, or `undefined` for defaults.
 */
export function wipeInvalid(
    catalog: SettingsCatalog,
    stored: Record<string, unknown>,
    baseline?: ReadonlyMap<string, SettingValue>,
    model?: ModelRules,
): Sanitized {
    const wiped: Wipe[] = []
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
    for (const group of Object.values(stored)) {
        if (isDict(group))
            for (const [name, entry] of Object.entries(group)) entries.set(name, entry)
    }
    for (const def of catalog.defs()) {
        if (!entries.has(def.name)) continue
        const entry = entries.get(def.name)
        const refused = model?.refuse(def.name)
        if (refused !== undefined) {
            wipe(def, isDict(entry) && "value" in entry ? entry.value : entry, refused)
            continue
        }
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
            catalog
                .defs()
                .map((d) => [
                    d.name,
                    saved.get(d.name) ?? model?.inherited.get(d.name) ?? d.default,
                ]),
        )
    for (let round = 0; round < maxWipeRounds; round++) {
        const reasons = new Map<string, string>()
        for (const broken of checkRelations(catalog.relations, effective())) {
            for (const name of [broken.relation.setting, broken.relation.of]) {
                if (name !== undefined && saved.has(name) && !reasons.has(name))
                    reasons.set(name, reasonFor(broken, name))
            }
        }
        if (reasons.size === 0) break
        for (const [name, reason] of reasons) {
            const def = catalog.require(name)
            wipe(def, saved.get(name), reason)
            sendBack(def, round)
        }
    }
    return { saved, wiped }
}

// --- loading and saving the files

/**
 * Adds one line to `settings.log` beside the settings file for each wiped value: time,
 * setting, the bad value as JSON and why, tab-separated. A log that cannot be written
 * never stops the load.
 */
function logWipes(dir: string, wiped: readonly Wipe[]): void {
    const stamp = new Date().toISOString()
    const line = (w: Wipe): string =>
        [stamp, w.setting, JSON.stringify(w.value) ?? String(w.value), w.reason].join("\t")
    try {
        appendFileSync(join(dir, settingsLogName), `${wiped.map(line).join("\n")}\n`)
    } catch {
        // the notices still tell the user
    }
}

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
 */
function readSettingsFile(file: string): FileState {
    if (!existsSync(file)) return { state: "missing" }
    if (!isFile(file)) return { state: "unreadable" }
    // An empty file reads as `null`, which is no map: unreadable, as for Julia.
    const value = readJson<undefined>(file, undefined)
    return isDict(value) ? { state: "ok", stored: value } : { state: "unreadable" }
}

/**
 * Loads a folder's settings under the lock on its file: a missing file is made by `seed`,
 * an unreadable one is kept as `settings.json.corrupt` and made again; an invalid saved
 * value is wiped and the file rewritten.
 *
 * @param baseline - as for [[wipeInvalid]]; a project's (its folder must exist).
 */
function load(
    catalog: SettingsCatalog,
    dir: string,
    baseline: ReadonlyMap<string, SettingValue> | undefined,
    seed: () => void,
    notice: string,
): LoadResult {
    const file = settingsFile(dir)
    const body = (): LoadResult => {
        let read = readSettingsFile(file)
        const reset = read.state === "unreadable"
        if (reset) quarantine(file)
        if (read.state !== "ok") {
            seed()
            read = readSettingsFile(file)
            if (read.state !== "ok")
                throw new Error(`${file} cannot be used after it was made`)
        }
        const { saved, wiped } = wipeInvalid(catalog, read.stored, baseline)
        const settings = new Settings(catalog, dir, saved, baseline)
        const notices = wiped.map((w) => ({ setting: w.setting, message: notice }))
        for (const n of notices) settings.notices.set(n.setting, n.message)
        if (wiped.length > 0) {
            writeAtomic(file, settings.toText(), { createParents: baseline === undefined })
            logWipes(dir, wiped)
        }
        return { settings, wiped, reset, notices }
    }
    return baseline === undefined ? withFileLock(file, body) : lockedIn(dir, file, body)
}

/**
 * Loads the global settings from the BAYSOL folder: the file is made first (empty: every
 * setting at its default) if it is missing; an invalid saved value is wiped to its
 * default and the file rewritten; a file that cannot be read is kept as
 * `settings.json.corrupt` and replaced.
 *
 * @throws if a file cannot be written.
 */
export function loadGlobal(
    dir: string,
    catalog: SettingsCatalog = defaultCatalog(),
): LoadResult {
    ensureDir(dir)
    return load(
        catalog,
        dir,
        undefined,
        () => writeAtomic(settingsFile(dir), writeJson({})),
        noticeDefault,
    )
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
 * @returns the project's settings and what was wiped; `reset` says the file was
 *     unreadable.
 * @throws [[ProjectGoneError]] if the project's folder does not exist (nothing is made);
 *     an error if a file cannot be written.
 */
export function loadProject(
    projectDir: string,
    globalDir: string,
    catalog: SettingsCatalog = defaultCatalog(),
): LoadResult {
    const global = loadGlobal(globalDir, catalog).settings
    return load(
        catalog,
        projectDir,
        new Map(Object.entries(global.values())),
        () => copyOver(settingsFile(globalDir), settingsFile(projectDir)),
        noticeGlobal,
    )
}

// ========================================================================================
// 2. The settings of one model
// ========================================================================================

/**
 * The settings of single models: `<project>/model-settings.json`, which Julia reads
 * (`{"<model file stem>": {"<sheet>": {"<NAME>": {"value": v}}}}`, the shape of a
 * `settings.json` for each model). It is SPARSE: a model has only the settings that differ
 * from the project's, and a model or a setting that is not in it is the project's. A
 * setting of the whole run ([[isRunLevel]]) is refused by Julia with an error that fails
 * the run, so it is never written and is wiped when found. The table of a model that is
 * no longer in the project stays in the file (Julia ignores it with a note).
 */
const modelFileName = "model-settings.json"

/** The notice of a model's setting wiped: it is the project's again. */
const noticeModel = "reset to project"

/** Why a setting of the whole run is wiped from a model's table. */
const reasonRunLevel = "is a setting of the whole run"

/** @returns the path of a project's `model-settings.json`. */
export const modelSettingsFile = (projectDir: string): string =>
    join(projectDir, modelFileName)

/**
 * @param file - a model's file name (`crambin.pdb`).
 * @returns its stem, the model's name in `model-settings.json`: the name without the last
 *     extension, as Julia takes it.
 */
export function modelStem(file: string): string {
    const dot = file.lastIndexOf(".")
    return dot > 0 ? file.slice(0, dot) : file
}

/** The rules of the table of a model whose project's values are `inherited`. */
const modelRules = (inherited: ReadonlyMap<string, SettingValue>): ModelRules => ({
    inherited,
    refuse: (name) => (isRunLevel(name) ? reasonRunLevel : undefined),
})

/** The `settings.log` lines of a model's wiped values (the setting: `model <stem>: X`). */
const modelWipes = (stem: string, wiped: readonly Wipe[]): Wipe[] =>
    wiped.map((w) => ({ ...w, setting: `model ${stem}: ${w.setting}` }))

/**
 * Writes the table of one model into `model-settings.json`, keeping every other model's
 * table as it is (the stored file, read under the lock). An empty table removes the
 * model's key (the file stays sparse); nothing is made when there is no file and nothing
 * to put in it.
 */
function writeModelTable(
    catalog: SettingsCatalog,
    projectDir: string,
    stored: Record<string, unknown> | undefined,
    stem: string,
    saved: ReadonlyMap<string, SettingValue>,
): void {
    const sheets = sheetsOf(catalog, saved)
    const out = { ...stored }
    if (Object.keys(sheets).length === 0) {
        if (stored === undefined) return
        delete out[stem]
    } else out[stem] = sheets
    writeAtomic(modelSettingsFile(projectDir), writeJson(out), { createParents: false })
}

/**
 * The settings of ONE model: its overrides (the table in `model-settings.json`) over the
 * project's values. [[get]] is the override, else the project's value; an edit to a value
 * equal to the project's removes the override instead of making one (so the file the
 * program writes stays sparse), a reset gives the project's value back (removes it); an
 * override already in the file is kept even when it equals the project's value now.
 * [[save]] changes only this model's table, under the lock of the file, over the file as
 * it is then, so another copy's work on other settings or models survives.
 *
 * @param inherited - the project's value of every setting.
 */
export class ModelSettings extends Settings {
    constructor(
        catalog: SettingsCatalog,
        readonly projectDir: string,
        readonly stem: string,
        saved: Map<string, SettingValue>,
        readonly inherited: ReadonlyMap<string, SettingValue>,
    ) {
        super(catalog, projectDir, saved)
    }

    /** @returns the override, else the project's value. */
    override get(name: string): SettingValue {
        return this.saved.get(name) ?? this.resetValue(name)
    }

    /** @returns the project's value: what the model has without an override. */
    override resetValue(name: string): SettingValue {
        return this.inherited.get(name) ?? this.catalog.require(name).default
    }

    /** As [[Settings.evaluate]], and a setting of the whole run is never accepted. */
    override evaluate(changes: Record<string, unknown>): ReturnType<Settings["evaluate"]> {
        const own = Object.entries(changes).filter(([name]) => !isRunLevel(name))
        const ev = super.evaluate(Object.fromEntries(own))
        for (const name of Object.keys(changes))
            if (isRunLevel(name)) ev.errors.set(name, reasonRunLevel)
        return { ...ev, ok: ev.errors.size === 0 }
    }

    /** @returns the names of the settings this model overrides, in the sheets' order. */
    overrides(): string[] {
        return this.catalog.defs().flatMap((d) => (this.saved.has(d.name) ? [d.name] : []))
    }

    /**
     * Gives values to settings in memory as [[Settings.set]] does, but a value equal to
     * the project's removes the override instead of making one.
     */
    override set(changes: Record<string, unknown>): ReturnType<Settings["evaluate"]> {
        const ev = this.evaluate(changes)
        if (!ev.ok) return ev
        for (const [name, value] of ev.values) {
            if (sameValue(value, this.resetValue(name))) this.saved.delete(name)
            else this.saved.set(name, value)
            this.changed.add(name)
            this.notices.delete(name)
        }
        return ev
    }

    /** Saves under the lock of `model-settings.json`, inside the project. */
    override save(): string {
        return lockedIn(this.projectDir, modelSettingsFile(this.projectDir), () =>
            this.saveLocked(),
        )
    }

    /**
     * The work of [[save]]: the file is read again, only the settings this copy changed
     * are applied to this model's table there, the table is checked as a load checks it
     * (a value that is not valid is wiped and logged) and written with the other models'
     * tables untouched; this copy takes over what was written. A file that cannot be read
     * is kept as `model-settings.json.corrupt` and replaced by the overrides this copy
     * has.
     */
    override saveLocked(): string {
        const file = modelSettingsFile(this.projectDir)
        const read = readSettingsFile(file)
        if (read.state === "unreadable") quarantine(file)
        const stored = read.state === "ok" ? structuredClone(read.stored) : undefined
        let table: Record<string, unknown>
        if (stored !== undefined) {
            const own = stored[this.stem]
            table = isDict(own) ? own : {}
            for (const name of this.changed) {
                const def = this.catalog.require(name)
                for (const group of Object.values(table))
                    if (isDict(group)) delete group[name]
                const value = this.saved.get(name)
                if (value === undefined) continue
                if (!isDict(table[def.sheet])) table[def.sheet] = {}
                ;(table[def.sheet] as Record<string, unknown>)[name] = { value }
            }
        } else table = sheetsOf(this.catalog, this.saved)
        const rules = modelRules(this.inherited)
        const final = wipeInvalid(this.catalog, table, undefined, rules)
        writeModelTable(this.catalog, this.projectDir, stored, this.stem, final.saved)
        if (final.wiped.length > 0)
            logWipes(this.projectDir, modelWipes(this.stem, final.wiped))
        this.saved.clear()
        for (const [name, value] of final.saved) this.saved.set(name, value)
        this.changed.clear()
        return file
    }
}

/**
 * Loads one model's settings over its project's (the project's own load comes first, so
 * its values are checked and its file made), under the lock of `model-settings.json`:
 * an invalid value, a setting of the whole run, or a value that a rule between settings
 * breaks (over the project's values) is wiped from the model's table, the file rewritten
 * without it and a line added to `settings.log`; a file that cannot be read is kept as
 * `model-settings.json.corrupt`; the other models' tables are never touched. A model that
 * has no table reads as empty and nothing is made.
 *
 * @param stem - the model's name (see [[modelStem]]).
 * @returns the settings, and what was wiped, as [[LoadResult]] says (`reset`: the file or
 *     the model's table could not be read).
 * @throws [[ProjectGoneError]] if the project's folder does not exist; an error if a
 *     file cannot be written.
 */
export function loadModel(
    projectDir: string,
    stem: string,
    globalDir: string,
    catalog: SettingsCatalog = defaultCatalog(),
): Omit<LoadResult, "settings"> & { settings: ModelSettings } {
    const project = loadProject(projectDir, globalDir, catalog).settings
    const inherited = new Map(Object.entries(project.values()))
    const file = modelSettingsFile(projectDir)
    return lockedIn(projectDir, file, () => {
        const read = readSettingsFile(file)
        let reset = read.state === "unreadable"
        if (reset) quarantine(file)
        const stored = read.state === "ok" ? structuredClone(read.stored) : undefined
        const own = stored?.[stem]
        if (own !== undefined && !isDict(own)) reset = true // Julia refuses it too
        const table = isDict(own) ? own : {}
        const rules = modelRules(inherited)
        const { saved, wiped } = wipeInvalid(catalog, table, undefined, rules)
        const settings = new ModelSettings(catalog, projectDir, stem, saved, inherited)
        const notices = wiped
            .filter((w) => !isRunLevel(w.setting))
            .map((w) => ({ setting: w.setting, message: noticeModel }))
        for (const n of notices) settings.notices.set(n.setting, n.message)
        if (wiped.length > 0 || (own !== undefined && !isDict(own))) {
            writeModelTable(catalog, projectDir, stored, stem, saved)
            if (wiped.length > 0) logWipes(projectDir, modelWipes(stem, wiped))
        }
        return { settings, wiped, reset, notices }
    })
}

/**
 * The settings each model of a project overrides, read without a lock or a change: model
 * stem to the names of its overrides in the sheets' order, for the models that have any.
 * An unreadable file, a table that is no object and the settings of the whole run (which
 * a model cannot have) count for nothing.
 */
export function modelOverrides(
    projectDir: string,
    catalog: SettingsCatalog = defaultCatalog(),
): Map<string, string[]> {
    const out = new Map<string, string[]>()
    const read = readSettingsFile(modelSettingsFile(projectDir))
    if (read.state !== "ok") return out
    for (const [stem, table] of Object.entries(read.stored)) {
        if (!isDict(table)) continue
        const given = new Set<string>()
        for (const group of Object.values(table))
            if (isDict(group))
                for (const [name, entry] of Object.entries(group))
                    if (isDict(entry) && "value" in entry) given.add(name)
        const names = catalog
            .defs()
            .filter((d) => given.has(d.name) && !isRunLevel(d.name))
            .map((d) => d.name)
        if (names.length > 0) out.set(stem, names)
    }
    return out
}

// ========================================================================================
// 3. Scope
// ========================================================================================

/**
 * Whose settings a screen shows: the global ones that every new project starts from,
 * those of one project, or the overrides of one model of a project. The same sheets serve
 * all three; only where the file is and what "reset" returns to differ.
 */
export type Scope =
    | { kind: "global" }
    | { kind: "project"; project: ProjectRef }
    | { kind: "model"; project: ProjectRef; model: string }

/** The global scope. */
export const globalScope: Scope = { kind: "global" }

/** The scope of a project. */
export function projectScope(project: ProjectRef): Scope {
    return { kind: "project", project }
}

/** The scope of one model of a project (`model` is its stem, see [[modelStem]]). */
export function modelScope(project: ProjectRef, model: string): Scope {
    return { kind: "model", project, model }
}

/** The words that name a scope on a screen's title. */
export function scopeTitle(scope: Scope): string {
    if (scope.kind === "model") return "model settings"
    return scope.kind === "global" ? "global settings" : "project settings"
}

/**
 * Loads (and checks, and if need be repairs) the settings of a scope.
 *
 * @returns the settings and what was wiped on the way, see [[LoadResult]].
 * @throws if the bundled data is corrupt or a file cannot be written.
 */
export function loadScope(scope: Scope): LoadResult {
    if (scope.kind === "model") return loadModel(scope.project.dir, scope.model, appDir())
    return scope.kind === "global"
        ? loadGlobal(appDir())
        : loadProject(scope.project.dir, appDir())
}

// ========================================================================================
// 4. Theme preference
// ========================================================================================

/**
 * The theme the user last left the program in, kept as one global preference so the
 * next start opens in it. The file is `theme.json` in the BAYSOL folder:
 * `{ "theme": "graphite" }`, the name of the theme. The store knows no themes (the app
 * passes the names that exist), and it is only a preference: a missing or unusable
 * file means the default, and nothing about it may ever stop the program.
 */

/** The name of the file, defined here once. */
const themeFileName = "theme.json"

/** The path of the theme file. */
export function themeFile(dir: string): string {
    return join(dir, themeFileName)
}

/**
 * Reads the saved theme name.
 *
 * @param fallback - the name to give when nothing usable is saved (the default theme).
 * @returns the saved name; `fallback` when there is no file, it cannot be read, or it
 *     names a theme that is not in `known` (one removed since).
 */
export function readThemeName(
    dir: string,
    known: readonly string[],
    fallback: string,
): string {
    const file = themeFile(dir)
    if (!isFile(file)) return fallback
    const saved = readJson<undefined>(file, undefined)
    const name = isDict(saved) ? saved.theme : undefined
    return typeof name === "string" && known.includes(name) ? name : fallback
}

/**
 * Saves the theme name. A file that exists but cannot be used is kept as
 * `theme.json.corrupt` first, so it is never written over.
 *
 * @returns `true` if it was saved; `false` if the folder cannot be written (a
 *     preference that cannot be kept is not an error worth stopping for).
 */
export function writeThemeName(dir: string, name: string): boolean {
    const file = themeFile(dir)
    try {
        if (isFile(file) && !isDict(readJson<undefined>(file, undefined))) quarantine(file)
        writeAtomic(file, writeJson({ theme: name }))
        return true
    } catch {
        return false
    }
}
