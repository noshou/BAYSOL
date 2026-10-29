#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Runs the visual checks in test/visualize/ (plots of the geometry code; they
;; need a display, except `sasa_hydro_report`, which prints numbers only).
;;
;;     bb vis [NAME ...] [--list] [--dry-run]
;;
;;   NAME       the checks to run (see --list). Every one must exist, or nothing runs.
;;              With none given, every check runs, one after the other.
;;   --list     show the checks and what each one does
;;   --threads N  run the Julia processes with N threads (as `julia -t N`: 4, auto,
;;                4,1); default one
;;   --dry-run  print what would be run, run nothing
;;
;; Each check is one call in a fresh Julia process in test/visualize/'s
;; own environment. Needs Babashka and `julia` on the PATH (or
;; JULIA=/path/to/julia); shared helpers are in dev/common.clj.

;; The shared helpers live next to this script; put its folder on the classpath so
;; the script runs from any working directory.
(ns vis
 (:require [babashka.fs :as fs]
  [babashka.classpath :refer [add-classpath]]
  [clojure.string :as str]))

(add-classpath (str (fs/parent (fs/absolutize *file*))))

(require '[common :as c])

(def ^:private who "bb vis")

;; The checks, in the order they run: name, script in test/visualize/, the Julia call
;; that runs the check, and a one-line description for --list.
(def ^:private checks
 [{:name "plastic_2d",
   :script "plastic_vis.jl",
   :call "vis_plastic_points_2D(2000)",
   :doc "plastic sequence on a spherical surface (2-D generator)"}
  {:name "plastic_3d",
   :script "plastic_vis.jl",
   :call "vis_plastic_points_3D(2000)",
   :doc "plastic sequence filling a spherical volume (3-D generator)"}
  {:name "sasa_hydro",
   :script "sasa_hydro_vis.jl",
   :call "vis_sasa_hydro()",
   :doc "SASA hydration-shell dummy cloud over a packed cluster"}
  {:name "sasa_hydro_report",
   :script "sasa_hydro_vis.jl",
   :call "sasa_hydro_report()",
   :doc "the same, numbers only, no window (works headless)"}])

(defn ^:private command
 "The Julia command line of one check: include its script, then call it."
 [julia {:keys [script call]}]
 [julia "--startup-file=no" (str "--project=" (c/in-root "test" "visualize")) "-e"
  (str "include(\"" (c/in-root "test" "visualize" script) "\"); " call)])

(defn run
 "The tool's main program for the argument list `argv`; returns the exit status."
 [argv]
 (if (some #{"--help" "-h"} argv)
  (c/usage)
  (let [{:keys [flags specs]}
    (c/split-args who [] ["--list" "--dry-run"] argv "one of")
    by-name (into {} (map (juxt :name identity)) checks)
    missing (remove by-name specs)]
   (cond
    ;; --list: the checks and what each does
    (some #{"--list"} flags) (doseq [{check-name :name, doc :doc} checks]
     (println (format "%-18s %s" check-name doc)))
    ;; every name must exist before anything runs
    (seq missing) (c/fail who
     (str "no visual check named: "
      (str/join ", " missing)
      " (available: "
      (str/join " " (map :name checks))
      ")"))
    :else (let [julia (c/find-julia)
      dry (boolean (some #{"--dry-run"} flags))
      ;; none named: all of them, in order
      chosen (map by-name (or (seq specs) (map :name checks)))
      ;; run them all even if one fails, then name the failures
      failed (doall (for [chk chosen
         :let [_ (println (str "\n=== " (:name chk)))
          ok (c/sh dry (command julia chk))]
         :when (not ok)]
        (:name chk)))]
     (when (seq failed)
      (binding [*out* *err*]
       (println (str "\n" who ": failed: " (str/join ", " failed))))
      1))))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
 (c/main run *command-line-args*))
