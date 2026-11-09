// SPDX-License-Identifier: LGPL-3.0-or-later

import { spawn } from "node:child_process"
import { fileURLToPath } from "node:url"
import type { Launcher } from "../../src/store/run.js"
import { RunSession } from "../../src/store/run.js"

const fake = fileURLToPath(new URL("./fake-julia.ts", import.meta.url))

/** The launcher that runs the fake Julia in `mode`, in a process group of its own. */
export function fakeLauncher(mode: string): Launcher {
    return (spec) =>
        spawn(
            process.execPath,
            [
                "--import",
                "tsx",
                fake,
                spec.projectDir,
                String(spec.temperature),
                spec.runDir,
            ],
            {
                detached: true,
                stdio: ["pipe", "pipe", "pipe"],
                env: { ...process.env, FAKE_MODE: mode, FAKE_PIDFILE: "" },
            },
        )
}

/**
 * Makes one finished run of a project with the fake Julia in `plots` mode: a model `m`
 * with its figures and a comparison, as a real run leaves them.
 *
 * @param projectDir - a project folder with the inputs of a run.
 * @param pack - what packs the run (the real packer when left out; one that throws leaves
 *     the run plain).
 * @returns the run's folder and name.
 */
export async function makeRun(
    projectDir: string,
    pack?: (runDir: string) => Promise<number>,
): Promise<{ dir: string; id: string }> {
    const session = RunSession.begin(projectDir, 25, fakeLauncher("plots"), pack)
    await session.done
    return { dir: `${projectDir}/runs/${session.view.id}`, id: session.view.id }
}
