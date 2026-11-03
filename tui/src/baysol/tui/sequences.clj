;; SPDX-License-Identifier: LGPL-3.0-or-later

;; A strict reader of FASTA and FASTQ text for the DNA, RNA and protein rows of the buffer
;; (not used by the buffer page yet). `parse-text` and `parse-file` give every record
;; as `{:id :sequence}` or `{:error message}`, the message at most 22 characters (it is
;; shown in a 24-character border note). One record makes one buffer row.
;;
;; The alphabets are the ones the Julia code accepts (src/BulkElectronDensity/Nucleotide
;; and Protein): DNA `A C G T` plus the IUPAC ambiguity codes `R Y S W K M B D H V N`; RNA
;; the same with `U` for `T` (`T` in RNA and `U` in DNA are errors); protein the twenty
;; residues `A C D E F G H I K L M N P Q R S T V W Y`, selenocysteine `U`, pyrrolysine `O`
;; and the ambiguity codes `B J Z`. `*` (any kind) and `X` (protein) are placeholders
;; Julia skips, so they are accepted and kept in the sequence, but they are no residue
;; and a record of nothing else is empty. Letters are upper-cased, whitespace is dropped,
;; nothing else is repaired (a gap `-`, a digit, an `@` in a FASTA body are errors).
;;
;; FASTA: a `>` header line, then the sequence on one or more lines. FASTQ: strict four
;; line records `@id`, the sequence on one line, `+` (with or without a repeat of the id)
;; and a quality line of the same length; only the sequence is kept, and an `@` at the
;; start of a quality line is not a header. The id is the header up to the first
;; whitespace. Blank lines are allowed in FASTA anywhere and in FASTQ before the first and
;; after the last record only; CRLF line ends are fine.

(ns baysol.tui.sequences
 (:require [clojure.java.io :as io]
  [clojure.string :as str]))

(def ^:private ambiguity-nuc "RYSWKMBDHVN")

(def ^:private alphabets
 {:dna (set (str "ACGT" ambiguity-nuc)),
  :rna (set (str "ACGU" ambiguity-nuc)),
  :protein (set "ACDEFGHIKLMNOPQRSTUVWYBJZ")})

(def ^:private placeholders
 "The letters Julia skips: no residue."
 {:dna #{\*}, :rna #{\*}, :protein #{\* \X}})

(def ^:private kind-names {:dna "DNA", :rna "RNA", :protein "protein"})

(def extensions
 "The file extensions (lower case, with the dot) of the sequence files."
 [".fasta" ".fa" ".fna" ".faa" ".fastq" ".fq"])

(defn fasta-file?
 "Whether the file name (or path) `fname` ends in one of the [[extensions]], in any case."
 [fname]
 (let [low (str/lower-case (str fname))]
  (boolean (some #(str/ends-with? low %) extensions))))

(defn ^:private err [message] {:error message})

(defn ^:private clean
 "The sequence text `s` without whitespace, upper-cased."
 [s]
 (str/upper-case (str/replace s #"\s+" "")))

(defn ^:private check-sequence
 "`seq-text` (cleaned) if every letter is allowed for `kind` and one is a residue, else
 {:error}."
 [kind seq-text]
 (let [ok (into (get alphabets kind) (get placeholders kind))
   bad (first (remove ok seq-text))
   real (remove (get placeholders kind) seq-text)]
  (cond bad (err (str "bad letter " bad " (" (kind-names kind) ")"))
   (empty? real) (err "empty sequence")
   :else seq-text)))

(defn ^:private record-id
 "The id of the header line `header` (its first character dropped): up to the first
 whitespace; `fallback` when that is empty."
 [header fallback]
 (let [id (first (str/split (str/trim (subs header 1)) #"\s+"))]
  (if (str/blank? id) fallback id)))

(defn ^:private finish
 "The result for the raw records [{:id :raw}] of `kind`: each sequence cleaned and
 checked, the first error returned."
 [kind raws]
 (if (empty? raws)
  (err "no records")
  (let [checked (map (fn [{:keys [id raw]}]
      (let [s (check-sequence kind (clean raw))]
       (if (:error s) s {:id id, :sequence s})))
     raws)]
   (or (first (filter :error checked)) {:records (vec checked)}))))

(defn ^:private fasta-raws
 "The records [{:id :raw}] of the FASTA `lines` (the first one is a header)."
 [lines]
 (loop [ls (remove str/blank? lines)
   acc []]
  (if (empty? ls)
   acc
   (let [header (first ls)
     body (take-while #(not (str/starts-with? % ">")) (rest ls))]
    (recur (drop (inc (count body)) ls)
     (conj acc
      {:id (record-id header (str "seq" (inc (count acc)))),
       :raw (str/join body)}))))))

(defn ^:private fastq-parse
 "The result for the FASTQ `lines` (blank lines at both ends already dropped)."
 [kind lines]
 (loop [ls lines
   acc []]
  (if (empty? ls)
   (finish kind acc)
   (let [[head sq plus quality] ls]
    (cond (not (str/starts-with? head "@")) (err "bad FASTQ record")
     (or (nil? sq) (nil? plus) (nil? quality)) (err "missing line")
     (not (str/starts-with? plus "+")) (err "bad FASTQ record")
     (not= (count (clean sq)) (count (str/trim quality)))
     (err "quality length differs")
     :else (recur (drop 4 ls)
      (conj acc
       {:id (record-id head (str "seq" (inc (count acc)))),
        :raw sq})))))))

(defn parse-text
 "Parses the FASTA or FASTQ `text` as sequences of `kind` (`:dna`, `:rna` or `:protein`).

 # Returns
 `{:records [{:id \"p1\" :sequence \"ACGT\"} ...]}`, or `{:error message}` (at most 22
 characters) for: no records, an empty sequence, a first line that starts with neither
 `>` nor `@`, a FASTQ record that has a missing line or a quality line of another length,
 a letter outside the alphabet of `kind`.

 # Exceptions
 Throws `IllegalArgumentException` for another `kind`."
 [text kind]
 (when-not (contains? alphabets kind)
  (throw (IllegalArgumentException. (str "unknown sequence kind " kind))))
 (let [lines (mapv #(str/replace % #"\s+$" "") (str/split (str text) #"\r?\n" -1))
   lines (->> lines
    (drop-while str/blank?)
    reverse
    (drop-while str/blank?)
    reverse
    vec)]
  (cond (empty? lines) (err "no records")
   (str/starts-with? (first lines) ">") (finish kind (fasta-raws lines))
   (str/starts-with? (first lines) "@") (fastq-parse kind lines)
   :else (err "wrong format"))))

(defn parse-file
 "Parses the file `path` like [[parse-text]]; `{:error \"cannot read file\"}` when it
 cannot be read as text."
 [path kind]
 (let [text (try (slurp (io/file path) :encoding "UTF-8") (catch Exception _ nil))]
  (if text (parse-text text kind) (err "cannot read file"))))

(defn residue-count
 "The number of residues of `letters`: its letters without the placeholders `*` and
 `X`."
 [letters]
 (count (remove #{\* \X} letters)))

(defn summary
 "The compact text of a sequence for the params cell: `ACG…GCA (24 nt)` for `:dna` and
 `:rna`, `MKT…QLS (317 aa)` for `:protein`. The count suffix is always kept; the head and
 the tail of the sequence shrink (the head gets the odd letter) to make the whole at most
 `width` characters, and the sequence is shown whole when it fits."
 [kind letters width]
 (let [n (residue-count letters)
   suffix (str " (" n (if (= kind :protein) " aa)" " nt)"))
   room (- width (count suffix))]
  (cond (<= (count letters) room) (str letters suffix)
   (< room 3) (str (apply str (take (max room 0) letters)) suffix)
   :else (let [room-kept (dec room)
     head (quot (inc room-kept) 2)
     tail (quot room-kept 2)]
    (str (subs letters 0 head)
     "…"
     (subs letters (- (count letters) tail))
     suffix)))))
