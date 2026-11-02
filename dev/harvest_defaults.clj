#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Writes the default of every setting of the terminal interface to one file, the colours
;; the settings may take to another, and the rules that tie settings together to a third.
;;
;;     bb harvest-defaults [--check]
;;
;;   (no option)  runs `dev/harvest_defaults.jl`, which reads the constants of the
;;                Params.jl files and the pages of the settings screens and writes
;;                tui/resources/default_settings.edn and, beside it, colours.txt (every
;;                colour name with its colour), then formats the first the way `bb fmt`
;;                does (a page whose setting no constant has is an error)
;;   --check      changes nothing: harvests into scratch files next to them and exits 1
;;                if default_settings.edn, colours.txt or setting_relations.edn differs,
;;                that is, is out of date
;;
;; `bb precommit` runs the first form, so the file changed by a commit belongs to it.

(ns harvest-defaults
 (:require [babashka.classpath :refer [add-classpath]]
  [babashka.fs :as fs]
  [clojure.string :as str]))

(add-classpath (str (fs/parent (fs/absolutize *file*))))

(require '[common :as c])

(def ^:private who "bb harvest-defaults")

(def ^:private defaults-file
 (c/in-root "tui" "resources" "default_settings.edn"))

(def ^:private colours-file (c/in-root "tui" "resources" "colours.txt"))

(def ^:private relations-file (c/in-root "tui" "resources" "setting_relations.edn"))

(defn ^:private harvest!
 "Harvests the defaults into the file `out` (and the colours and the rules beside it) and
 formats the two EDN files; true on success."
 [out]
 (let [rules (str/replace out "default_settings" "setting_relations")]
  (and (c/sh false
    (or (System/getenv "JULIA") "julia")
    "--startup-file=no"
    (str "--project=" c/*root*)
    (c/in-root "dev" "harvest_defaults.jl")
    out)
   (c/sh false "bb" (c/in-root "dev" "format.clj") "--apply" out rules))))

(defn run
 "The tool's main program for the argument list `argv`; returns the exit status."
 [argv]
 (if (some #{"--help" "-h"} argv)
  (c/usage)
  (let [unknown (first (remove #{"--check"} argv))]
   (when unknown
    (c/fail who (str "unknown option " unknown " (the only one is --check)")))
   (if (some #{"--check"} argv)
    (let [scratch (c/in-root "tui" "resources" "default_settings.check.edn")
      scratch-colours (c/in-root "tui" "resources" "colours.check.txt")
      scratch-rules (c/in-root "tui" "resources" "setting_relations.check.edn")
      same? (fn [fresh old]
       (= (c/slurp8 fresh) (when (fs/exists? old) (c/slurp8 old))))]
     (try
      (cond
       (not (harvest! scratch)) 1
       (and (same? scratch defaults-file)
        (same? scratch-colours colours-file)
        (same? scratch-rules relations-file))
       (do (println
         (str who ": the defaults, the colours and the rules are up to date"))
        0)
       :else
       (do
        (println
         (str
          who
          ": default_settings.edn, colours.txt or setting_relations.edn is out of date"))
        1))
      (finally (fs/delete-if-exists scratch)
       (fs/delete-if-exists scratch-colours)
       (fs/delete-if-exists scratch-rules))))
    (when-not (harvest! defaults-file) 1)))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
 (c/main run *command-line-args*))
