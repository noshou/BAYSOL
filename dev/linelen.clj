#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The line-length rule of the code: every line at most 92 characters, no tab character.
;;
;;     bb linelen --check [PATH ...]
;;
;;   --check   lists every line over 92 characters (file:line: length) in the code
;;             files under PATH (files or directories, default the whole repository)
;;             and exits 1 if there is one; a tab character is an error too.
;;             Characters are counted, not bytes. The precommit step `line-length`
;;             runs this and refuses the commit. To fix what it finds, `bb fmt` wraps
;;             the code and re-wraps comments and docstrings (dev/reflow.clj); a long
;;             string or symbol is for a person.
;;
;; Checked: code only (.jl .clj .edn .scss .yml), not Markdown, data (json, tsv,
;; toml, txt) or generated CSS. Needs Babashka.

(ns linelen
    (:require [babashka.classpath :refer [add-classpath]]
        [babashka.fs :as fs]
        [clojure.string :as str]))

(add-classpath (str (fs/parent (fs/absolutize *file*))))

(require '[common :as c])

(def ^:private who "bb linelen")

(def ^:private limit c/line-limit)

(def ^:private len c/char-count)

(defn ^:private lines-of
    "The lines of the file `rel` (relative to the root), split on newlines only: a
    carriage return stays at the end of its line."
    [rel]
    (str/split (c/slurp8 (c/in-root rel)) #"\n" -1))

(defn ^:private long-lines
    "[file line-number length] of every line over the limit in `files`."
    [files]
    (for [f files
            [i line] (map-indexed vector (lines-of f))
            :let [n (len (str/replace line #"\r$" ""))]
            :when (> n limit)]
        [f (inc i) n]))

(defn ^:private tab-lines
    "[file line-number] of every line holding a tab character (indent with 4 spaces)."
    [files]
    (for [f files
            [i line] (map-indexed vector (lines-of f))
            :when (str/includes? line "\t")]
        [f (inc i)]))

(defn ^:private check
    "Lists the lines over the limit and the tabs; true when there are none."
    [paths]
    (let [files (mapcat c/code-files (or (seq paths) [c/*root*]))
            too-long (long-lines files)
            tabs (tab-lines files)]
        (doseq [[f i n] too-long] (println (str f ":" i ": " n " characters")))
        (doseq [[f i] tabs]
            (println (str f ":" i ": tab character (indent with 4 spaces)")))
        (binding [*out* *err*]
            (when (seq tabs)
                (println
                    (str who ": " (count tabs) " line(s) with a tab character")))
            (when (seq too-long)
                (println (str who
                        ": "
                        (count too-long)
                        " line(s) over "
                        limit
                        " characters in "
                        (count (distinct (map first too-long)))
                        " file(s)"))))
        (when (and (empty? too-long) (empty? tabs))
            (println (str "layout: "
                    (count files)
                    " code files, no line over "
                    limit
                    " characters, no tab character")))
        (and (empty? too-long) (empty? tabs))))

(defn run
    "The tool's main program for the argument list `argv`; returns the exit status."
    [argv]
    (if (or (empty? argv) (some #{"--help" "-h"} argv))
        (c/usage)
        (let [[cmd & more] argv]
            (if (= cmd "--check")
                (when-not (check more) 1)
                (c/fail who (str "unknown option " cmd " (only: --check)"))))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
    (c/main run *command-line-args*))
