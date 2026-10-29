#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Runs the end-to-end fitting tests (test/fitting_tests/<ID>/): each is a script
;; that fits one SASBDB entry and writes its workbook, figures and run log next to it.
;;
;;     bb fitting-tests --list
;;     bb fitting-tests [ID ...] [--no-fit] [--bench] [--approved] [--report]
;;         [--table] [--fixme] [--trace-compile FILE] [--dry-run]
;;
;;   --list     print the ID of every fitting test, one per line, and run nothing
;;   ID         the fitting-test folders to run (SASDMJ9, SASDBS6, ...). Every one
;;              must exist, or nothing runs. With none given, every fitting test runs.
;;   --bench    also run the cold / steady-state benchmark on the selected fits
;;              (bb bench)
;;   --approved  with --bench: the owner has approved this benchmark run. Without it
;;              the benchmark is a no-op that only prints its plan. Why: timings
;;              need a quiet machine, and AI agents tend to start a benchmark
;;              without checking for one, so the owner's per-run approval (their
;;              confirmation that nothing else is running) is a small safeguard.
;;   --no-fit   skip the fits themselves (the later steps read the logs earlier fits left)
;;   --report   afterwards, print the Results-table rows of the selected fits
;;              (bb results-table)
;;   --table    afterwards, rewrite the Results table in test/fitting_tests/README.md
;;              from all the run logs (bb results-table --update); covers
;;              every fit, whatever IDs are named
;;   --fixme    afterwards, run the sampler diagnostics on the selected fits
;;              (bb diagnose --report)
;;   --trace-compile FILE  run the fits with Julia's --trace-compile=FILE (the
;;              methods each fit's process compiles at run time, which a precompile
;;              workload should have covered; one file for all the fits, appended)
;;   --threads N  run the Julia processes with N threads (as `julia -t N`: 4, auto,
;;              4,1); default one
;;   --dry-run  print what would be run, run nothing
;;
;; The steps run in that order: the fits, the benchmark, the report, the
;; table, the diagnostics. A failing fit does not stop the others; the
;; exit status is 1 if any step failed. The fits rewrite the workbook, the figures and the
;; run log in their folders. Needs Babashka and `julia` on the PATH (or
;; JULIA=/path/to/julia); shared helpers are in dev/common.clj.

(ns fitting-tests
 (:require [babashka.classpath :refer [add-classpath]]
  [babashka.fs :as fs]
  [clojure.string :as str]))

(add-classpath (str (fs/parent (fs/absolutize *file*))))

(require '[common :as c])

(def ^:private who "bb fitting-tests")

(def ^:private flag-names
 ["--list" "--bench" "--approved" "--no-fit" "--report" "--table" "--fixme"
  "--dry-run"])

;; The options that take a value.
(def ^:private valued ["--trace-compile"])

(defn ^:private tool
 "The command that runs another Babashka tool of the repository by its task name:
 `bb <task> args`."
 [task & args]
 (into ["bb" task] args))

(defn ^:private steps
 "The steps to run, in order, as [label failure-name command-or-fn]. Each has a
 command (a vector, run with `sh`) and runs only if its flag was given (the fits
 unless --no-fit)."
 [{:keys [flag? selected requested julia trace]}]
 (concat
  ;; 1. the fits: one Julia process per fitting test, in the fitting-test project
  (when-not (flag? "--no-fit")
   (for [id selected]
    [(str "fit: " id) (str "fit " id)
     (concat [julia "--startup-file=no"]
      (when trace [(str "--trace-compile=" trace)])
      [(str "--project=" (c/in-root c/fit-dir)) (c/script-of id)])]))
  ;; 2. the benchmark (a no-op that prints its plan unless --approved is given)
  (when (flag? "--bench")
   [["benchmark" "benchmark"
     (concat (tool "bench")
      (when (flag? "--approved") ["--approved"])
      (c/specs-of selected))]])
  ;; 3. the report: the Results-table rows of the selected fits
  (when (flag? "--report")
   [["report" "report" (apply tool "results-table" requested)]])
  ;; 3b. the Results table of the fitting tests' README
  (when (flag? "--table") [["table" "table" (tool "results-table" "--update")]])
  ;; 4. the diagnostics
  (when (flag? "--fixme")
   [["diagnostics" "diagnostics"
     (apply tool "diagnose" "--report" (c/specs-of selected))]])))

(defn run
 "The tool's main program for the argument list `argv`; returns the exit status."
 [argv]
 (if (some #{"--help" "-h"} argv)
  (c/usage)
  (let [{:keys [opts flags specs]}
    (c/split-args who valued flag-names argv "one of")
    flag? (set flags)
    trace (some-> (get (into {} opts) "--trace-compile")
     fs/absolutize
     str)]
   (when (and (flag? "--approved") (not (flag? "--bench")))
    (c/fail who "--approved only applies together with --bench"))
   ;; every folder asked for must exist; none asked for means all of them
   (c/check-folders who specs false)
   (if (flag? "--list")
    (run! println (c/ids))
    (let [selected (or (seq specs) (c/ids))
      julia (c/find-julia)
      dry (boolean (flag? "--dry-run"))
      ;; a failing step does not stop the others
      failed (doall (for [[label failure cmd] (steps {:flag? flag?,
           :selected selected,
           :requested specs,
           :julia julia,
           :trace trace})
         :let [_ (println (str "\n=== " label))]
         :when (not (binding [c/*dir* (when (= "bb"
              (first cmd))
             c/*root*)]
           (c/sh dry cmd)))]
        failure))]
     (when (seq failed)
      (binding [*out* *err*]
       (println (str "\n" who ": failed: " (str/join ", " failed))))
      1))))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
 (c/main run *command-line-args*))
