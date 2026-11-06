// SPDX-License-Identifier: LGPL-3.0-or-later

import { readSolutes } from "./buffer.js"
import { dataIsReady } from "./data.js"
import { listModels } from "./models.js"
import type { ProjectRef } from "./scope.js"

/**
 * What a project has of what a run needs, one flag each.
 *
 * @property models - at least one model.
 * @property buffer - a buffer with at least one solute (a buffer file that cannot be
 *     read counts as missing).
 * @property data - the measured curve is loaded (`data.tsv` and `data.json` valid) and
 *     the X-ray energy is set (there is no default energy); the pH of the buffer will
 *     join it later.
 * @property run - everything above is there, so a run can start.
 */
export type Readiness = {
    models: boolean
    buffer: boolean
    data: boolean
    run: boolean
}

/**
 * Whether a project can run a fit, and which parts it still lacks. The project menu
 * shows the `run` item of its taskbar only when `run` is true.
 *
 * @param project - the project.
 * @returns the flags, see [[Readiness]].
 * @throws never: a folder that cannot be read counts as missing parts.
 */
export function projectReadiness(project: ProjectRef): Readiness {
    let models = false
    try {
        models = listModels(project.dir).length > 0
    } catch {
        models = false
    }
    let buffer = false
    try {
        buffer = readSolutes(project.dir).length > 0
    } catch {
        buffer = false
    }
    let data = false
    try {
        data = dataIsReady(project.dir)
    } catch {
        data = false
    }
    return { models, buffer, data, run: models && buffer && data }
}
