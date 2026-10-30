;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The one place the program says something about itself outside the screens: a line on
;; stderr. Every namespace logs through here, so a different logger (clojure.tools.logging,
;; a file) would be a change in this file only.

(ns baysol.tui.log
 (:require [clojure.string :as str]))

(defn ^:private say!
 "Prints `level` and the `parts` joined by spaces as one line on stderr; returns nil."
 [level parts]
 (binding [*out* *err*] (println (str "BAYSOL " level ": " (str/join " " parts))))
 nil)

(defn warn!
 "Prints a warning line on stderr; returns nil."
 [& parts]
 (say! "warning" parts))

(defn error!
 "Prints an error line on stderr; returns nil."
 [& parts]
 (say! "error" parts))
