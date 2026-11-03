#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Writes the index of every solute name a user may type in the terminal interface to
;; tui/resources/solute_index.edn, for the autocomplete of the buffer page.
;;
;;     bb harvest-solutes [--check]
;;
;;   (no option)  reads the two alias tables and the two value tables of
;;                src/BulkElectronDensity (NonBiological/nonbio_lookup.json and
;;                nonbiological.json, Polymers/polymers_lookup.json and polymers.json)
;;                and the families of tui/resources/polymer_families.edn, and writes
;;                the index, sorted and deterministic, then formats the file the way
;;                `bb fmt` does
;;   --check      changes nothing: builds the index in a scratch file next to the real
;;                one and exits 1 when the file differs, that is, is out of date
;;
;; The index maps a (lower-case) name to its canonical target: every alias of the
;; non-biological table to its IUPAC name (the `:arg` of a buffer row), every alias of a
;; polymer grade to the grade, and every name of a polymer family to the family. Names
;; and targets are kept apart in two vectors per kind, a name holding the position of
;; its target, so the file stays well under 1.5 MB. A name too long for the line limit
;; of the repository is written as a vector of pieces that the reader joins. Each
;; polymer target has a `:basis` (what the molarity is per) where it is not "per mole of
;; chains". A name that a polymer family recognises is the family's, not the grade's
;; (the Julia code lets the family win too), and a table alias whose target is not in
;; the value table is left out (the tool prints the count).
;;
;; `bb precommit` runs the first form, so a changed index belongs to the commit.

(ns harvest-solutes
 (:require [babashka.classpath :refer [add-classpath]]
  [babashka.fs :as fs]
  [cheshire.core :as json]
  [clojure.edn :as edn]
  [clojure.string :as str]))

(add-classpath (str (fs/parent (fs/absolutize *file*))))

(require '[common :as c])

(def ^:private who "bb harvest-solutes")

(def ^:private out-file (c/in-root "tui" "resources" "solute_index.edn"))

(def ^:private families-file (c/in-root "tui" "resources" "polymer_families.edn"))

(def ^:private bde ["src" "BulkElectronDensity"])

(def ^:private piece-length
 "A name longer than this many characters is written in pieces of this length."
 70)

;; What the molarity of a polymer means where it is not the moles of chains
;; (src/BulkElectronDensity/README.md, section Polymers): the first pattern that matches
;; the grade or one of its aliases decides.
(def ^:private basis-rules
 [[#"dextran|amphipol|\bpvp\b|\bpva\b" "per monomer unit"]
  [#"ficoll" "per 1000 Da"]])

(defn basis-of
 "What the molarity of a polymer is per, from its grade key and its aliases (all
 lower-case): \"per monomer unit\" for dextran, amphipol, PVP and PVA, \"per 1000 Da\"
 for Ficoll, nil (per mole of chains) for the rest."
 [target aliases]
 (some (fn [[rx text]] (when (some #(re-find rx %) (cons target aliases)) text))
  basis-rules))

(defn ^:private read-json
 [& parts]
 (json/parse-string (c/slurp8 (apply c/in-root (concat bde parts)))))

(defn ^:private lower [s] (str/lower-case s))

(defn kind-table
 "One kind's names and targets from its alias table `lookup` (alias -> target) and its
 value table `values` (target -> row), all keys lower-cased: {:targets [sorted keys]
 :names [[name target-position] ...] :dropped n}. The keys of the value table are names
 of their own. Aliases whose target is not in `values` are dropped and counted. A name
 in `reserved` (a set) is left out."
 [lookup values reserved]
 (let [targets (vec (sort (map lower (keys values))))
   pos (zipmap targets (range))
   pairs (concat (map (fn [t] [t t]) targets)
    (map (fn [[a t]] [(lower a) (lower t)]) lookup))
   kept (filter (fn [[_ t]] (contains? pos t)) pairs)
   names (->> kept
    (remove (fn [[n _]] (contains? reserved n)))
    (map (fn [[n t]] [n (pos t)]))
    distinct
    (sort-by first))]
  {:targets targets,
   :names (vec names),
   :dropped (- (count (distinct pairs)) (count (distinct kept)))}))

(defn polymer-bases
 "{target basis} for the polymer targets of `lookup` and `values` that have one."
 [lookup values]
 (let [aliases (reduce (fn [m [a t]] (update m (lower t) (fnil conj []) (lower a)))
    {}
    lookup)]
  (into (sorted-map)
   (keep (fn [t] (when-let [b (basis-of t (get aliases t))] [t b])))
   (map lower (keys values)))))

(defn pieces
 "A name for the file: the string itself when it is short, else a vector of strings of
 at most `piece-length` characters whose concatenation is the name."
 [s]
 (if (<= (count s) piece-length) s (mapv str/join (partition-all piece-length s))))

(defn index
 "The index as data from the four tables (parsed JSON maps) and the families (the
 vector of polymer_families.edn)."
 [nb-lookup nb-values pol-lookup pol-values families]
 (let [fam-names (into (sorted-map)
    (for [{:keys [id names]} families
      n names]
     [(lower n) id]))
   nb (kind-table nb-lookup nb-values #{})
   pol (kind-table pol-lookup pol-values (set (keys fam-names)))]
  {:nonbiological (select-keys nb [:targets :names]),
   :polymers (assoc (select-keys pol [:targets :names])
    :basis
    (polymer-bases pol-lookup pol-values)),
   :families (vec fam-names),
   :dropped (:dropped nb)}))

(defn render
 "The text of the file for the index `idx` (before the formatter): the header comment,
 then the data, one name to a line."
 [idx]
 (let [line (fn [[n i]] (str "   [" (pr-str (pieces n)) " " i "]"))
   vec-of (fn [indent xs f]
    (str "[" (str/join (str "\n" indent) (map f xs)) "]"))
   targets (fn [ts] (vec-of "    " ts #(pr-str (pieces %))))]
  (str
   ";; SPDX-License-Identifier: LGPL-3.0-or-later\n\n"
   ";; Written by `bb harvest-solutes`, do not edit: every name the buffer page may be\n"
   ";; given and what it stands for. Per kind, `:targets` are the canonical names (the\n"
   ";; `:arg` of a buffer row: the lower-case IUPAC name of a non-biological solute, the\n"
   ";; grade of a polymer) and `:names` the typed names, each with the position of its\n"
   ";; target; a name or target too long for a line is a vector of pieces to join.\n"
   ";; `:basis` maps a polymer target to what its molarity is per (absent: per mole of\n"
   ";; chains); `:families` pairs a family name with the id of polymer_families.edn.\n\n"
   "{:nonbiological {:targets "
   (targets (get-in idx [:nonbiological :targets]))
   ",\n  :names ["
   (str/join "\n" (map line (get-in idx [:nonbiological :names])))
   "]},\n :polymers {:targets "
   (targets (get-in idx [:polymers :targets]))
   ",\n  :basis "
   (pr-str (get-in idx [:polymers :basis]))
   ",\n  :names ["
   (str/join "\n" (map line (get-in idx [:polymers :names])))
   "]},\n :families "
   (pr-str (:families idx))
   "}\n")))

(defn build-text
 "The unformatted file text from the repository's tables."
 []
 (let [idx (index (read-json "NonBiological" "nonbio_lookup.json")
    (read-json "NonBiological" "nonbiological.json")
    (read-json "Polymers" "polymers_lookup.json")
    (read-json "Polymers" "polymers.json")
    (edn/read-string (c/slurp8 families-file)))]
  (when (pos? (:dropped idx))
   (println
    (str who ": " (:dropped idx) " alias(es) left out: target not in the table")))
  (render idx)))

(defn ^:private sha256
 "The hex SHA-256 of the text `s`."
 [s]
 (let [md (java.security.MessageDigest/getInstance "SHA-256")]
  (apply str
   (map #(format "%02x" (bit-and % 0xff))
    (.digest md (.getBytes ^String s "UTF-8"))))))

(def ^:private cache-dir (c/in-root "_cache" "harvest-solutes"))

(defn ^:private write-formatted!
 "Writes the formatted index to `path`; true on success. zprint needs a couple of
 minutes for the 16 000 lines under Babashka, so the formatted text of an unformatted
 text is remembered in `_cache/harvest-solutes/` (gitignored), keyed by the hash of the
 latter: a run on unchanged tables takes a moment."
 [path]
 (let [text (build-text)
   cached (fs/path cache-dir (sha256 text))]
  (if (fs/exists? cached)
   (do (c/spit8 path (c/slurp8 cached)) true)
   (do (c/spit8 path text)
    (when (c/sh false "bb" (c/in-root "dev" "format.clj") "--apply" path)
     (fs/create-dirs cache-dir)
     (c/spit8 cached (c/slurp8 path))
     true)))))

(defn run
 "The tool's main program for the argument list `argv`; returns the exit status."
 [argv]
 (if (some #{"--help" "-h"} argv)
  (c/usage)
  (let [unknown (first (remove #{"--check"} argv))]
   (when unknown
    (c/fail who (str "unknown option " unknown " (the only one is --check)")))
   (if (some #{"--check"} argv)
    (let [scratch (c/in-root "tui" "resources" "solute_index.check.edn")]
     (try
      (cond (not (write-formatted! scratch)) 1
       (= (c/slurp8 scratch) (when (fs/exists? out-file) (c/slurp8 out-file)))
       (do (println (str who ": the solute index is up to date")) 0)
       :else (do (println (str who ": solute_index.edn is out of date")) 1))
      (finally (fs/delete-if-exists scratch))))
    (if (write-formatted! out-file)
     (do (println (str who ": wrote " out-file)) 0)
     1)))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
 (c/main run *command-line-args*))
