#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Everything to check before committing, in one command:
;;
;;     bb precommit [--quick] [--dry-run]
;;
;; The steps, in order (all of them run even if
;; one fails; the exit status is 1 if any failed):
;;   tool-tests     the tests of the dev tools (`bb test`)
;;   unit-tests     the unit and integration suite
;;                  (`julia --project=test dev/unittests.jl`, ~5 min)
;;   concurrency-tests  the concurrency and race tests again with six Julia threads
;;                  and an interactive one (`julia -t 6,1 dev/unittests.jl
;;                  concurrency parallel gcpause cache`, ~20 s): the full
;;                  unit-tests step runs with the thread count given by `--threads`
;;                  (default one), where the parallel paths are not exercised by
;;                  real threads
;;   whitespace     trailing whitespace on the lines you changed is stripped
;;                  (`git diff --check HEAD` finds the lines of tracked files; every
;;                  line of an untracked, unignored text file is stripped) and
;;                  reported, never a failure; a leftover conflict marker cannot be
;;                  fixed by a tool and is a failure
;;   clj-format     every .clj file is formatted by zprint (`bb fmt-check --clj`)
;;   julia-format   every .jl file is formatted by JuliaFormatter.jl
;;                  (`bb fmt-check --julia`, settings in .JuliaFormatter.toml);
;;                  `bb fmt` fixes both
;;   clj-lint       clj-kondo finds no warning or error in the .clj files
;;                  (settings in .clj-kondo/config.edn)
;;   line-length    no line of code (.jl .clj .edn .scss .yml) is longer than 92
;;                  characters (`bb linelen --check`); a violation refuses the commit
;;   results-table  the Results table in test/fitting_tests/README.md equals the one
;;                  generated from the reports (`bb results-table --check`)
;;   docs-build     the strict documentation build (`julia --project=docs
;;                  docs/make.jl`, ~1 min); it also regenerates the (gitignored)
;;                  copies of the READMEs under docs/src/guides and docs/src/testing
;;
;;   --quick     skip the Julia steps (unit-tests, concurrency-tests, julia-format,
;;               docs-build): the checks that take a second
;;   --threads N  run the Julia processes with N threads (as `julia -t N`: 4, auto,
;;               4,1); default one
;;   --dry-run   print what would run, run nothing
;;
;; It never runs a fitting test or a benchmark (those need a quiet
;; machine and the owner's approval). Needs Babashka and `clj-kondo`; the Julia
;; steps need `julia` on the PATH (or JULIA=/path/to/julia).

(ns precommit
    (:require [babashka.classpath :refer [add-classpath]]
        [babashka.fs :as fs]
        [babashka.process :as p]
        [clojure.string :as str]))

(add-classpath (str (fs/parent (fs/absolutize *file*))))

(require '[common :as c])

(def ^:private who "bb precommit")

;; File types scanned for trailing whitespace in untracked files.
(def ^:private text-extensions #{"jl" "clj" "edn" "md" "tsv" "toml" "json" "yml"})

;; --- the whitespace step

(defn ^:private strip-lines
    "Strips the trailing blanks (spaces and tabs) from the lines of file `path` listed
    in `only` (a set of 1-based line numbers, or :all), leaving everything else, line
    endings included, untouched. Returns how many lines changed. A .tsv file is left
    alone: a trailing tab there is an empty last field, not whitespace."
    [path only]
    (if (= "tsv" (fs/extension path))
        0
        (let [lines (str/split (c/slurp8 path) #"\n" -1)
                stripped (map-indexed (fn [i line]
                        (if (or (= only :all)
                                (contains? only (inc i)))
                            (str/replace line #"[ \t]+(\r?)$" "$1")
                            line))
                    lines)
                n (count (filter true? (map not= lines stripped)))]
            (when (pos? n) (c/spit8 path (str/join "\n" stripped)))
            n)))

(defn ^:private git-check-output
    "The output of `git diff --check HEAD`: the lines of tracked files with trailing
    whitespace, and other problems such as leftover conflict markers. The command
    exits non-zero when it finds any, which is not an error here."
    []
    (let [git-proc (p/process {:out :stream, :err :inherit, :dir c/*root*}
                "git" "-c"
                "core.quotepath=false" "diff"
                "--check" "HEAD")]
        (slurp (:out git-proc) :encoding "UTF-8")))

(defn ^:private summary-lines
    "The report of what was stripped (at most 12 files) and of the problems (at most
    12), as printed lines."
    [stripped problems]
    (concat (when (seq stripped)
            (concat
                [(str "  stripped trailing whitespace from "
                        (reduce + (map second stripped))
                        " lines in "
                        (count stripped)
                        " files:")]
                (for [[f n] (take 12 stripped)] (str "    " f " (" n ")"))
                (when (> (count stripped) 12)
                    [(str "    ... and " (- (count stripped) 12) " more")])))
        (map #(str "  " %) (take 12 problems))
        (when (> (count problems) 12)
            [(str "  ... and " (- (count problems) 12) " more")])))

(defn whitespace
    "Strips trailing whitespace from the lines you changed (`git diff --check HEAD`
    names them in the tracked files; an untracked, unignored text file is stripped
    whole) and says what it did. Conflict markers are the one problem it cannot fix:
    they are listed (at most 12) and make it return false. Otherwise true."
    []
    (let [checked (str/split-lines (git-check-output))
            ;; tracked files: {file #{line numbers}}, plus the problems git names
            at (reduce (fn [m line]
                    (if-let [[_ f n] (re-matches
                                #"(\S.*?):(\d+): trailing whitespace\."
                                line)]
                        (update m f (fnil conj #{}) (parse-long n))
                        m))
                (array-map)
                checked)
            other (filter #(and (re-find #"^\S.*:\d+: " %)
                    (not (re-find #": trailing whitespace\.$" %)))
                checked)
            tracked (for [[f lines] at] [f (strip-lines (c/in-root f) lines)])
            untracked-files
            (->> (str/split-lines (c/git "-c"
                        "core.quotepath=false" "ls-files"
                        "-o" "--exclude-standard"))
                (filter #(and (seq %) (text-extensions (fs/extension %)))))
            untracked (for [f untracked-files] [f (strip-lines (c/in-root f) :all)])
            markers (for [f untracked-files
                    [i line] (map-indexed
                        vector
                        (str/split (c/slurp8 (c/in-root f)) #"\n" -1))
                    :when (re-find #"^(<<<<<<<|>>>>>>>) " line)]
                (str f ":" (inc i) ": conflict marker"))
            stripped (filter #(pos? (second %)) (concat tracked untracked))
            problems (concat other markers)]
        (run! println (summary-lines stripped problems))
        (empty? problems)))

;; --- the steps

(defn ^:private steps
    "The checks, in order: {:name :quick? :cmd}. `:cmd` is a command vector, whose
    first element :julia stands for the Julia executable, or :whitespace for the
    step done in this process."
    []
    [{:name "tool-tests", :quick? true, :cmd ["bb" (c/in-root "dev" "tests.clj")]}
        {:name "unit-tests",
            :cmd [:julia "--startup-file=no" (str "--project=" (c/in-root "test"))
                (c/in-root "dev" "unittests.jl")]}
        {:name "concurrency-tests",
            :cmd [:julia "--startup-file=no" "-t" "6,1"
                (str "--project=" (c/in-root "test")) (c/in-root "dev" "unittests.jl")
                "concurrency" "parallel" "gcpause" "cache"]}
        {:name "whitespace", :quick? true, :cmd :whitespace}
        {:name "clj-format",
            :quick? true,
            :cmd ["bb" (c/in-root "dev" "format.clj") "--check" "--clj"]}
        {:name "julia-format",
            :cmd ["bb" (c/in-root "dev" "format.clj") "--check" "--julia"]}
        {:name "clj-lint", :quick? true, :cmd ["clj-kondo" "--lint" (c/in-root "dev")]}
        {:name "line-length",
            :quick? true,
            :cmd ["bb" (c/in-root "dev" "linelen.clj") "--check"]}
        {:name "results-table",
            :quick? true,
            :cmd ["bb" (c/in-root "dev" "results_table.clj") "--check"]}
        {:name "docs-build",
            :cmd [:julia "--startup-file=no" (str "--project=" (c/in-root "docs"))
                (c/in-root "docs" "make.jl")]}])

(defn ^:private run-step
    "Runs one step; [state seconds] with state \"ok\" or \"FAILED\"."
    [{:keys [cmd]} julia]
    (let [t0 (System/currentTimeMillis)
            ok (if (= cmd :whitespace)
                (whitespace)
                (c/sh false (map #(if (= % :julia) julia %) cmd)))]
        [(if ok "ok" "FAILED") (/ (- (System/currentTimeMillis) t0) 1000.0)]))

(defn run
    "The tool's main program for the argument list `argv`; returns the exit status."
    [argv]
    (if (some #{"--help" "-h"} argv)
        (c/usage)
        (let [unknown (first (remove #{"--quick" "--dry-run"} argv))
                _ (when unknown
                    (c/fail who
                        (str "unknown option "
                            unknown
                            " (one of: --quick, --dry-run)")))
                quick (boolean (some #{"--quick"} argv))
                dry (boolean (some #{"--dry-run"} argv))
                julia (when-not (or dry quick) (c/find-julia))
                results
                (doall
                    (for
                        [{step-name :name, :keys [quick? cmd], :as step} (steps)
                            :let [skipped (and quick (not quick?))]
                            :when (or skipped (do (println (str "\n=== " step-name)) true))]
                        (cond skipped [step-name "skipped" 0]
                            dry (do (println (if (= cmd :whitespace)
                                        (str "(strip trailing whitespace "
                                            "from the changed lines; "
                                            "fail on conflict markers)")
                                        (str "$ "
                                            (str/join " "
                                                (map #(if (= % :julia)
                                                        "JULIA"
                                                        %)
                                                    cmd)))))
                                nil)
                            :else (into [step-name] (run-step step julia)))))]
            (when-not dry
                (println "\n=== summary")
                (doseq [[step-name state secs] results]
                    (println (format "  %-14s %-8s %s"
                            step-name
                            state
                            (if (= state "skipped")
                                ""
                                (str (c/fmt "%.1f" secs) " s")))))
                (let [failed (some #(= "FAILED" (second %)) results)]
                    (println
                        (cond
                            failed "NOT ready to commit"
                            quick
                            (str
                                "quick checks passed (the unit suite and the docs build "
                                "were skipped)")
                            :else "ready to commit"))
                    (when failed 1))))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
    (c/main run *command-line-args*))
