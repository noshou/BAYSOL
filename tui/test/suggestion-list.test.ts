// SPDX-License-Identifier: LGPL-3.0-or-later

import assert from "node:assert/strict"
import { test } from "node:test"
import { positionStatus } from "../src/ui/suggestion-list.js"

test("positionStatus counts from one", () => {
    assert.equal(positionStatus(0, 12), "1 of 12")
    assert.equal(positionStatus(11, 12), "12 of 12")
})
