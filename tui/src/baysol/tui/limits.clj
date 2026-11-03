;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Limits that more than one part of the TUI shares, so that none of them owns the number.

(ns baysol.tui.limits)

(def max-rows
 "The most rows a list of solutes holds, in the buffer and in the custom solutes: the
 counters of the tables have room for three digits. Adding stops there (the `add`
 legends of the footer disappear), and a file that holds more is unusable."
 999)
