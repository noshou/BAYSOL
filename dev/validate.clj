#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Runs a validation: a slow, suite-wide check of one change
;; against criteria fixed before the run (test/validation/<name>/).
;;
;;     bb validate --list
;;     bb validate NAME [ID[:tag] ...] [--approved] [--dry-run]
;;
;;   --list      the validations and the question each answers
;;   NAME        a folder of test/validation/ (shannon_binning, map_fstop, ...). An
;;               unknown name stops before anything runs.
;;   ID ...      the fitting tests to run it on (SASDMJ9, SASDBS6, ...); every one
;;               must exist. None: all of them.
;;   --approved  the owner has approved this run. Without it the validation is a
;;               no-op that only prints its plan. Why: a validation runs the MAP
;;               search (or more) of dozens of fits, minutes of one core, and AI
;;               agents tend to start such runs unasked, so the owner's per-run
;;               approval is a small safeguard.
;;   --threads N  run the Julia processes with N threads (as `julia -t N`: 4, auto,
;;               4,1); default one
;;   --dry-run   print the command, run nothing
;;
;; With --approved the validation's script runs (Julia, in the
;; test/fitting_tests environment) and writes its per-fit rows to
;; test/validation/NAME/results/NAME-<stamp>.tsv, which is the evidence
;; the validation's README refers to; it prints its verdict against the
;; criteria in its README. Needs Babashka and `julia` on the PATH (or
;; JULIA=/path/to/julia); shared helpers are in test/utils/common.clj.

(ns validate
    (:require [babashka.classpath :refer [add-classpath]]
        [babashka.fs :as fs]
        [clojure.string :as str])
    (:import (java.time LocalDateTime)
        (java.time.format DateTimeFormatter)))

(add-classpath (str
        (fs/path (fs/parent (fs/absolutize *file*)) ".." "test" "utils")))

(require '[common :as c])

(def ^:private who "bb validate")

(defn- validations
    "The validations: the sub-folders of test/validation/ that hold a validate.jl,
    sorted by name."
    []
    (->> (fs/glob (c/in-root "test" "validation") "*/validate.jl")
        (map #(str (fs/file-name (fs/parent %))))
        sort))

(defn- question
    "The question of validation `name`: the first paragraph after the title of its
    README, on one line."
    [validation]
    (->> (rest (str/split-lines
                (c/slurp8 (c/in-root "test" "validation" validation "README.md"))))
        (map str/trim)
        ;; blank lines before the paragraph are skipped, the next blank line ends it
        (drop-while str/blank?)
        (take-while (complement str/blank?))
        (str/join " ")))

(defn- specs-for
    "The ID[:tag] specs to run: a bare ID stands for every run of its script, an
    ID:tag names one; no IDs at all means every fitting test."
    [requested]
    (mapcat #(if (str/includes? % ":") [%] (c/specs-of [%]))
        (or (seq requested) (c/ids))))

(defn run
    "The tool's main program for the argument list `argv`; returns the exit status."
    [argv]
    (if (some #{"--help" "-h"} argv)
        (c/usage)
        (let [{:keys [flags specs]} (c/split-args who
                    []
                    ["--list" "--approved"
                        "--dry-run"]
                    argv
                    "one of")
                [validation & requested] specs
                names (validations)
                flag? (set flags)]
            (cond
                (flag? "--list") (doseq [n names]
                    (println (format "%-16s %s" n (question n))))
                (nil? validation)
                (c/fail who "give a validation name (see: bb validate --list)")
                (not (some #{validation} names)) (c/fail who
                    (str "no validation '"
                        validation
                        "' (available: "
                        (str/join " " names)
                        ")"))
                :else
                (do (c/check-folders who requested)
                    (let [julia (c/find-julia)
                            stamp (.format (LocalDateTime/now)
                                (DateTimeFormatter/ofPattern
                                    "yyyyMMdd-HHmmss"))
                            out (c/in-root "test"
                                "validation" validation
                                "results"
                                (str validation "-" stamp ".tsv"))
                            cmd
                            (concat
                                [julia "--startup-file=no"
                                    (str "--project=" (c/in-root "test" "fitting_tests"))
                                    (c/in-root "test" "validation" validation "validate.jl")
                                    "--out" out]
                                (specs-for requested))]
                        (if-not (flag? "--approved")
                            ;; the safeguard: show the plan and stop
                            (println
                                (str
                                    "validation "
                                    validation
                                    ": not running. "
                                    (question validation)
                                    "\nIt needs the repository owner's explicit approval"
                                    " (minutes of one core, writes only a TSV);\n"
                                    "re-run with --approved once it has been approved.\n"
                                    "Planned: " (str/join " " cmd)))
                            ;; `sh` prints the command, and runs it unless --dry-run
                            (let [dry (boolean (flag? "--dry-run"))]
                                (when-not dry (fs/create-dirs (fs/parent out)))
                                (cond (not (c/sh dry cmd))
                                    (do (binding [*out* *err*]
                                            (println
                                                (str who ": " validation " failed")))
                                        1)
                                    (not dry) (println (str "results: "
                                            out)))))))))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
    (c/main run *command-line-args*))
