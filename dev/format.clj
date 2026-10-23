#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Formats the code: Julia with JuliaFormatter.jl (settings: .JuliaFormatter.toml at the
;; repository root), Babashka (.clj and .edn, e.g. bb.edn) with zprint (lines wrapped at
;; 92 characters; the options are `zprint-options` below) followed by `reindent`, which
;; sets the indentation: a continuation line is indented 4 more than the line that opened
;; its bracket, plus 4 for each further bracket still open from that same line, so every
;; indentation is a multiple of 4 and inherits from its parent line (zprint alone aligns
;; arguments under the first one, which depends on where the bracket sits). A string or a
;; symbol longer than the limit cannot be wrapped: `bb linelen --check` finds those.
;; After the formatters, the prose of both languages is re-wrapped (dev/reflow.clj): the
;; comment blocks and docstring paragraphs that contain a line over the limit, balanced.
;;
;;     bb fmt [--julia|--clj] [PATH ...]
;;     bb fmt-check [--julia|--clj] [PATH ...]
;;
;;   bb fmt        rewrites the Julia and Babashka files under PATH (default: the whole
;;                 repository), then re-wraps their long comments and docstrings
;;   bb fmt-check  changes nothing; lists the files that are not formatted or whose
;;                 prose would be re-wrapped, and exits 1 if there are any
;;   --julia, --clj   only that language (the precommit runs the two checks as
;;                 separate steps)
;;
;; JuliaFormatter lives in its own environment, test/format (first use:
;; `julia --project=test/format -e 'using Pkg; Pkg.instantiate()'`). zprint is fetched
;; from Clojars on first use (the version is pinned below) and needs `java` on the PATH,
;; as Babashka's dependency resolution does. Needs `julia` on the PATH (or
;; JULIA=/path/to/julia) for the Julia part.

(ns format
    (:require [babashka.classpath :refer [add-classpath]]
        [babashka.deps :as deps]
        [babashka.fs :as fs]
        [clojure.string :as str]))

(add-classpath (str (fs/parent (fs/absolutize *file*))))

(require '[common :as c] '[reflow])

(def ^:private who "bb fmt")

;; zprint's options: the `:community` style (the usual Clojure layout), a form's body
;; indented by 4 (`:list :indent`; zprint's default is 2), lines wrapped at 92 characters.
(def ^:private zprint-options
    {:style :community, :width 84, :list {:indent 4}, :comment {:wrap? false}})

(def ^:private zprint-version "1.3.0")

(defn- zprint-file-str
    "zprint's whole-file formatter. The library is loaded on first use, so a Julia-only
    run never waits for it. Once downloaded (into the local Maven repository) its jar goes
    straight on the classpath, which takes a fraction of a second; resolving it through
    `babashka.deps` starts a JVM and takes seconds, so that is only done to fetch it."
    []
    (let [jar (fs/path (fs/home)
                ".m2"
                "repository"
                "zprint"
                "zprint"
                zprint-version
                (str "zprint-" zprint-version ".jar"))]
        (if (fs/exists? jar)
            (add-classpath (str jar))
            (deps/add-deps {:deps {'zprint/zprint {:mvn/version zprint-version}}})))
    (requiring-resolve 'zprint.core/zprint-file-str))

(defn reindent
    "`text` with every continuation line re-indented: 4 more than the line that opened
    the innermost open bracket, plus 4 for each further bracket that is still open and
    was opened on that same line (so `(foo (bar a` continues `bar`'s arguments at 8 and
    `foo`'s at 4). Line breaks, strings (multi-line ones included), comments and the
    text of each line are kept. A comment-only line takes the indentation of the next
    line of code; a line that starts inside a string is left as it is. Reading the
    code understands strings, regex literals, character literals and `;` comments, so
    brackets inside them do not count."
    [text]
    (let [lines (vec (str/split text #"\n" -1))
            closer? (set ")]}")
            opener? (set "([{")
            ;; the brackets on the rest of `line` (from `from`), given whether we start in
            ;; a string: [in-string? stack], an entry being {:line id :indent n}
            scan (fn [line from in-str stack id indent]
                (loop [i from
                        in-str in-str
                        stack stack]
                    (if (>= i (count line))
                        [in-str stack]
                        (let [ch (.charAt ^String line i)]
                            (cond in-str
                                (cond (= ch \\) (recur (+ i 2) true stack)
                                    (= ch \") (recur (inc i) false stack)
                                    :else (recur (inc i) true stack))
                                (= ch \\) (recur (+ i 2) false stack)
                                (= ch \") (recur (inc i) true stack)
                                (= ch \;) [false stack]
                                (opener? ch)
                                (recur (inc i)
                                    false
                                    (conj stack {:line id, :indent indent}))
                                (closer? ch)
                                (recur (inc i)
                                    false
                                    (if (seq stack) (pop stack) stack))
                                :else (recur (inc i) false stack))))))
            ;; first pass: the lines of code get their indentation; comment-only lines are
            ;; marked, and given the indentation of the code line after them in the second
            [out kinds _ _]
            (reduce
                (fn [[out kinds in-str stack] [id line]]
                    (let [trimmed (str/triml line)]
                        (cond in-str
                            (let [[in-str' stack'] (scan line 0 true stack id 0)]
                                [(conj out line) (conj kinds nil) in-str' stack'])
                            (str/blank? line) [(conj out "") (conj kinds nil) false
                                stack]
                            (or (str/starts-with? trimmed ";")
                                (and (zero? id) (str/starts-with? trimmed "#!")))
                            [(conj out trimmed) (conj kinds :comment) false stack]
                            :else (let [top (peek stack)
                                    k (count (take-while #(= (:line %) (:line top))
                                            (rseq stack)))
                                    indent (cond (nil? top) 0
                                        (closer? (.charAt ^String trimmed
                                                0))
                                        (+ (:indent top) (* 4 (dec k)))
                                        :else (+ (:indent top) (* 4 k)))
                                    new-line (str (apply str (repeat indent " "))
                                        trimmed)
                                    [in-str' stack']
                                    (scan new-line indent false stack id indent)]
                                [(conj out new-line) (conj kinds indent) in-str'
                                    stack']))))
                [[] [] false []]
                (map-indexed vector lines))
            ;; second pass, from the end: a comment-only line takes the indentation of the
            ;; next line of code
            result
            (loop [i (dec (count out))
                    next-indent 0
                    acc ()]
                (if (neg? i)
                    acc
                    (let [kind (kinds i)
                            line (out i)]
                        (cond (= kind :comment)
                            (recur (dec i)
                                next-indent
                                (cons (str (apply str (repeat next-indent " "))
                                        line)
                                    acc))
                            (number? kind) (recur (dec i) kind (cons line acc))
                            :else (recur (dec i) next-indent (cons line acc))))))]
        (str/join "\n" result)))

(defn format-text
    "`text` of a .clj file as zprint (`zprint-fn`, from `zprint-file-str`) and `reindent`
    leave it."
    [zprint-fn text path]
    (reindent (zprint-fn text path zprint-options)))

(defn- formatted-key
    "The name of the cache entry for a text that zprint leaves unchanged: a hash of the
    text, the options and the zprint version, so any of them changing invalidates it."
    [text]
    (let [digest (java.security.MessageDigest/getInstance "SHA-1")
            bytes* (.digest digest
                (.getBytes
                    (pr-str zprint-version zprint-options :reindent-1 text)
                    "UTF-8"))]
        (apply str (map #(format "%02x" (bit-and % 0xff)) bytes*))))

(defn- format-clj
    "Formats (`apply?`) or checks the .clj files under `paths`; true on success: when
    formatting always, when checking if none would change. Lists the files that were (or
    would be) changed. zprint is slow under
    Babashka (about half a second a file), so a text it has once left unchanged is
    remembered in `_cache/format-clj/` and skipped the next time."
    [apply? paths]
    (let [files (->> paths
                (mapcat c/code-files)
                (filter #(re-find #"\.(clj|edn)$" %))
                distinct)
            cache (c/in-root "_cache" "format-clj")
            known? #(fs/exists? (fs/path cache (formatted-key %)))
            remember! (fn [text]
                (fs/create-dirs cache)
                (spit (str (fs/path cache (formatted-key text))) ""))
            format* (delay (zprint-file-str))
            changed (for [f files
                    :let [path (c/in-root f)
                        old (c/slurp8 path)]
                    :when (not (known? old))
                    :let [fresh (format-text @format* old path)]
                    :when (if (= old fresh) (do (remember! old) false) true)]
                (do (when apply? (c/spit8 path fresh) (remember! fresh)) f))]
        (doseq [f changed] (println (if apply? "formatted" "not formatted:") f))
        (or apply? (empty? changed))))

(defn- format-julia
    "Formats (`apply?`) or checks the Julia files under `paths` with JuliaFormatter, in
    its own environment; true on success."
    [apply? paths]
    (c/run-cmd [(c/find-julia) "--startup-file=no"
            (str "--project=" (c/in-root "test" "format"))
            (c/in-root "dev" "format.jl") (if apply? "--apply" "--check")
            paths]))

(defn- reflow-prose
    "Re-wraps (`apply?`) or checks the prose of the `language` files under `paths`;
    true on success."
    [apply? language paths]
    (let [changed (reflow/reflow-files apply? language paths)]
        (doseq [f changed] (println (if apply? "re-wrapped" "prose to re-wrap:") f))
        (or apply? (empty? changed))))

(defn run
    "The tool's main program for the argument list `argv`; returns the exit status."
    [argv]
    (if (or (empty? argv) (some #{"--help" "-h"} argv))
        (c/usage)
        (let [[mode & rest-args] argv
                _ (when-not (#{"--apply" "--check"} mode)
                    (c/fail
                        who
                        (str "unknown option " mode " (one of: --apply, --check)")))
                ;; a typo such as `bb fmt --check` (the task passes --apply) must not reach
                ;; the formatters as a path
                _ (when-let [bad (first (filter #(and (str/starts-with? % "--")
                                    (not (#{"--julia" "--clj"} %)))
                                rest-args))]
                    (c/fail who
                        (str "unknown option " bad
                            " (use `bb fmt-check` to only check, "
                            "`bb fmt` to rewrite; options: --julia, --clj)")))
                apply? (= mode "--apply")
                languages (set (filter #{"--julia" "--clj"} rest-args))
                ;; no language flag: both
                both? (empty? languages)
                paths (or (seq (remove #{"--julia" "--clj"} rest-args)) [c/*root*])
                ;; each language is run even if the other failed
                ;; the formatter first, then the prose; both run even if one fails
                both-ok (fn [language format-fn]
                    (let [formatted (format-fn apply? paths)
                            prose (reflow-prose apply? language paths)]
                        (and formatted prose)))
                julia-ok (or (not (or both? (languages "--julia")))
                    (both-ok :julia format-julia))
                clj-ok (or (not (or both? (languages "--clj")))
                    (both-ok :clj format-clj))]
            (when-not (and julia-ok clj-ok) 1))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
    (c/main run *command-line-args*))
