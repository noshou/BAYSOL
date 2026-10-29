#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Formats the code: Julia with JuliaFormatter.jl (settings: .JuliaFormatter.toml at the
;; repository root), Babashka (.clj and .edn, e.g. bb.edn) with zprint (lines wrapped at
;; 92 characters; the options are `zprint-options` below) followed by `reindent`, which
;; sets the indentation: a continuation line is indented 1 more than the line that opened
;; its bracket, plus 1 for each further bracket still open from that same line, so every
;; indentation inherits from its parent line (zprint alone aligns arguments under the
;; first one, which depends on where the bracket sits). A string or a
;; symbol longer than the limit cannot be wrapped: `bb linelen --check` finds those.
;; SCSS is indented by `reindent-scss` (4 spaces a level). After the
;; formatters, the prose of all three languages is re-wrapped (dev/reflow.clj): the
;; comment blocks and docstring paragraphs that contain a line over the limit, balanced.
;;
;; Before both, every code file gets its license header (`with-header`): the line
;; `SPDX-License-Identifier: LGPL-3.0-or-later` as the first line (the second after a
;; shebang), in the file's comment syntax, followed by a blank line.
;;
;;     bb fmt [--julia|--clj|--scss] [PATH ...]
;;     bb fmt-check [--julia|--clj|--scss] [PATH ...]
;;
;;   bb fmt        rewrites the Julia, Babashka (.clj, .edn) and SCSS files under PATH
;;                 (default: the whole repository, `tui/` included, no flag needed),
;;                 then re-wraps their long comments and docstrings; adds or repairs
;;                 the license header of every code file; and finally lints the .clj
;;                 files with clj-kondo, so it exits 1 on any warning or error
;;                 (line breaks and blank lines are kept, except the blank lines
;;                 before the end of a file)
;;                 Both commands also check the release name `v<version>-<release_name>`
;;                 of the root Project.toml: at most 22 characters, the room the TUI's
;;                 main menu has for it
;;   bb fmt-check  changes nothing; lists the files that are not formatted, whose
;;                 prose would be re-wrapped or whose license header is missing or
;;                 wrong, and exits 1 if there are any
;;   --julia, --clj, --scss   only that language (the precommit runs the first two
;;                 checks as separate steps)
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
  [clojure.set :as set]
  [clojure.string :as str]))

(add-classpath (str (fs/parent (fs/absolutize *file*))))

(require '[common :as c] '[reflow])

(def ^:private who "bb fmt")

;; The indentation unit: a form's body, and each level of nesting, is indented by this
;; many spaces (zprint's own default is 2).
(def ^:private indent-unit 1)

;; zprint's options: the `:community` style (the usual Clojure layout), a form's body
;; indented by `indent-unit` (`:list :indent`), lines wrapped at 92 characters. The
;; styles `:respect-nl` and `:respect-bl` keep the author's line breaks and blank lines
;; (zprint would otherwise join the lines of a form that fit on one and delete every
;; blank line inside a form); only the blank lines before the end of a file go
;; (`trim-eof`).
(def ^:private zprint-options
 {:style [:community :respect-nl :respect-bl],
  :width 84,
  :list {:indent indent-unit},
  :comment {:wrap? false}})

(defn options-for
 "zprint's options for the file at `path` (the same for .clj and .edn files)."
 [_path]
 zprint-options)

(def ^:private zprint-version "1.3.0")

(defn ^:private zprint-file-str
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
 "`text` with every continuation line re-indented: `indent-unit` (1) more than the line
 that opened the innermost open bracket, plus 1 for each further bracket that is still
 open and was opened on that same line (so `(foo (bar a` continues `bar`'s arguments
 at 2 and `foo`'s at 1). Line breaks, strings (multi-line ones included), comments and the
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
       (cond in-str (cond (= ch \\) (recur (+ i 2) true stack)
         (= ch \") (recur (inc i) false stack)
         :else (recur (inc i) true stack))
        (= ch \\) (recur (+ i 2) false stack)
        (= ch \") (recur (inc i) true stack)
        (= ch \;) [false stack]
        (opener? ch)
        (recur (inc i) false (conj stack {:line id, :indent indent}))
        (closer? ch)
        (recur (inc i) false (if (seq stack) (pop stack) stack))
        :else (recur (inc i) false stack))))))
   ;; first pass: the lines of code get their indentation; comment-only lines are
   ;; marked, and given the indentation of the code line after them in the second
   [out kinds _ _]
   (reduce
    (fn [[out kinds in-str stack] [id line]]
     (let [trimmed (str/triml line)]
      (cond in-str (let [[in-str' stack'] (scan line 0 true stack id 0)]
        [(conj out line) (conj kinds nil) in-str' stack'])
       (str/blank? line) [(conj out "") (conj kinds nil) false stack]
       (or (str/starts-with? trimmed ";")
        (and (zero? id) (str/starts-with? trimmed "#!")))
       [(conj out trimmed) (conj kinds :comment) false stack]
       :else
       (let [top (peek stack)
         k (count (take-while #(= (:line %) (:line top)) (rseq stack)))
         indent (cond (nil? top) 0
          (closer? (.charAt ^String trimmed 0))
          (+ (:indent top) (* indent-unit (dec k)))
          :else (+ (:indent top) (* indent-unit k)))
         new-line (str (apply str (repeat indent " ")) trimmed)
         [in-str' stack'] (scan new-line indent false stack id indent)]
        [(conj out new-line) (conj kinds indent) in-str' stack']))))
    [[] [] false []]
    (map-indexed vector lines))
   ;; second pass, from the end: a comment-only line takes the indentation of the
   ;; next line of code
   result (loop [i (dec (count out))
     next-indent 0
     acc ()]
    (if (neg? i)
     acc
     (let [kind (kinds i)
       line (out i)]
      (cond (= kind :comment)
       (recur (dec i)
        next-indent
        (cons (str (apply str (repeat next-indent " ")) line)
         acc))
       (number? kind) (recur (dec i) kind (cons line acc))
       :else (recur (dec i) next-indent (cons line acc))))))]
  (str/join "\n" result)))

(defn private-defns
 "`text` with every top-level `(defn- name` written as `(defn ^:private name`, the way
 a private `def` is written. Only a form that starts a line at column 0 is touched, so
 prose and docstrings that mention `defn-` indented stay as they are. Done before zprint,
 which then wraps the longer line, so formatting twice changes nothing."
 [text]
 (str/replace text #"(?m)^\(defn- " "(defn ^:private "))

(defn trim-eof
 "`text` without the blank lines before the end of the file: it ends with exactly one
 newline (a text of nothing but white space becomes empty). Blank lines anywhere else
 are the author's and stay."
 [text]
 (let [body (str/replace text #"\s+\z" "")]
  (if (empty? body) "" (str body "\n"))))

(defn format-text
 "`text` of a .clj file as zprint (`zprint-fn`, from `zprint-file-str`) and `reindent`
 leave it, without blank lines before the end of the file."
 [zprint-fn text path]
 (trim-eof (reindent (zprint-fn (private-defns text) path (options-for path)))))

(def license-id "LGPL-3.0-or-later")

(def ^:private comment-prefixes
 "The line-comment syntax of each code extension (see `common/code-extensions`)."
 {".jl" "#", ".clj" ";;", ".edn" ";;", ".scss" "//"})

(def ^:private language-extensions
 "The extensions each language flag of the tool covers."
 {:julia #{".jl"}, :clj #{".clj" ".edn"}, :scss #{".scss"}})

(defn with-header
 "`text` of a file with extension `ext` (with its dot) with the license header in
 place: `<comment> SPDX-License-Identifier: <license-id>` as the first line, or as the
 second when the first is a shebang, and a blank line after it. A different
 SPDX-License-Identifier line in that place is replaced, a missing one is inserted
 (text without a shebang gets it first), and a missing blank line is added; nothing else
 is touched, so applying it twice changes nothing. An extension without a known
 comment syntax leaves the text as it is."
 [text ext]
 (if-let [prefix (comment-prefixes ext)]
  (let [header (str prefix " SPDX-License-Identifier: " license-id)
    lines (str/split text #"\n" -1)
    shebang? (str/starts-with? (first lines) "#!")
    [top rest-lines]
    (if shebang? [(subvec lines 0 1) (subvec lines 1)] [[] lines])
    spdx? #(re-find #"^\s*(#|;+|//)\s*SPDX-License-Identifier:" (or % ""))
    ;; the lines after the header: a stale one is dropped
    body (if (spdx? (first rest-lines)) (rest rest-lines) rest-lines)
    ;; an empty file is the one empty line `split` gives: no body at all
    body (if (= body [""]) [] body)
    ;; the blank line after the header, unless the body starts with one or is empty
    spacer (if (or (empty? body) (str/blank? (first body))) [] [""])]
   (str/join "\n" (concat top [header] spacer body (when (empty? body) [""]))))
  text))

(defn header-ext
 "The extension of `path` with its dot, \"\" if it has none."
 [path]
 (if-let [e (fs/extension path)]
  (str "." e)
  ""))

(defn ^:private header-files
 "Adds (`apply?`) or checks the license header of `files` (paths relative to the root)
 whose extension is in `exts`; returns the files that were (or would be) changed."
 [apply? files exts]
 (vec (for [f files
    :when (exts (header-ext f))
    :let [old (c/slurp8 (c/in-root f))
     fresh (with-header old (header-ext f))]
    :when (not= old fresh)]
   (do (when apply? (c/spit8 (c/in-root f) fresh)) f))))

(defn ^:private format-headers
 "Adds (`apply?`) or checks the license headers of the code files under `paths` of the
 `languages` (a set of `language-extensions` keys); true on success."
 [apply? languages paths]
 (let [exts (apply set/union (map language-extensions languages))
   changed (header-files apply? (distinct (mapcat c/code-files paths)) exts)]
  (doseq [f changed]
   (println (if apply? "license header added:" "license header missing:") f))
  (or apply? (empty? changed))))

(defn ^:private formatted-key
 "The name of the cache entry for a text that zprint leaves unchanged: a hash of the
 text, the options and the zprint version, so any of them changing invalidates it."
 [text]
 (let [digest (java.security.MessageDigest/getInstance "SHA-1")
   bytes* (.digest digest
    (.getBytes (pr-str zprint-version
      zprint-options
      :reindent-1
      :private-defn
      :trim-eof
      text)
     "UTF-8"))]
  (apply str (map #(format "%02x" (bit-and % 0xff)) bytes*))))

(defn ^:private format-clj
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

(defn ^:private format-julia
 "Formats (`apply?`) or checks the Julia files under `paths` with JuliaFormatter, in
 its own environment; true on success."
 [apply? paths]
 (c/run-cmd [(c/find-julia) "--startup-file=no"
   (str "--project=" (c/in-root "test" "format"))
   (c/in-root "dev" "format.jl") (if apply? "--apply" "--check") paths]))

;; The SCSS indentation rules (`reindent-scss`): 4 spaces a level,
;; trailing whitespace removed, nothing else rewritten (line
;; breaks, spacing inside a line and the order are the author's):
;;   - a line is indented by the number of brackets ({ ( [) still open from earlier
;;     lines; a line that starts with closing brackets is indented by that many less;
;;   - the lines of a declaration (`name: value`, `$var: value`) that continue on
;;     further lines, without having opened a bracket of their own, are indented one
;;     level more than the declaration;
;;   - a comment line (`//`) takes the indentation of the code around it; the lines
;;     of a /* ... */ comment are kept as they are, except for the one that opens it;
;;   - strings, comments, unquoted `url(...)` and interpolation `#{...}` are read, so
;;     brackets in them are not counted wrongly.

(def scss-indent-unit "The spaces of one level of nesting." 4)

(def ^:private scss-openers #{\{ \( \[})

(def ^:private scss-closers #{\} \) \]})

(defn ^:private scan-scss
 "Reads `line` from the start. `in-block?` says whether it starts inside a /* */
 comment. Returns {:delta the net number of brackets the line opens, :lead the closing
 brackets it starts with, :code the text before a trailing // comment, :in-block? and
 :comment? (the line holds nothing but comment)}."
 [line in-block?]
 (let [n (count line)
   at (fn [i] (when (< i n) (.charAt ^String line i)))]
  (loop [i 0
    in-block in-block?
    open-quote nil
    delta 0
    lead 0
    leading? true
    code-end n]
   (if (>= i n)
    {:delta delta, :lead lead, :code (subs line 0 code-end), :in-block? in-block}
    (let [ch (at i)]
     (cond
      in-block (if (and (= ch \*) (= (at (inc i)) \/))
       (recur (+ i 2) false nil delta lead leading? code-end)
       (recur (inc i) true nil delta lead leading? code-end))
      open-quote
      (cond (= ch \\) (recur (+ i 2) false open-quote delta lead false code-end)
       (= ch open-quote) (recur (inc i) false nil delta lead false code-end)
       :else (recur (inc i) false open-quote delta lead false code-end))
      (or (= ch \") (= ch \')) (recur (inc i) false ch delta lead false code-end)
      (and (= ch \/) (= (at (inc i)) \/)) (recur n false nil delta lead false i)
      (and (= ch \/) (= (at (inc i)) \*))
      (recur (+ i 2) true nil delta lead false code-end)
      ;; unquoted url(...) may hold // and quotes: skip to its closing bracket
      (and (= ch \()
       (str/ends-with? (subs line 0 i) "url")
       (not (#{\" \'} (at (inc i)))))
      (let [close (str/index-of line ")" i)]
       (recur (if close (inc close) n) false nil delta lead false code-end))
      (scss-openers ch) (recur (inc i) false nil (inc delta) lead false code-end)
      (scss-closers ch) (recur (inc i)
       false
       nil
       (dec delta)
       (if leading? (inc lead) lead)
       leading?
       code-end)
      (Character/isWhitespace ^char ch)
      (recur (inc i) false nil delta lead leading? code-end)
      :else (recur (inc i) false nil delta lead false code-end)))))))

(def ^:private scss-declaration-start
 "The first line of `name: value`, `$var: value` or `--custom: value`; a selector such
 as `a:hover` has no space after its colon."
 #"^[$@A-Za-z_-][\w-]*:\s")

(defn reindent-scss
 "`text` of a .scss file with every line indented by the nesting rules above and
 without trailing whitespace. A second application changes nothing."
 [text]
 (let [lines (str/split text #"\n" -1)]
  (loop [[line & more] lines
    out []
    depth 0
    in-block? false
    ;; the open declaration: the depth it started at, or nil
    decl nil]
   (if (nil? line)
    (str/join "\n" out)
    (let [trimmed (str/trim line)]
     (cond in-block?
      (let [{:keys [in-block? delta]} (scan-scss line true)]
       (recur more (conj out (str/trimr line)) (+ depth delta) in-block? decl))
      (str/blank? trimmed) (recur more (conj out "") depth false decl)
      :else (let [{:keys [delta lead code in-block?]} (scan-scss trimmed false)
        comment? (or (str/starts-with? trimmed "//")
         (str/starts-with? trimmed "/*"))
        level (max 0 (- depth lead))
        continued?
        (and decl (= decl depth) (zero? lead) (not comment?))
        indent (* scss-indent-unit (+ level (if continued? 1 0)))
        depth' (max 0 (+ depth delta))
        ended? (let [c (str/trimr code)]
         (or (str/blank? c)
          (#{\; \{ \}} (last c))
          (pos? lead)
          (pos? delta)))
        decl' (cond comment? decl
         (and (nil? decl)
          (re-find scss-declaration-start trimmed)
          (not ended?))
         depth'
         ended? nil
         :else decl)]
       (recur more
        (conj out (str (apply str (repeat indent " ")) trimmed))
        depth'
        in-block?
        decl'))))))))

(defn ^:private format-scss
 "Formats (`apply?`) or checks the indentation of the .scss files under `paths`
 (`reindent-scss`); true on success. Lists the files that were (or would be) changed."
 [apply? paths]
 (let [changed (for [f (distinct (mapcat c/code-files paths))
     :when (str/ends-with? f ".scss")
     :let [path (c/in-root f)
      old (c/slurp8 path)
      fresh (trim-eof (reindent-scss old))]
     :when (not= old fresh)]
    (do (when apply? (c/spit8 path fresh)) f))]
  (doseq [f changed] (println (if apply? "formatted" "not formatted:") f))
  (or apply? (empty? changed))))

(defn ^:private reflow-prose
 "Re-wraps (`apply?`) or checks the prose of the `language` files under `paths`;
 true on success."
 [apply? language paths]
 (let [changed (reflow/reflow-files apply? language paths)]
  (doseq [f changed] (println (if apply? "re-wrapped" "prose to re-wrap:") f))
  (or apply? (empty? changed))))

;; The release name `v<version>-<release_name>` is shown on the main menu of the TUI, which
;; has room for this many characters.
(def max-version-name-length 22)

(defn version-name
 "The release name `v<version>-<release_name>` of the Project.toml text `toml`, or nil
 if it lacks either key."
 [toml]
 (let [version (second (re-find #"(?m)^version\s*=\s*\"([^\"]*)\"" toml))
   release (second (re-find #"(?m)^release_name\s*=\s*\"([^\"]*)\"" toml))]
  (when (and version release) (str "v" version "-" release))))

(defn version-problem
 "What is wrong with the release name in the Project.toml text `toml`, or nil if it is
 fine: a missing key, or more than `max-version-name-length` characters."
 [toml]
 (if-let [release (version-name toml)]
  (let [n (.codePointCount ^String release 0 (count release))]
   (when (> n max-version-name-length)
    (str "the release name "
     release
     " has "
     n
     " characters, the limit is "
     max-version-name-length
     " (the main menu of the TUI has room for that many)")))
  "there is no `version` or no `release_name`"))

(defn ^:private check-version-name
 "Checks the release name in the Project.toml at the root of the repository: prints the
 problem and returns false, or returns true."
 []
 (let [path (c/in-root "Project.toml")
   problem (when (fs/exists? path) (version-problem (c/slurp8 path)))]
  (when problem (println (str who ": Project.toml: " problem)))
  (nil? problem)))

(defn ^:private lint-clj
 "Runs clj-kondo (settings: .clj-kondo/config.edn) over the .clj files under `paths`,
 which prints what it finds; true when it finds no warning and no error."
 [paths]
 (let [files (->> paths
    (mapcat c/code-files)
    (filter #(str/ends-with? % ".clj"))
    distinct
    (map c/in-root))]
  (cond (empty? files) true
   (not (fs/which "clj-kondo"))
   (do (println
     "bb fmt: clj-kondo is not on the PATH, so the lint could not run")
    false)
   :else (c/run-cmd ["clj-kondo" "--lint" files]))))

(defn run
 "The tool's main program for the argument list `argv`; returns the exit status."
 [argv]
 (if (or (empty? argv) (some #{"--help" "-h"} argv))
  (c/usage)
  (let [[mode & rest-args] argv
    _ (when-not (#{"--apply" "--check"} mode)
     (c/fail who (str "unknown option " mode " (one of: --apply, --check)")))
    ;; a typo such as `bb fmt --check` (the task passes --apply) must not reach
    ;; the formatters as a path
    _ (when-let [bad (first (filter #(and (str/starts-with? % "--")
         (not (#{"--julia" "--clj" "--scss"}
           %)))
        rest-args))]
     (c/fail who
      (str "unknown option " bad
       " (use `bb fmt-check` to only check, "
       "`bb fmt` to rewrite; options: --julia, --clj, --scss)")))
    apply? (= mode "--apply")
    languages (set (filter #{"--julia" "--clj" "--scss"} rest-args))
    ;; no language flag: all
    both? (empty? languages)
    paths (or (seq (remove #{"--julia" "--clj" "--scss"} rest-args)) [c/*root*])
    ;; each language is run even if the other failed
    ;; the formatter first, then the prose; both run even if one fails
    both-ok (fn [language format-fn]
     (let [formatted (format-fn apply? paths)
       prose (reflow-prose apply? language paths)]
      (and formatted prose)))
    ;; the license header comes first; no language flag: every code file
    header-ok (format-headers apply?
     (if both?
      (set (keys language-extensions))
      (cond-> #{}
       (languages "--julia") (conj :julia)
       (languages "--clj") (conj :clj)
       (languages "--scss") (conj :scss)))
     paths)
    julia-ok (or (not (or both? (languages "--julia")))
     (both-ok :julia format-julia))
    clj-ok (or (not (or both? (languages "--clj"))) (both-ok :clj format-clj))
    scss-ok (or (not (or both? (languages "--scss")))
     (both-ok :scss format-scss))
    ;; after the formatting, `bb fmt` lints the Clojure code too (`bb fmt-check`
    ;; only checks; the precommit lints in a step of its own)
    lint-ok
    (or (not apply?) (not (or both? (languages "--clj"))) (lint-clj paths))
    ;; whatever the mode and the language: the release name must fit the main menu
    version-ok (check-version-name)]
   (when-not (and header-ok julia-ok clj-ok scss-ok lint-ok version-ok) 1))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
 (c/main run *command-line-args*))
