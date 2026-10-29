;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Re-wrapping of the prose of the code: the comment blocks and docstring paragraphs of
;; Julia, Clojure and EDN files that contain a line over the limit are filled again,
;; balanced (all lines about equally long, no stray last word). Code, lists, tables,
;; code blocks and indented text are left alone, and a block that fits is kept as it
;; is, so a second pass changes nothing. The formatters do not wrap prose; `bb fmt`
;; runs this after them (dev/format.clj), and `bb linelen --check` reports what is
;; still too long.

(ns reflow
 (:require [babashka.fs :as fs]
  [clojure.string :as str]
  [common :as c]))

(def ^:private limit c/line-limit)

(def ^:private len c/char-count)

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
       brk
       (and (Character/isWhitespace ^char ch) (not code) (not link))]
      {:cur (if brk "" (str cur ch)),
       :out (if (and brk (seq cur)) (conj out cur) out),
       :code code,
       :link link,
       :prev ch}))
    {:keys [cur out]}
    (reduce step {:cur "", :code false, :link false, :prev nil, :out []} text)]
   (if (seq cur) (conj out cur) out))))

(defn ^:private greedy
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
      (filter #(and (<= (count %) k) (not-any? bad-start? (rest %))))
      first)
     (greedy ws width))))))

(defn ^:private structured?
 "Is this comment text the start of a list item, a table row, an aligned column or
 other structure?"
 [text]
 (boolean (re-find #"^(?:[-*+]\s|\d+[.)]\s|\||```|[A-Za-z_0-9`]+\s*(?:=|:)\s*$)"
   text)))

(defn ^:private banner?
 "Is this comment text a section banner (`--- name` or `=== name`)?"
 [ext text]
 (boolean (re-find (if (= ext "jl") #"^#+\s*[-=─]{3}" #"^[-=─]{3}") text)))

;; The comment prefix of a file type: `#` for Julia, one or more `;` for Clojure, `//`
;; for SCSS.
(defn ^:private comment-re
 [ext]
 (case ext
  "scss" #"^(\s*//) (\S.*)$"
  ("clj" "edn") #"^(\s*;+) (\S.*)$"
  #"^(\s*#) (\S.*)$"))

(defn ^:private docstring-fence
 "A line that is exactly three quotes opens or closes a Julia docstring."
 [{:keys [ext lines]} i]
 (when (and (= ext "jl") (= (str/trim (lines i)) "\"\"\""))
  {:out [(lines i)], :next (inc i), :toggle true}))

(defn ^:private one-line-docstring
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

(defn ^:private continuation
 "The indented lines after index `i` that continue a docstring list item: [hang
 parts next-index], `hang` being the indent of the first one."
 [lines i]
 (let [cont (->> (range (inc i) (count lines))
    (map (fn [j] [j (lines j)]))
    (take-while
     (fn [[_ l]]
      (and (not (str/blank? l))
       (not (re-find #"^\s*([-*]\s|\d+[.)]\s|```|#|@|\||\")" l))
       (re-matches #"(\s+)(\S.*)" l)))))]
  [(if (seq cont) (second (re-matches #"(\s+)(\S.*)" (second (first cont)))) "")
   (map (fn [[_ l]] (nth (re-matches #"(\s+)(\S.*)" l) 2)) cont)
   (+ i 1 (count cont))]))

(defn ^:private docstring-list-item
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
        (apply str (repeat (max (len (str ind mark)) 4) " ")))
       first-part (str ind mark)
       width (- limit (max (len first-part) (len hang)))
       wrapped (balanced (words (str/join " " parts)) width)]
      (cons (str first-part (first wrapped))
       (map #(str hang %) (rest wrapped))))
     (subvec lines i j)),
    :next j})))

(defn ^:private trailing-comment
 "A trailing comment that makes a Julia code line too long moves above the line."
 [{:keys [ext lines in-doc]} i]
 (let [line (lines i)]
  (when-let [[_ ind code cmt] (and (= ext "jl")
     (not in-doc)
     (> (len line) limit)
     (re-matches #"(\s*)([^#\s][^#]*?)\s+# (\S.*)"
      line))]
   (when (and (even? (count (re-seq #"\"" code))) (not (re-find #"^\s*\"" code)))
    {:out (concat (map #(str ind "# " %)
       (balanced (words cmt) (- limit (len ind) 2)))
      [(str ind code)]),
     :next (inc i)}))))

(defn ^:private paragraph-lines
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

(defn ^:private paragraph
 "A paragraph with a line over the limit is re-wrapped balanced under its prefix; one
 that fits is kept."
 [ctx i]
 (when-let [[prefix texts] (paragraph-lines ctx i)]
  (when (seq texts)
   {:out (if (some #(> (len (str prefix %)) limit) texts)
     (map #(str prefix %)
      (balanced (words (str/join " " texts)) (- limit (len prefix))))
     (map #(str prefix %) texts)),
    :next (+ i (count texts))})))

(def ^:private rules
 [docstring-fence one-line-docstring docstring-list-item trailing-comment
  paragraph])

(defn reflow-lines
 "The `lines` (a vector) of a file of type `ext` (\"jl\", \"clj\", \"edn\" or \"scss\")
 with the paragraphs that contain a long line re-wrapped."
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

(def ^:private extensions
 "The file types the engine knows, by language flag."
 {:julia #{"jl"}, :clj #{"clj" "edn"}, :scss #{"scss"}})

(defn reflow-files
 "Re-wraps the files of `language` (`:julia` or `:clj`) under `paths`. With `apply?`
 the changed files are rewritten. Returns the changed files (relative to the root)."
 [apply? language paths]
 (vec (for [f (distinct (mapcat c/code-files paths))
    :let [ext (fs/extension f)]
    :when ((extensions language) ext)
    :let [old (str/split (c/slurp8 (c/in-root f)) #"\n" -1)
     fresh (reflow-lines (vec old) ext)]
    :when (not= fresh old)]
   (do (when apply? (c/spit8 (c/in-root f) (str/join "\n" fresh))) f))))
