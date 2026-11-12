// SPDX-License-Identifier: LGPL-3.0-or-later

/**
 * The restores of a run's inputs: the `restore ...` options of the logs menu put a run's
 * own copy of its settings, buffer, or units and energy back into the project. The
 * reading of the run (its LOG, its files) is `run-logs.ts`.
 */

import {
    ChangedOnDiskError,
    FileInUseError,
    isDict,
    ParentMissingError,
    parseJson,
    UnusableFileError,
} from "../core/file-system.js"
import {
    type BufferRow,
    type Conditions,
    conditionsOf,
    readSolutes,
    rowProblem,
    writeSolutes,
} from "./buffer.js"
import {
    type DataMapping,
    type EnergyUnit,
    energyUnitsList,
    readMapping,
    setEnergy,
    setUnits,
    type Units,
} from "./data.js"
import { DataFileError } from "./data-table.js"
import { assertNoLiveRun, RunInProgressError } from "./projects.js"
import { RUN_FILES } from "./run-archive.js"
import { defaultCatalog } from "./settings.js"
import { loadProject, wipeInvalid } from "./settings-store.js"

/**
 * Putting a run's inputs back into the project (the `restore ...` options of the logs
 * menu). The caller reads the text of the run's own copy (`settings.json`, `buffer.json`,
 * `data.tsv`, `data.json`) and hands it here; nothing is ever written into the run, and
 * every write goes through the store that owns the file (its validation, its lock, its
 * atomic replace, `ChangedOnDiskError`). Every restore refuses while a run of the project
 * is live, and says in a short sentence what is wrong with a file it cannot use; nothing
 * is written then.
 */

/** The error of a run file that cannot be restored; the message is short, for a note. */
export class RestoreError extends Error {}

/**
 * The JSON object in a text.
 *
 * @throws [[RestoreError]] `<name> is not usable` for anything else.
 */
function objectOf(text: string, name: string): Record<string, unknown> {
    let value: unknown
    try {
        value = parseJson(text)
    } catch {
        throw new RestoreError(`${name} is not usable`)
    }
    if (!isDict(value)) throw new RestoreError(`${name} is not usable`)
    return value
}

/**
 * Restores the settings of the project to those of a run: every setting the run's
 * `settings.json` holds (a value that is not valid is left out) is set, and a setting the
 * project has saved that the run's file lacks goes to its default (that is what the run
 * used). The values are checked together with the rules between settings and saved
 * through the settings store (its lock and merge).
 *
 * @param globalDir - the BAYSOL folder (the baseline of a project's settings).
 * @throws [[RestoreError]] for a file that is no settings map or whose values break a
 *     rule; `RunInProgressError` for a live run; whatever the store throws (project gone,
 *     file in use).
 */
export function restoreSettings(project: string, globalDir: string, text: string): void {
    const stored = objectOf(text, RUN_FILES.settings)
    assertNoLiveRun(project)
    const catalog = defaultCatalog()
    const { settings } = loadProject(project, globalDir, catalog)
    const kept = wipeInvalid(catalog, stored).saved
    const changes: Record<string, unknown> = Object.fromEntries(kept)
    for (const def of catalog.defs())
        if (!kept.has(def.name) && settings.isSaved(def.name))
            changes[def.name] = def.default
    const result = settings.set(changes)
    if (!result.ok) {
        const first = [...result.errors][0]
        throw new RestoreError(first ? `${first[0]} ${first[1]}` : "settings are not valid")
    }
    settings.save()
}

/**
 * What a run's `buffer.json` holds, for the question before it replaces the buffer.
 *
 * @returns the solutes and the conditions (`undefined` when it has none).
 * @throws [[RestoreError]] for a file that is not a buffer.
 */
export function bufferFacts(text: string): {
    rows: BufferRow[]
    conditions: Conditions | undefined
} {
    const map = objectOf(text, RUN_FILES.buffer)
    const rows = map.solutes
    if (!Array.isArray(rows)) throw new RestoreError("buffer.json has no solutes")
    for (const row of rows) {
        if (rowProblem(row) !== undefined)
            throw new RestoreError("buffer.json is not usable")
    }
    return { rows: rows as BufferRow[], conditions: conditionsOf(map) }
}

/**
 * Starts watching the project's buffer file for the replace question: the version read
 * now is the one [[restoreBuffer]] checks, so a save by another copy while the question
 * is open makes the restore refuse (`ChangedOnDiskError`) instead of losing that save.
 * A buffer that cannot be read is not watched (the restore says why).
 */
export function watchBuffer(project: string): void {
    try {
        readSolutes(project, { track: true })
    } catch {
        // an unusable file: the restore reports it
    }
}

/**
 * Restores the buffer of the project to a run's: its solutes and its pH and σ in ONE
 * write (a run file without conditions leaves the project's own).
 *
 * @throws [[RestoreError]] for a file that is not a buffer; `RunInProgressError` for a
 *     live run; `ChangedOnDiskError`, `UnusableFileError`, `ProjectGoneError` from the
 *     buffer store.
 */
export function restoreBuffer(project: string, text: string): void {
    const { rows, conditions } = bufferFacts(text)
    assertNoLiveRun(project)
    writeSolutes(project, rows, conditions)
}

/**
 * The units, energy, source and import mapping of a run's `data.json`, checked.
 *
 * @returns the units of q, the X-ray energy (`undefined` when the run had none), the name
 *     of the file the curve came from and the mapping of the import, if it says.
 * @throws [[RestoreError]] `data.json is not usable` for units that are none of the two
 *     or an energy that is no number above 0.
 */
function infoOf(json: string): {
    units: Units
    energy?: number
    energyUnit: EnergyUnit
    source?: string
    mapping?: DataMapping
} {
    const info = objectOf(json, RUN_FILES.dataInfo)
    const { units, energy, energy_unit, source, mapping } = info
    const badUnits = units !== "nm-1" && units !== "A-1"
    const badEnergy = energy != null && !(typeof energy === "number" && energy > 0)
    // the energy unit is a label, and always written
    const badEnergyUnit = !energyUnitsList.includes(energy_unit as EnergyUnit)
    if (badUnits || badEnergy || badEnergyUnit)
        throw new RestoreError("data.json is not usable")
    return {
        units: units as Units,
        energy: typeof energy === "number" ? energy : undefined,
        energyUnit: energy_unit as EnergyUnit,
        source: typeof source === "string" ? source : undefined,
        mapping: readMapping(mapping),
    }
}

/**
 * Restores the units of q and the X-ray energy of the project's data to a run's: only
 * `data.json` is written (the table and the mapping never), through the data store's
 * edits.
 *
 * @throws [[RestoreError]] when it is not usable; `DataFileError` `no data yet` when the
 *     project has no data; `RunInProgressError` for a live run; `UnusableFileError`.
 */
export function restoreUnits(project: string, json: string): void {
    const { units, energy, energyUnit } = infoOf(json)
    assertNoLiveRun(project)
    setUnits(project, units)
    // the energy comes back with its unit label: a number alone would be read as eV
    if (energy !== undefined) setEnergy(project, energy, energyUnit)
}

/**
 * The words for a failure of a restore, for the line of a screen.
 *
 * @returns the message of the errors that say it themselves (a restore, the data store,
 *     an unusable file, a live run, another copy's save or lock, a deleted project), else
 *     `could not restore`.
 */
export function restoreErrorNote(error: unknown): string {
    const speaks =
        error instanceof RestoreError ||
        error instanceof DataFileError ||
        error instanceof UnusableFileError ||
        error instanceof RunInProgressError ||
        error instanceof ChangedOnDiskError ||
        error instanceof FileInUseError ||
        error instanceof ParentMissingError
    return speaks ? (error as Error).message : "could not restore"
}
