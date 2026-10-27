#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Profiles the static build of fitting tests: where the seed build (structure,
;; SASA, the B_lm expansion, the Gram matrix) spends its time, by function.
;;
;;     bb profile ID[:tag] [ID[:tag] ...] [--delay SECONDS] [--nuts] [--dry-run]
;;
;;   ID[:tag]   fitting tests to profile (SASDMJ9, SASDBS6:fit2_model3, ...); every
;;              ID must exist
;;   --delay    the profiler's sampling interval (default 0.0005 s)
;;   --nuts     also profile the sampling (MAP search and NUTS) of each fit, after a
;;              short run that warms the compiler
;;   --threads N  run the Julia processes with N threads (as `julia -t N`: 4, auto,
;;              4,1); default one
;;   --dry-run  print the command, run nothing
;;
;; Each is built twice in one process (the first call warms the compiler) and the
;; second build is profiled (dev/profile_seed.jl): the stage timings of that
;; build, and the samples by function, exclusive and inclusive, for frames in
;; BAYSOL's own source. This is development tooling for performance work, not a
;; benchmark: use it to find what to optimize, and `bb fitting-tests --bench --approved`
;; or the fitting-test run logs to measure it. Needs Babashka and `julia` on the PATH
;; (or JULIA=/path/to/julia); shared helpers are in dev/common.clj.

(ns profile
    (:require [babashka.classpath :refer [add-classpath]]
        [babashka.fs :as fs]))

(add-classpath (str (fs/parent (fs/absolutize *file*))))

(require '[common :as c])

(def ^:private who "bb profile")

(defn run
    "The tool's main program for the argument list `argv`; returns the exit status."
    [argv]
    (if (some #{"--help" "-h"} argv)
        (c/usage)
        (let [{:keys [opts flags specs]}
                (c/split-args who ["--delay"] ["--nuts" "--dry-run"] argv)
                interval (get (into {} opts) "--delay")]
            (when (empty? specs) (c/fail who "give at least one ID[:tag]"))
            (c/check-folders who specs)
            ;; one Julia process profiles every spec, so the compiler warms up once
            (let [cmd (concat [(c/find-julia) "--startup-file=no"
                            (str "--project=" (c/in-root c/fit-dir))
                            (c/in-root "dev" "profile_seed.jl")]
                        (when interval ["--delay" interval])
                        (when (some #{"--nuts"} flags) ["--nuts"])
                        specs)]
                ;; a failed run is the tool's failure: status 1
                (when-not (c/sh (boolean (some #{"--dry-run"} flags)) cmd) 1)))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
    (c/main run *command-line-args*))
