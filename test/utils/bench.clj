#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Cold / steady-state benchmark driver.
;;
;;     bb bench --approved [--state cold|warm] [--keep] \
;;         [--out FILE.json] [--samples N] [--adapt N] ID[:tag] ...
;;
;; `--approved` is required; without it the script prints the plan and stops. Why:
;; timings are only meaningful on a quiet machine (nothing else running, no desktop
;; indexers or browsers burning CPU), and AI agents tend to start a benchmark without
;; checking that. So `--approved` is passed only after the repository owner has approved
;; this particular run, which means they have confirmed the machine is quiet. It is a
;; small safeguard, not a security boundary. See the Benchmarks section of README.md for
;; the protocol. The measured process itself stays Julia (child.jl, next to this script):
;; it is the code being timed. This script only prepares the state, starts that process
;; once per fit and collects the JSON it prints; `bb compare --bench` reads the result.
;;
;; --state cold (default): measures from a wiped state. A throwaway depot is built
;;     from symlinks to the *source* parts of the real one (packages, artifacts,
;;     registries, clones, conda_environments: what a user has after installing)
;;     WITHOUT its compiled caches, and the repository is copied from `git ls-files`
;;     (tracked plus untracked-unignored files, no `_cache/`, no result files).
;;     Package precompilation is timed, then each fit runs in a fresh process.
;;     Nothing in the real depot or repository is modified or deleted.
;; --state warm: the real depot and repo, for comparison with a cold run (never
;;     quote it as a user-facing number).
;; --keep: the cold state's temporary directory is deleted when the run ends
;;     (links are unlinked, never followed: your depot is not touched); with
;;     --keep it is left in place and its path printed.
;;
;; Results go to test/baselines/results/ (not tracked) unless --out is given. A baseline
;; for a release is a result saved as test/baselines/<release tag>-<state>-<host>.json when
;; that release is made (see test/baselines/README.md); `bb compare --bench NEW.json`
;; compares against the newest baseline of the latest release.
;;
;; Needs Babashka, and `julia` on the PATH (or JULIA=/path/to/julia). Shared helpers
;; are in common.clj.

(ns bench
    (:require [babashka.classpath :refer [add-classpath]]
        [babashka.fs :as fs]
        [babashka.process :as p]
        [cheshire.core :as json]
        [clojure.string :as str])
    (:import (java.time LocalDateTime)
        (java.time.format DateTimeFormatter)))

(add-classpath (str (fs/parent (fs/absolutize *file*))))

(require '[common :as c])

;; Directories of a Julia depot that a user has after installing (sources, not
;; compiled caches).
(def ^:private depot-source-dirs
    ["packages" "artifacts" "registries" "clones" "conda_environments"
        "environments"])

(defn parse-args
    "The `--key value` options (and the value-less --keep) and the positional specs of
    the command line: {:opts {\"state\" \"cold\" ...} :specs [...]}."
    [argv]
    (let [{:keys [opts flags specs]} (c/split-args "bb bench"
                ["--state" "--out" "--samples"
                    "--adapt"]
                ["--keep"]
                argv)]
        {:opts (into (into {} (map (fn [[k v]] [(subs k 2) v])) opts)
                (map (fn [f] [(subs f 2) 1]) flags)),
            :specs specs}))

(defn excluded?
    "Is the repository file `f` (a path relative to the root) left out of the cold
    state's repository copy? Docs, the visual-check snapshots, the fitting tests' result
    files and untracked benchmark results are: none of them is needed to build a Seed and
    fit it."
    [f]
    (boolean (or (str/starts-with? f "docs/")
            (str/starts-with? f "test/visualize/xyz/")
            (str/starts-with? f "test/baselines/results/")
            (re-find #"^test/fitting_tests/.*/res[^/]*\.(txt|png)$" f))))

(defn- copy-repo
    "Copies the repository's tracked and untracked-but-not-ignored files (minus the
    excluded ones) to `dest`. Returns the number of files copied."
    [dest]
    (count
        (for [f (str/split-lines (c/git "-c"
                        "core.quotepath=false" "ls-files"
                        "-co" "--exclude-standard"))
                :when (and (seq f) (not (excluded? f)) (fs/regular-file? (c/in-root f)))]
            (do (fs/create-dirs (fs/parent (fs/path dest f)))
                (fs/copy (c/in-root f) (fs/path dest f) {:replace-existing true})))))

(defn make-depot
    "Builds a depot at `dest` from symlinks to the source parts of the real depot
    `real`. Deliberately absent: compiled/ (precompile caches), scratchspaces/, logs/."
    [dest real]
    (fs/create-dirs dest)
    (doseq [d depot-source-dirs
            :when (fs/directory? (fs/path real d))]
        (fs/create-sym-link (fs/path dest d) (fs/path real d))))

(defn- julia-facts
    "Julia's version, CPU name, hardware threads and first depot, from one short call."
    [julia]
    (let [out (:out @(p/process
                    {:out :string, :err :inherit}
                    julia
                    "--startup-file=no"
                    "-e"
                    (str "print(join((VERSION, Sys.CPU_NAME, Sys.CPU_THREADS, "
                        "first(DEPOT_PATH)), \"\\n\"))")))
            [version cpu cores depot] (str/split-lines out)]
        {:version version, :cpu cpu, :cores cores, :depot depot}))

(defn- hostname [] (str/trim (:out @(p/process {:out :string} "hostname"))))

(defn json-line
    "The JSON object a child process printed: the last line that is a whole object
    (opens and closes with a curly brace), or nil. The child's stdout can carry other
    text before it (CondaPkg's \"Transaction ... All requested packages already
    installed\" when PROPKA first runs)."
    [out]
    (->> (str/split-lines out)
        (map str/trim)
        (filter #(and (str/starts-with? % "{") (str/ends-with? % "}")))
        last))

(defn- timed
    "Runs a command and returns [wall-seconds stdout]. The command's stderr goes to
    ours, and the variables of the map `env` are set for its duration only."
    [env cmd]
    (let [t0 (System/nanoTime)
            result @(apply
                p/process
                {:out :string, :err :inherit, :continue true, :extra-env env}
                (map str cmd))
            seconds (/ (- (System/nanoTime) t0) 1e9)]
        (when-not (zero? (:exit result))
            (throw (ex-info (str "command failed: " (str/join " " (take 4 cmd))
                        " ...\n" (:out result))
                    {})))
        [seconds (:out result)]))

;; --- the result file
;;
;; Written by hand, not by a JSON library: the keys keep their order, and the child's
;; own JSON text is kept as it printed (no digit is rewritten).

(defn- jstr [s] (json/generate-string (str s)))

(defn- pretty-object
    "A JSON object from [key already-encoded-value] pairs, one key per line at
    `indent` spaces, the colons aligned."
    [pairs indent]
    (let [pad (apply max (map (comp count first) pairs))
            ind (apply str (repeat indent " "))]
        (str "{\n"
            (str/join ",\n"
                (for [[k v] pairs]
                    (str ind
                        "    "
                        (jstr k)
                        (apply str (repeat (- pad (count k)) " "))
                        " : "
                        v)))
            "\n"
            ind
            "}")))

(defn- meta-object
    [facts state repo]
    (let [rev (str (str/trim (c/git "rev-parse" "--short" "HEAD"))
                (when (seq (str/trim (c/git "status" "--porcelain"))) "+dirty"))
            note
            (if (= state "cold")
                (str "compiled caches, _cache/ and result files wiped; conda env and "
                    "package sources kept (provisioning is not measured)")
                "real depot and repo; caches warm")]
        (pretty-object [["date"
                    (jstr (.format (LocalDateTime/now)
                            (DateTimeFormatter/ofPattern
                                "yyyy-MM-dd'T'HH:mm:ss")))]
                ["host" (jstr (hostname))] ["julia" (jstr (:version facts))]
                ["cpu" (jstr (:cpu facts))] ["cores" (:cores facts)]
                ["state" (jstr state)] ["git_rev" (jstr rev)]
                ["repo" (jstr repo)] ["note" (jstr note)]]
            4)))

;; --- the run

(defn- plan
    "What an unapproved run prints instead of running."
    [argv]
    (str/join
        "\n"
        [(str "benchmarks: not running. A benchmark needs a QUIET machine, and an "
                "unattended agent cannot tell whether it is")
            (str "quiet, so each run needs the repository owner's explicit approval "
                "(they confirm nothing else is running).")
            (str "Planned: " (str/join " " argv))
            (str "It uses one core for minutes (cold: a full precompile of every "
                "dependency first), builds a throwaway depot")
            (str "and repo copy under the temp directory, and leaves your real depot "
                "and repository untouched.")
            "Re-run with --approved once the run has been approved."]))

(defn- install!
    "Instantiates and precompiles the project at `repo` (timed): [json-text-of-install
    env]. The cold state builds its own repo copy and depot first."
    [julia state facts tmp]
    (if (= state "cold")
        (let [repo (str (fs/path tmp "repo"))
                depot (str (fs/path tmp "depot"))
                env {"JULIA_DEPOT_PATH" depot}]
            (println (str "cold state in " tmp))
            (println (str "  copied " (copy-repo repo) " files"))
            (make-depot depot (:depot facts))
            (let [[t-pre txt] (timed env
                        [julia (str "--project=" repo) "-e"
                            (str "using Pkg\nPkg.instantiate()\n"
                                "t = @elapsed Pkg.precompile()\n"
                                "println(\"PRECOMPILE_S=\", t)")])
                    pre (second (re-find #"PRECOMPILE_S=([0-9.eE+-]+)" txt))]
                (when-not pre
                    (throw (ex-info "no PRECOMPILE_S in the precompile output" {})))
                (println
                    (format
                        "  instantiate + precompile: %.1f s (precompile alone %.1f s)"
                        t-pre
                        (parse-double pre)))
                {:repo repo,
                    :env env,
                    :install (pretty-object [["instantiate_and_precompile_s" t-pre]
                            ["precompile_s" pre]]
                        4)}))
        (let [[t-pre _] (timed {}
                    [julia (str "--project=" c/*root*) "-e"
                        "using Pkg\nPkg.precompile()"])]
            {:repo c/*root*,
                :env {},
                :install (pretty-object [["instantiate_and_precompile_s" t-pre]
                        ["precompile_s" t-pre]]
                    4)})))

(defn- fit!
    "One fresh process for the fit `spec`: the child's JSON with the process wall time
    added, as text."
    [julia {:keys [repo env]} spec iterations]
    (let [[t-proc out]
            (timed env
                (concat [julia (str "--project=" repo)
                        (str (fs/path repo "test" "utils" "child.jl")) repo spec]
                    iterations))
            raw (json-line out)]
        (when (or (nil? raw) (= raw "{}"))
            (throw (ex-info
                    (str "child.jl printed something other than a non-empty JSON "
                        "object for " spec
                        ":\n" raw)
                    {})))
        (let [r (json/parse-string raw true)]
            (println (format
                    (str
                        "  %-22s process %6.1f s | using BAYSOL %5.1f s | first fit "
                        "%6.1f s (seed %5.1f + run %5.1f) | steady fit %6.1f s")
                    spec
                    t-proc
                    (:using_baysol_s r)
                    (get-in r [:first :total_s])
                    (get-in r [:first :seed_s])
                    (get-in r [:first :run_s])
                    (get-in r [:second :total_s])))
            ;; the parent measured the process wall time; add it to the child's object
            (str (subs raw 0 (dec (count raw)))
                ",\"process_wall_s\":"
                t-proc
                "}"))))

(defn run
    "The tool's main program for the argument list `argv`; returns the exit status."
    [argv]
    (cond (some #{"--help" "-h"} argv) (c/usage)
        ;; the safeguard: no approval, no benchmark
        (not (some #{"--approved"} argv)) (println (plan argv))
        :else
        (let [{:keys [opts specs]} (parse-args (remove #{"--approved"} argv))
                state (get opts "state" "cold")
                _ (when (empty? specs)
                    (throw
                        (ex-info
                            (str
                                "usage: bb bench --approved [--state cold|warm] "
                                "[--out FILE.json] [--samples N --adapt N] ID[:tag] ...")
                            {})))
                _ (when-not (#{"cold" "warm"} state)
                    (throw (ex-info "--state must be cold or warm" {})))
                ;; NUTS iterations: only when given; otherwise the child uses the
                ;; run_model defaults of the code it measures
                _ (when (not= (contains? opts "samples") (contains? opts "adapt"))
                    (throw (ex-info
                            "give --samples and --adapt together, or neither"
                            {})))
                iterations (when (contains? opts "samples")
                    [(opts "samples") (opts "adapt")])
                out (or (opts "out")
                    (c/in-root "test" "baselines"
                        "results" (str (.format
                                (LocalDateTime/now)
                                (DateTimeFormatter/ofPattern
                                    "yyyyMMdd-HHmm"))
                            "-"
                            state
                            "-"
                            (hostname)
                            ".json")))
                julia (c/find-julia)
                facts (julia-facts julia)
                tmp (when (= state "cold")
                    (str (fs/create-temp-dir {:prefix "baysol-bench-"})))]
            (fs/create-dirs (fs/parent (fs/absolutize out)))
            (try (let [{:keys [repo install], :as st}
                        (install! julia state facts tmp)
                        fits (for [spec specs]
                            [spec (fit! julia st spec iterations)])]
                    (c/spit8 out
                        (str (pretty-object
                                [["meta" (meta-object facts state repo)]
                                    ["install" install]
                                    ["fit" (pretty-object (vec fits) 4)]]
                                0)
                            "\n"))
                    (println (str "wrote " out)))
                (finally (when tmp
                        (if (opts "keep")
                            (println
                                (str
                                    "kept the cold state in " tmp
                                    " (remove it with "
                                    "rm -r; the links inside are not followed)"))
                            (do (c/rm-tree tmp)
                                (println (str "removed " tmp))))))))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
    (c/main run *command-line-args*))
