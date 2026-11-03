;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The buffer of a project: `buffer.edn` in the project's folder, an EDN map whose
;; `:solutes` is a vector of the solutes of the buffer, one map each:
;;
;;   {:kind :nonbiological, :name "NaCl", :arg "NaCl", :mM 200.0, :sigma-mM 10.0}
;;
;; `:name` is what the user calls it, `:arg` what BAYSOL is given (the solute's name for a
;; non-biological one), `:mM` the concentration and `:sigma-mM` its standard uncertainty,
;; both in millimolar as they were typed (BAYSOL takes molar; that is for the run).
;; Other keys of the map are kept as they are when the solutes are written, so what
;; the buffer gets later (pH, temperature) does not need a new file. A missing, empty or
;; comment-only file is a buffer with no solutes; a file that is not an EDN map (or whose
;; `:solutes` is not a vector of maps, or has a row that `row-problem` refuses) is unusable,
;; and is never written over.
;;
;; The kinds of row are the ones of `test/fixtures/buffer/buffer.edn`, the file the Julia
;; loader (`BAYSOL.Pipeline.load_buffer`, `src/Pipeline/Buffer.jl`) is tested against
;; too: `:nonbiological`, `:polymer`, `:dna`, `:rna` and `:protein` rows have an `:arg` (a
;; table name, a grade or family string, a clean sequence; a sequence row also has its
;; `:source` file name and `:record` id, provenance only); `:custom-nonbio` and
;; `:custom-polymer` rows carry a snapshot of the custom entry
;; (`baysol.tui.custom/snapshot`) and no `:arg`. Every row has `:kind`, `:name`, `:mM`
;; (above 0) and `:sigma-mM` (0 or more). `row-problem` checks the same keys and types as
;; the loader, so a row the screen writes is one the loader reads.

(ns baysol.tui.buffer
 (:require [baysol.tui.edn-store :as store]
  [clojure.java.io :as io]
  [clojure.string :as str]))

(defn buffer-file
 "The `buffer.edn` (a File) of the project `project-dir`."
 [project-dir]
 (io/file project-dir "buffer.edn"))

;; --- what a row must have (the loader's rules)

(def kinds
 "The kinds a row may have."
 #{:nonbiological :polymer :dna :rna :protein :custom-nonbio :custom-polymer})

(def max-units
 "The most units a custom polymer row has (`baysol.tui.custom/max-units`, the loader's
 `CUSTOM_POLYMER_MAX_UNITS`)."
 4)

(defn ^:private num?
 [x]
 (and (number? x) (not (Double/isNaN (double x)))))

(defn ^:private int?*
 [x]
 (or (instance? Long x)
  (instance? Integer x)
  (instance? Short x)
  (instance? Byte x)
  (instance? clojure.lang.BigInt x)
  (instance? java.math.BigInteger x)))

(defn ^:private opt-num?
 "A number, or nil: the key must be there (the loader wants it written)."
 [m k]
 (and (contains? m k) (or (nil? (get m k)) (num? (get m k)))))

(defn ^:private named?
 [x]
 (and (string? x) (not (str/blank? x))))

(defn ^:private unit-problem
 [u]
 (cond (not (map? u)) "a unit is not a map"
  (not (int?* (:z u))) "unit :z must be an integer"
  (not (num? (:slope u))) "unit :slope must be a number"
  (not (opt-num? u :sigma)) "unit :sigma must be a number or nil"))

(defn ^:private custom-problem
 [row]
 (if (= (:kind row) :custom-nonbio)
  (cond (not (named? (:custom row))) ":custom must be a name"
   (not (int?* (:z row))) ":z must be an integer"
   (not (num? (:pmv row))) ":pmv must be a number"
   (not (opt-num? row :sigma-pmv)) ":sigma-pmv must be a number or nil")
  (let [units (:units row)
    counts (:counts row)]
   (cond (not (named? (:custom row))) ":custom must be a name"
    (not (and (vector? units) (<= 1 (count units) max-units)))
    ":units needs 1 to 4"
    (some unit-problem units) (some unit-problem units)
    (not (and (vector? counts) (every? num? counts))) ":counts must be numbers"
    (not= (count counts) (count units)) ":counts needs one per unit"
    (not (int?* (:z-ends row))) ":z-ends must be an integer"
    (not (num? (:pmv-ends row))) ":pmv-ends must be a number"
    (not (opt-num? row :sigma-ends)) ":sigma-ends must be a number or nil"))))

(defn row-problem
 "What is wrong with the buffer row `row` for the Julia loader, a short text, or nil when
 it is fine: a map of a known `:kind` with an `:mM` above 0 and a `:sigma-mM` of 0 or more
 (numbers), and the keys its kind needs (see the top of this file). The name of a row is
 only a label and is not checked here."
 [row]
 (cond (not (map? row)) "a row is not a map"
  (not (contains? kinds (:kind row))) "unknown :kind"
  (not (and (num? (:mM row)) (pos? (:mM row)))) ":mM must be above 0"
  (not (and (num? (:sigma-mM row)) (>= (:sigma-mM row) 0)))
  ":sigma-mM must be 0 or more"
  (contains? #{:custom-nonbio :custom-polymer} (:kind row)) (custom-problem
   row)
  (not (named? (:arg row))) ":arg must be a name"))

(defn ^:private read-map
 "The map in the buffer file of `project-dir`: `{}` for no file or no content.
 Throws an exception (`:type ::unusable`) if the file is not readable as one EDN map."
 [project-dir]
 (store/read-map (buffer-file project-dir)
  {:type ::unusable,
   :name "buffer.edn",
   :expected "a map with a vector of valid solutes",
   :valid?
   (fn [value]
    (let [s (:solutes value [])]
     (and (vector? s) (every? map? s) (not-any? row-problem s))))}))

(defn read-solutes
 "The solutes of the buffer of `project-dir`, a vector of maps (empty for none).
 Throws an exception (`:type ::unusable`) if the file cannot be used."
 [project-dir]
 (vec (:solutes (read-map project-dir) [])))

(defn write-solutes!
 "Writes `solutes` (a vector of maps) as the solutes of the buffer of `project-dir`, the
 other keys of the file kept, through a temporary file that replaces it in one step. The
 file is made if there is none; one that cannot be used is not touched (the exception of
 `read-solutes` is thrown). A solute that `row-problem` refuses is not written: an
 exception (`:type ::invalid`) is thrown first. Returns the file."
 [project-dir solutes]
 (when-let [p (some row-problem solutes)]
  (throw (ex-info (str "not a valid buffer row: " p) {:type ::invalid})))
 (let [others (dissoc (read-map project-dir) :solutes)
   file (buffer-file project-dir)
   text (store/map-text :solutes (map pr-str solutes) others)]
  (store/write-atomic! file text)))
