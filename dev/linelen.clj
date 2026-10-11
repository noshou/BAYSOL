#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The line-length rule of the code (every line at
;; most 92 characters) and the tools for applying it.
;;
;;     bb linelen --check [PATH ...]
;;     bb linelen --snapshot DIR
;;     bb linelen --verify DIR [PATH ...]
;;     bb linelen --reflow [PATH ...]
;;
;; One of the four modes is required; without any, the tool prints this text.
;;
;;   --check      lists every line over 92 characters (file:line: length) in the code
;;                files under PATH (files or directories, default the whole
;;                repository) and exits 1 if there is one; a tab character is an
;;                error too. Characters are counted, not bytes. The precommit step
;;                `line-length` runs this and refuses the commit.
;;   --snapshot   copies every checked code file into DIR (keeping the relative
;;                paths), the state to compare against.
;;   --verify     after the long lines were split: every checked file (under PATH,
;;                default all) that differs from its copy in DIR must have the same
;;                code. Julia files are compared as syntax trees (comments and line
;;                breaks do not count, the whitespace inside string and docstring
;;                literals is normalized), Clojure and EDN files by their forms (comments
;;                and layout do not count), YAML and SCSS by their words. Exits 1 on the
;;                first difference.
;;
;;   --reflow     re-wraps the comment blocks and docstring paragraphs of Julia,
;;                Clojure and EDN files under PATH that contain a line over the limit,
;;                balanced (all lines about equally long, no stray last word). Code,
;;                lists, tables, code blocks and indented text are left alone.
;;
;; Checked: code only (.jl .clj .edn .scss .yml), not Markdown,
;; data (json, tsv, toml, txt) or generated CSS. Needs Babashka;
;; --verify needs `julia` on the PATH (or JULIA=/path/to/julia).

(ns linelen
    (:require [babashka.classpath :refer [add-classpath]]
        [babashka.fs :as fs]
        [clojure.string :as str]
        [edamame.core :as edamame]))

(add-classpath (str
        (fs/path (fs/parent (fs/absolutize *file*)) ".." "test" "utils")))

(require '[common :as c])

(def ^:private who "bb linelen")

(defn- clojure-ext?
    "Is `ext` the extension of a Clojure source or EDN file (`;` comments)?"
    [ext]
    (contains? #{"clj" "edn"} ext))

(def limit 92)

(defn- len
    "Characters of `s`, not UTF-16 units: a code point outside the BMP counts once."
    [s]
    (.codePointCount ^String s 0 (count s)))

(defn- lines-of
    "The lines of the file `rel` (relative to the root), split on newlines only: a
    carriage return stays at the end of its line."
    [rel]
    (str/split (c/slurp8 (c/in-root rel)) #"\n" -1))

;; --- --check

(defn- long-lines
    "[file line-number length] of every line over the limit in `files`."
    [files]
    (for [f files
            [i line] (map-indexed vector (lines-of f))
            :let [n (len (str/replace line #"\r$" ""))]
            :when (> n limit)]
        [f (inc i) n]))

(defn- tab-lines
    "[file line-number] of every line holding a tab character (indent with 4 spaces)."
    [files]
    (for [f files
            [i line] (map-indexed vector (lines-of f))
            :when (str/includes? line "\t")]
        [f (inc i)]))

(defn- check
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

;; --- --snapshot and --verify

(defn- snapshot
    "Copies every code file of the repository into `dir`, keeping the relative paths."
    [dir]
    (let [files (c/code-files c/*root*)]
        (doseq [f files]
            (let [to (fs/path dir f)]
                (fs/create-dirs (fs/parent to))
                (fs/copy (c/in-root f) to {:replace-existing true})))
        (println (str "snapshot of " (count files) " files in " dir))))

(defn- clj-forms
    "The forms of a Clojure source as a string: what a re-wrapping must leave alone.
    Comments and layout are not part of the forms."
    [text]
    (pr-str (edamame/parse-string-all text {:all true})))

(defn- plain-words
    "The words of a YAML or SCSS source, without blank lines and `#` comment lines."
    [text]
    (->> (str/split-lines text)
        (map str/trim)
        (remove #(or (str/blank? %) (str/starts-with? % "#")))
        (mapcat #(re-seq #"\S+" %))))

(defn- same-code?
    "Do the two texts of file `f` hold the same code? Julia is judged by its own parser
    elsewhere, so it is not handled here."
    [f a b]
    (case (fs/extension f)
        ("clj" "edn") (= (clj-forms a) (clj-forms b))
        (= (plain-words a) (plain-words b))))

(defn- verify
    "Checks that each file under `paths` that differs from its copy in `dir` holds the
    same code; true when all do."
    [dir paths]
    (let [files (mapcat c/code-files (or (seq paths) [c/*root*]))
            ;; the files that have a copy and differ from it
            changed (for [f files
                    :let [old (fs/path dir f)]
                    :when (fs/exists? old)
                    :let [a (c/slurp8 old)
                        b (c/slurp8 (c/in-root f))]
                    :when (not= a b)]
                [f a b])
            julia (filter #(= "jl" (fs/extension (first %))) changed)
            bad (count (remove (fn [[f a b]] (same-code? f a b))
                    (remove #(= "jl" (fs/extension (first %))) changed)))
            ;; Julia files are compared as syntax trees by ast_same.jl
            julia-bad (if (seq julia)
                (if (c/run-cmd [(c/find-julia) "--startup-file=no"
                            (c/in-root "test" "utils" "ast_same.jl") dir
                            c/*root* (map first julia)])
                    0
                    1)
                0)]
        (doseq [[f a b] changed
                :when (and (not= "jl" (fs/extension f)) (not (same-code? f a b)))]
            (println (str "DIFFERENT CODE: " f)))
        (println (str "verify: " (count changed)
                " changed file(s) (" (count julia)
                " Julia), " (if (pos? (+ bad julia-bad))
                    "DIFFERENCES FOUND"
                    "same code")))
        (zero? (+ bad julia-bad))))

;; --- --reflow
;;
;; Re-wrapping works on the lines of a file. Each rule below looks at the line at
;; index `i` and either returns {:out [lines it writes] :next index-to-continue-at},
;; or nil when it does not apply; the first rule that applies wins.

(defn words
    "The words of a paragraph. A backtick code span and the target of a Markdown link
    `[text](target)` stay in one piece (a space inside them is not a break). With an
    odd number of backticks: plain words."
    [text]
    (if (odd? (count (re-seq #"`" text)))
        (re-seq #"\S+" text)
        (let [step (fn [{:keys [cur code link prev out]} ch]
                    (let [code (if (= ch \`) (not code) code)
                            link (cond code link
                                (and (= ch \() (= prev \])) true
                                (and (= ch \)) link) false
                                :else link)
                            brk (and (Character/isWhitespace ^char ch)
                                (not code)
                                (not link))]
                        {:cur (if brk "" (str cur ch)),
                            :out (if (and brk (seq cur)) (conj out cur) out),
                            :code code,
                            :link link,
                            :prev ch}))
                {:keys [cur out]}
                (reduce step
                    {:cur "", :code false, :link false, :prev nil, :out []}
                    text)]
            (if (seq cur) (conj out cur) out))))

(defn- greedy
    "Greedy wrap of `ws` to lines of at most `w` characters."
    [ws w]
    (let [[lines cur] (reduce (fn [[lines cur] word]
                    (cond (nil? cur) [lines word]
                        (<= (+ (len cur) 1 (len word)) w)
                        [lines (str cur " " word)]
                        :else [(conj lines cur) word]))
                [[] nil]
                ws)]
        (if cur (conj lines cur) lines)))

(defn bad-start?
    "Would Markdown read the line as a list, heading, quote or table?"
    [line]
    (boolean (re-find #"^(?:[-*+#>|=]|\d+[.)])(?:\s|$)|^```" line)))

(defn balanced
    "`ws` wrapped balanced into lines of at most `width` characters: as few lines as
    greedy needs, at the smallest width that still gives that many lines (and no
    continuation line that Markdown would read as structure)."
    [ws width]
    (let [k (count (greedy ws width))]
        (if (<= k 1)
            (greedy ws width)
            (let [longest (apply max (map len ws))
                    lo (max longest (quot (len (str/join " " ws)) k))]
                (or (->> (range lo (inc width))
                        (map #(greedy ws %))
                        (filter #(and (<= (count %) k)
                                (not-any? bad-start? (rest %))))
                        first)
                    (greedy ws width))))))

(defn- structured?
    "Is this comment text the start of a list item, a table row, an aligned column or
    other structure?"
    [text]
    (boolean (re-find #"^(?:[-*+]\s|\d+[.)]\s|\||```|[A-Za-z_0-9`]+\s*(?:=|:)\s*$)"
            text)))

(defn- banner?
    "Is this comment text a section banner (`--- name` or `=== name`)?"
    [ext text]
    (boolean (re-find (if (clojure-ext? ext) #"^[-=─]{3}" #"^#+\s*[-=─]{3}") text)))

;; The comment prefix of a file type: `#` for Julia, one or more `;` for Clojure.
(defn- comment-re
    [ext]
    (if (clojure-ext? ext) #"^(\s*;+) (\S.*)$" #"^(\s*#) (\S.*)$"))

(defn- docstring-fence
    "A line that is exactly three quotes opens or closes a Julia docstring."
    [{:keys [ext lines]} i]
    (when (and (= ext "jl") (= (str/trim (lines i)) "\"\"\""))
        {:out [(lines i)], :next (inc i), :toggle true}))

(defn- one-line-docstring
    "A one-line Julia docstring that is too long becomes a block docstring."
    [{:keys [ext lines in-doc]} i]
    (let [line (lines i)]
        (when (and (= ext "jl")
                (not in-doc)
                (re-find #"^(\"|\"\"\")" line)
                (re-matches #"\"[^\"]*\"" line)
                (> (len line) limit))
            {:out (concat ["\"\"\""]
                    (balanced (words (subs line 1 (dec (count line)))) limit)
                    ["\"\"\""]),
                :next (inc i)})))

(defn- continuation
    "The indented lines after index `i` that continue a docstring list item: [hang
    parts next-index], `hang` being the indent of the first one."
    [lines i]
    (let [cont (->> (range (inc i) (count lines))
                (map (fn [j] [j (lines j)]))
                (take-while
                    (fn [[_ l]]
                        (and (not (str/blank? l))
                            (not (re-find #"^\s*([-*]\s|\d+[.)]\s|```|#|@|\||\")"
                                    l))
                            (re-matches #"(\s+)(\S.*)" l)))))]
        [(if (seq cont)
                (second (re-matches #"(\s+)(\S.*)" (second (first cont))))
                "") (map (fn [[_ l]] (nth (re-matches #"(\s+)(\S.*)" l) 2)) cont)
            (+ i 1 (count cont))]))

(defn- docstring-list-item
    "A too long list item of a Julia docstring (`- text` with its indented continuation
    lines) is re-wrapped under its marker, with a hanging indent."
    [{:keys [ext lines in-doc]} i]
    (when-let [[_ ind mark text] (and (= ext "jl")
                in-doc
                (re-matches #"(\s*)([-*]\s+|\d+[.)]\s+)(\S.*)"
                    (lines i)))]
        (let [[hang more j] (continuation lines i)
                parts (cons text more)
                long? (or (> (len (lines i)) limit)
                    (some #(> (len (str hang %)) limit) more))]
            {:out (if long?
                    (let [hang (if (seq hang)
                                hang
                                (apply str
                                    (repeat (max (len (str ind mark)) 4)
                                        " ")))
                            first-part (str ind mark)
                            width (- limit (max (len first-part) (len hang)))
                            wrapped (balanced (words (str/join " " parts)) width)]
                        (cons (str first-part (first wrapped))
                            (map #(str hang %) (rest wrapped))))
                    (subvec lines i j)),
                :next j})))

(defn- trailing-comment
    "A trailing comment that makes a Julia code line too long moves above the line."
    [{:keys [ext lines in-doc]} i]
    (let [line (lines i)]
        (when-let [[_ ind code cmt]
                (and (= ext "jl")
                    (not in-doc)
                    (> (len line) limit)
                    (re-matches #"(\s*)([^#\s][^#]*?)\s+# (\S.*)" line))]
            (when (and (even? (count (re-seq #"\"" code)))
                    (not (re-find #"^\s*\"" code)))
                {:out (concat (map #(str ind "# " %)
                            (balanced (words cmt) (- limit (len ind) 2)))
                        [(str ind code)]),
                    :next (inc i)}))))

(defn- paragraph-lines
    "The consecutive lines from `i` that form one paragraph, and the prefix they share:
    [prefix texts], or nil when line `i` starts none. A paragraph is a block of
    comment lines with one prefix, or (Julia) plain lines of a docstring."
    [{:keys [ext lines in-doc]} i]
    (let [line (lines i)]
        (cond (re-matches (comment-re ext) line)
            (let [[_ pre] (re-matches (comment-re ext) line)
                    texts (->> (range i (count lines))
                        (map #(re-matches (comment-re ext) (lines %)))
                        (take-while #(and %
                                (= (second %) pre)
                                (not (structured? (nth % 2)))
                                (not (banner? ext (nth % 2)))))
                        (map #(nth % 2)))]
                [(str pre " ") texts])
            (and (= ext "jl")
                in-doc
                (re-find #"^\S" line)
                (not (structured? line))
                (not (re-find #"^[@#!]" line)))
            [""
                (->> (range i (count lines))
                    (map lines)
                    (take-while #(and (re-find #"^\S" %)
                            (not (structured? %))
                            (not (re-find #"^[@#!\"]" %)))))])))

(defn- paragraph
    "A paragraph with a line over the limit is re-wrapped balanced under its prefix; one
    that fits is kept."
    [ctx i]
    (when-let [[prefix texts] (paragraph-lines ctx i)]
        (when (seq texts)
            {:out (if (some #(> (len (str prefix %)) limit) texts)
                    (map #(str prefix %)
                        (balanced (words (str/join " " texts))
                            (- limit (len prefix))))
                    (map #(str prefix %) texts)),
                :next (+ i (count texts))})))

(def ^:private rules
    [docstring-fence one-line-docstring docstring-list-item trailing-comment
        paragraph])

(defn reflow-lines
    "The `lines` (a vector) of a file of type `ext` (\"jl\" or \"clj\") with the
    paragraphs that contain a long line re-wrapped."
    [lines ext]
    (loop [i 0
            in-doc false
            out []]
        (if (>= i (count lines))
            out
            (let [ctx {:lines lines, :ext ext, :in-doc in-doc}
                    hit (some #(% ctx i) rules)]
                (if hit
                    (recur (:next hit)
                        (if (:toggle hit) (not in-doc) in-doc)
                        (into out (:out hit)))
                    ;; no rule applies: the line stays
                    (recur (inc i) in-doc (conj out (lines i))))))))

(defn- reflow
    "Re-wraps the Julia and Clojure files under `paths`; prints how many changed."
    [paths]
    (let [n (count (for [f (mapcat c/code-files (or (seq paths) [c/*root*]))
                        :let [ext (fs/extension f)]
                        :when (#{"jl" "clj" "edn"} ext)
                        :let [old (lines-of f)
                            fresh (reflow-lines (vec old) ext)]
                        :when (not= fresh old)]
                    (c/spit8 (c/in-root f) (str/join "\n" fresh))))]
        (println (str "reflow: " n " file(s) rewritten"))))

(defn run
    "The tool's main program for the argument list `argv`; returns the exit status."
    [argv]
    (if (or (empty? argv) (some #{"--help" "-h"} argv))
        (c/usage)
        (let [[cmd & more] argv]
            (case cmd
                "--check" (when-not (check more) 1)
                "--snapshot" (if (= 1 (count more))
                    (snapshot (first more))
                    (c/fail who "--snapshot needs a directory"))
                "--verify" (if (seq more)
                    (when-not (verify (first more) (rest more)) 1)
                    (c/fail who "--verify needs the snapshot directory"))
                "--reflow" (reflow more)
                (c/fail who
                    (str
                        "unknown option "
                        cmd
                        " (one of: --check, --snapshot, --verify, --reflow)"))))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
    (c/main run *command-line-args*))
