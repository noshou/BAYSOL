#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Sampler diagnostics on SASBDB fitting tests, without
;; rerunning their fits or reports: every part by default.
;;
;;     bb diagnose [--report] [--ablate] [--residuals] [--warmup]
;;         [--tolerance] [--chains] [options] [ID[:tag] ...]
;;     bb diagnose --list
;;
;; Parts (each is one Julia process, test/utils/diagnose.jl,
;; which loads the fit's Seed and runs the part):
;;   --report     MAP starts, Hessian, NUTS step size and depth, Laplace agreement,
;;                modes, gradient error
;;   --ablate     chi-squared with one shared shell contrast / drho1=drho2 + drho3 /
;;                the full model
;;   --residuals  are the residuals at the MAP white (lag-1, runs z), reduced
;;                chi-squared on the fitted and measured grid
;;   --warmup     how short can the warm-up be and how many draws are enough: step
;;                size along a long reference warm-up, runs with 50..1000 adaptation
;;                iterations against it, ESS vs draws
;;   --tolerance  NUTS at several c1 profiling tolerances and RNG seeds (is the
;;                tolerance tight enough?)
;;   --chains     every chain of infer (the 8 chains run_model uses): start distance,
;;                posterior mode, divergences, step size, steps, acceptance, and each
;;                divergent draw, to see which chains a fit's divergences come from.
;;                --seeds is the run's rng_seed (default 7; pass the one in a report's
;;                === Run === section to look at that run); --retry 1: the rerun infer does
;;                when R̂ is above the limit (2000 + 2000, derived seeds), kept or not
;; With none of the part flags, all six run, in
;; this order. Name one or more to run only those.
;;
;; Options (each is passed to the parts that accept it):
;;   --samples N --adapt N   NUTS iterations (report, tolerance, chains; default:
;;   run_model)
;;   --tols 1e-5,1e-8        c1 tolerances (tolerance)
;;   --seeds 1,2,3           RNG seeds (warmup, tolerance, chains; default 7)
;;   --out DIR               write DIR/<part>.txt for each part instead of stdout
;;   --threads N  run the Julia processes with N threads (as `julia -t N`: 4, auto,
;;                4,1); default one
;;   --dry-run               print the commands, run nothing
;;   --list                  the fitting tests and their tags
;;
;; `ID` is a folder under test/fitting_tests/ (SASDBS6); `tag` picks one run of a
;; script that has several (fit2_model3); scripts with a single run take no tag. With
;; no ID, every run of every fitting test (53 fits). The command line is checked before
;; Julia starts. Needs Babashka, and `julia` on the PATH (or JULIA=/path/to/julia).

(ns diagnose
    (:require [babashka.classpath :refer [add-classpath]]
        [babashka.fs :as fs]
        [clojure.string :as str]))

(add-classpath (str
        (fs/path (fs/parent (fs/absolutize *file*)) ".." "test" "utils")))

(require '[common :as c])

(def ^:private who "bb diagnose")

;; The parts, in the order they run (the slow ones last), each with the options it
;; accepts.
(def ^:private parts
    [["report" ["--out" "--samples" "--adapt"]] ["ablate" ["--out"]]
        ["residuals" ["--out"]] ["warmup" ["--out" "--seeds"]]
        ["tolerance" ["--out" "--samples" "--adapt" "--tols" "--seeds"]]
        ["chains" ["--out" "--samples" "--adapt" "--seeds" "--retry"]]])

(defn- integer-text? [s] (boolean (re-matches #"[-+]?\d+" s)))

(defn- check-option
    "Stops with a message if the value of option `k` is bad."
    [[k v]]
    (let [csv #(str/split v #"," -1)]
        (case k
            ("--samples" "--adapt")
            (when-not (and (integer-text? v) (>= (parse-long v) 1))
                (c/fail who (str k " needs a positive integer, got '" v "'")))
            "--seeds"
            (when-not (every? integer-text? (csv))
                (c/fail
                    who
                    (str "--seeds needs integers separated by commas, got '" v "'")))
            "--retry" (when-not (#{"0" "1"} v)
                (c/fail who (str "--retry needs 0 or 1, got '" v "'")))
            "--tols"
            (when-not (every? #(some-> (parse-double %)
                        pos?)
                    (csv))
                (c/fail who
                    (str
                        "--tols needs positive numbers separated by commas, got '"
                        v
                        "'")))
            nil)))

(defn- command
    "The command that runs `part` on `specs` with the options `opts` (pairs): diagnose.jl
    in the fitting-test project."
    [julia part opts specs]
    (concat [julia "--startup-file=no" (str "--project=" (c/in-root c/fit-dir))
            (c/in-root "test" "utils" "diagnose.jl") (str "--" part)]
        (mapcat identity opts)
        specs))

(defn- part-options
    "The options that go to `part`: those it accepts, in command-line order, and its
    own output file under `outdir` when one was asked for."
    [part opts outdir]
    (let [accepted (set (second (some #(when (= part (first %)) %) parts)))]
        (cond-> (filterv #(accepted (first %)) opts)
            outdir (conj ["--out" (str (fs/path outdir (str part ".txt")))]))))

(defn- run-part
    "Runs one part (or, with `dry`, prints its command); true if it succeeded."
    [julia part opts outdir specs dry]
    (let [cmd (command julia part (part-options part opts outdir) specs)]
        (println (str "\n=== diagnose: " part))
        (if dry (do (println (str/join " " cmd)) true) (c/run-cmd cmd))))

(defn run
    "The tool's main program for the argument list `argv`; returns the exit status."
    [argv]
    (if (or (empty? argv) (some #{"--help" "-h"} argv))
        (c/usage)
        (let [part-flags (map #(str "--" (first %)) parts)
                {:keys [opts flags specs]} (c/split-args
                    who
                    (distinct (mapcat second parts))
                    (concat part-flags ["--list" "--dry-run"])
                    argv)]
            (if (some #{"--list"} flags)
                (c/list-fits)
                (let [outdir (get (into {} opts) "--out")
                        ;; --out is per part, set by `part-options`
                        opts (remove #(= "--out" (first %)) opts)
                        specs (or (seq specs) (c/specs-of (c/ids)))
                        ;; the parts asked for, in the order given; none: all, in order
                        chosen (or (seq (keep #(when (some #{%} part-flags)
                                        (subs % 2))
                                    flags))
                            (map first parts))
                        dry (boolean (some #{"--dry-run"} flags))]
                    ;; the command line is checked before Julia is looked for or
                    ;; started
                    (run! check-option opts)
                    (c/check-specs who specs)
                    (let [julia (c/find-julia)]
                        (when (and outdir (not dry)) (fs/create-dirs outdir))
                        ;; every part runs even if one fails; the failures are named
                        (let [failed (doall
                                    (remove
                                        #(run-part julia % opts outdir specs dry)
                                        chosen))]
                            (when (seq failed)
                                (binding [*out* *err*]
                                    (println (str "\n" who
                                            ": failed: " (str/join ", "
                                                failed))))
                                1))))))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
    (c/main run *command-line-args*))
