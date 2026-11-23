// SPDX-License-Identifier: LGPL-3.0-or-later

// Tests of the help screen text and of the setup wizard call (`screens/help-screen.tsx`,
// `runSetupWizard` of `core/file-system.ts`).

import assert from "node:assert/strict"
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"
import { runSetupWizard, SETUP_UNINSTALLED } from "../src/core/file-system.js"
import { helpText } from "../src/screens/help-screen.js"

/** A bundle whose `baysol` exits with a status. */
function fakeBundle(status: number): string {
    const dir = mkdtempSync(join(tmpdir(), "baysol-help-"))
    const launcher = join(dir, "baysol")
    writeFileSync(launcher, `#!/bin/sh\nexit ${status}\n`)
    chmodSync(launcher, 0o755)
    return dir
}

test("the help text covers setup and uninstalling", () => {
    const text = helpText()
    assert.match(text, /Setup wizard/)
    assert.match(text, /Uninstall/)
    assert.match(text, /baysol setup/)
})

test("without a packaged app the wizard is a problem, not an uninstall", () => {
    const result = runSetupWizard({})
    assert.equal(result.uninstalled, false)
    assert.match(result.problem ?? "", /packaged app/)
})

const posixOnly = { skip: process.platform === "win32" }

test("the wizard's exit status says whether the app was uninstalled", posixOnly, () => {
    assert.deepEqual(runSetupWizard({ BAYSOL_BUNDLE: fakeBundle(0) }), { uninstalled: false })
    assert.deepEqual(runSetupWizard({ BAYSOL_BUNDLE: fakeBundle(SETUP_UNINSTALLED) }), {
        uninstalled: true,
    })
})
