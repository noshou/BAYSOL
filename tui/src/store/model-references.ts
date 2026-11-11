// SPDX-License-Identifier: LGPL-3.0-or-later

// The reference curve of a single model: `<project>/model-references.json`, which Julia
// reads (`{"<model file stem>": {"tag", "software", "ref_chi2", "fit", "rescale"}}`). A
// deposited entry has one fit file and one χ² for each atomic model, and the run draws
// that curve with the data and the model's MAP curve, with both χ², on the model's own
// figure and writes the χ² in the model's LOG.
//
// The file is SPARSE: a model with nothing set has no entry, and a model that is no
// longer in the project keeps its entry (Julia ignores it with a note). The columns and
// the units of the curve were chosen when it was imported into `reference-fit/`, so
// `fit` is only the name of that file.

import { join } from "node:path"
import {
    isDict,
    isFile,
    quarantine,
    readJson,
    writeAtomic,
    writeJson,
} from "../core/file-system.js"
import { lockedIn } from "./projects.js"

/**
 * What a model is given.
 *
 * @property tag - what the curve is called for this model (`fit3_model1`).
 * @property software - the program that made it (`MultiFoXS 2-state`).
 * @property refChi2 - the depositor's χ² with its method (`MultiFoXS 2-state 0.79`).
 * @property fit - the file of `reference-fit/` that is the model's curve (`fit3.tsv`).
 * @property rescale - whether the curve is scaled onto the measured one (a normalized
 *     fit file).
 */
export type ModelReference = {
    tag: string
    software: string
    refChi2: string
    fit: string
    rescale: boolean
}

/** A model that is given nothing. */
export const EMPTY_MODEL_REFERENCE: ModelReference = {
    tag: "",
    software: "",
    refChi2: "",
    fit: "",
    rescale: false,
}

/** The longest any of the texts is (cells), so every screen can show it. */
export const MAX_REFERENCE_TEXT = 40

/** @returns the path of a project's `model-references.json`. */
export const modelReferencesFile = (projectDir: string): string =>
    join(projectDir, "model-references.json")

/** The JSON keys of an entry, by field. */
const jsonKey: Record<keyof ModelReference, string> = {
    tag: "tag",
    software: "software",
    refChi2: "ref_chi2",
    fit: "fit",
    rescale: "rescale",
}

/** @returns an entry as the file holds it: only what is set, in the JSON keys. */
function toEntry(ref: ModelReference): Record<string, unknown> {
    const out: Record<string, unknown> = {}
    for (const field of ["tag", "software", "refChi2", "fit"] as const)
        if (ref[field].trim() !== "") out[jsonKey[field]] = ref[field].trim()
    if (ref.rescale) out[jsonKey.rescale] = true
    return out
}

/** @returns an entry of the file as a [[ModelReference]]; what is not valid is unset. */
function fromEntry(entry: unknown): ModelReference {
    const ref = { ...EMPTY_MODEL_REFERENCE }
    if (!isDict(entry)) return ref
    for (const field of ["tag", "software", "refChi2", "fit"] as const) {
        const value = entry[jsonKey[field]]
        if (typeof value === "string") ref[field] = value
        else if (typeof value === "number") ref[field] = String(value)
    }
    ref.rescale = entry[jsonKey.rescale] === true
    return ref
}

/** @returns whether nothing is set. */
const isEmptyReference = (ref: ModelReference): boolean =>
    Object.keys(toEntry(ref)).length === 0

/**
 * Every model's entry, read without a lock (a screen's read; a save re-reads under the
 * lock). A missing or unreadable file gives none.
 *
 * @returns the entries by model stem; models with nothing set are not in it.
 */
export function readModelReferences(projectDir: string): Map<string, ModelReference> {
    const content = readJson(modelReferencesFile(projectDir), null)
    const out = new Map<string, ModelReference>()
    if (!isDict(content)) return out
    for (const [stem, entry] of Object.entries(content)) {
        const ref = fromEntry(entry)
        if (!isEmptyReference(ref)) out.set(stem, ref)
    }
    return out
}

/**
 * @returns a model's entry (all unset for a model that has none).
 */
export const modelReference = (projectDir: string, stem: string): ModelReference =>
    readModelReferences(projectDir).get(stem) ?? { ...EMPTY_MODEL_REFERENCE }

/**
 * Saves one model's entry under the lock of the file, inside the project, over the file as
 * it is then (another model's entry, even one this program does not know, is kept
 * as it is). An entry with nothing set removes the model's key; nothing is made when there
 * is no file and nothing to put in it. A file that is not an object is kept as
 * `model-references.json.corrupt` and replaced.
 *
 * @throws ProjectGoneError, FileInUseError, or what the write throws.
 */
export function saveModelReference(
    projectDir: string,
    stem: string,
    ref: ModelReference,
): void {
    const file = modelReferencesFile(projectDir)
    lockedIn(projectDir, file, () => {
        let stored = readJson(file, undefined)
        if (stored !== undefined && !isDict(stored)) {
            quarantine(file)
            stored = undefined
        }
        const out: Record<string, unknown> = isDict(stored) ? { ...stored } : {}
        const entry = toEntry(ref)
        if (Object.keys(entry).length === 0) {
            if (!isFile(file)) return
            delete out[stem]
        } else out[stem] = entry
        writeAtomic(file, writeJson(out), { createParents: false })
    })
}
