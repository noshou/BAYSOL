#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Extract data from xraydb.sqlite into one compact db.
;;
;;     bb extract-formfactor \
;;         xraydb.sqlite src/Scattering/form_factors.sqlite3
;;
;; Source: xraydb 4.5.8's xraydb.sqlite. Its LICENSE places
;; xraydb.sqlite and data_sources/ in the public domain via CC0 1.0.
;;     - Waasmaier & Kirfel (1995) Acta Cryst A51, 416   -> f0 Gaussian coefficients
;;     - Chantler FFAST (NIST, fine grid)                -> f1/f2 anomalous terms
;; Energy/f1/f2 are stored as little-endian Float64 BLOBs.
;;
;; Offline script, not runtime code. Needs Babashka; SQLite comes from the
;; `org.babashka/go-sqlite3` pod (fetched on first use).
;;
;; The output was checked against the bundled form_factors.sqlite3: the same schema text,
;; and every row equal cell for cell (floats compared by their bits, through JDBC, not
;; through a text dump). Two limits of the pod, neither reached by this data: it reads a
;; REAL back through a short text form (exact for decimals of a few digits like these,
;; not for arbitrary doubles) and stores -0.0 as 0.0.

(ns extract-formfactor
 (:require [babashka.classpath :refer [add-classpath]]
  [babashka.fs :as fs]
  [babashka.pods :as pods]
  [clojure.string :as str])
 (:import (java.nio ByteBuffer ByteOrder)))

(add-classpath (str (fs/parent (fs/absolutize *file*))))

(require '[common :as c])

(def ^:private who "bb extract-formfactor")

;; The SQLite pod is started on first use, so that loading this namespace (for its
;; helpers) starts nothing.
(defonce ^:private pod (delay (pods/load-pod 'org.babashka/go-sqlite3 "0.3.13")))

(defn ^:private query
 "The rows of a SELECT, as maps."
 [db sql-params]
 @pod
 ((requiring-resolve 'pod.babashka.go-sqlite3/query) db sql-params))

(defn ^:private execute!
 "Runs one statement with its parameters."
 [db sql-params]
 @pod
 ((requiring-resolve 'pod.babashka.go-sqlite3/execute!) db sql-params))

;; --- helpers

(defn numbers
 "The numbers of a JSON array of plain numbers (\"[1, 2.5, 3e-4]\") as a vector of
 doubles. Anything else in it is an error. Each is parsed by Java's correctly rounded
 parser and bound to SQLite as a real, so no digits are lost on the way."
 [json what]
 (vec (for [tok (str/split (str/replace json #"^[\[\]\s]+|[\[\]\s]+$" "") #",")
    :let [tok (str/trim tok)]]
   (if (re-matches #"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?" tok)
    (parse-double tok)
    (throw (ex-info (str what ": '" tok "' is not a number") {}))))))

(defn blob
 "A sequence of doubles as the bytes of a little-endian Float64 array (bound to
 SQLite as a BLOB)."
 [xs]
 (let [buf (-> (ByteBuffer/allocate (* 8 (count xs)))
    (.order ByteOrder/LITTLE_ENDIAN))]
  (run! #(.putDouble buf (double %)) xs)
  (.array buf)))

;; The schema, one statement per element and written out verbatim (not indented or
;; reformatted): the DDL text is stored in sqlite_master, and the bundled database has
;; this exact text.
(def ^:private schema
 [(str
   "CREATE TABLE waasmaier (
    ion     TEXT PRIMARY KEY,
    element TEXT NOT NULL,
    z       INTEGER NOT NULL,
    c       REAL NOT NULL,
    a1 REAL NOT NULL, a2 REAL NOT NULL, a3 REAL NOT NULL, a4 REAL NOT NULL, "
   "a5 REAL NOT NULL,
    b1 REAL NOT NULL, b2 REAL NOT NULL, b3 REAL NOT NULL, b4 REAL NOT NULL, b5 REAL NOT NULL
)")
  "CREATE INDEX idx_waasmaier_element ON waasmaier(element)"
  "CREATE TABLE chantler (
    element TEXT PRIMARY KEY,
    z       INTEGER NOT NULL,
    npts    INTEGER NOT NULL,
    emin    REAL NOT NULL,
    emax    REAL NOT NULL,
    energy  BLOB NOT NULL,
    f1      BLOB NOT NULL,
    f2      BLOB NOT NULL
)"
  "CREATE TABLE provenance (key TEXT PRIMARY KEY, value TEXT NOT NULL)"])

;; Where the data came from, in the provenance table. The f0_form text is plain ASCII
;; (`<=`), as in the bundled database.
(def ^:private provenance
 [["f0_source"
   (str "Waasmaier & Kirfel (1995) Acta Cryst A51, 416-431; "
    "doi:10.1107/S0108767394013292")]
  ["f0_form"
   (str "f0(s) = c + sum_{i=1..5} a_i*exp(-b_i*s^2), s = q/(4*pi) [1/Ang], "
    "valid 0 <= s <= 6")]
  ["anomalous_source"
   (str "Chantler FFAST (NIST), fine grid; J. Phys. Chem. Ref. Data 24 "
    "71 (1995), 29 597 (2000)")]
  ["anomalous_form"
   (str "f1 stored as f1_FFAST - Z + f_rel(3/5 CL) + f_NT (xraydb "
    "convention); f = f0 + f1 + i*f2")]
  ["extracted_from" "xraydb 4.5.8 xraydb.sqlite"]
  ["license"
   (str "CC0 1.0 - xraydb LICENSE dedicates xraydb.sqlite and data_sources/ to "
    "the public domain")]])

;; --- the two tables

(defn ^:private add-waasmaier!
 "Copies the Waasmaier-Kirfel f0 coefficients: one row per ion, the offset c, five
 Gaussian amplitudes a1..a5 and five exponents b1..b5 (the source keeps the two
 five-element lists as JSON text). Returns the number of rows."
 [src dst]
 (let [rows (query src
    [(str
      "SELECT atomic_number, element, ion, offset, scale, exponents "
      "FROM Waasmaier")])]
  (doseq [{:keys [atomic_number element ion offset scale exponents]} rows
    :let [a (numbers scale (str "Waasmaier " ion " scale"))
     b (numbers exponents (str "Waasmaier " ion " exponents"))]]
   (when-not (and (= 5 (count a)) (= 5 (count b)))
    (throw (ex-info (str "Waasmaier "
       ion
       ": expected 5 amplitudes and 5 "
       "exponents, got " (count a)
       " and " (count b))
      {})))
   (execute! dst
    (into [(str "INSERT INTO waasmaier VALUES "
       "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
      (str/lower-case ion) (str/lower-case element) atomic_number
      offset]
     (concat a b))))
  (count rows)))

(defn ^:private dedupe-grid
 "The indices of the grid points to keep: the first, then each point above the last
 one kept. Cs has duplicate grid energies upstream, which makes the s=0 spline throw;
 dropping them (keeping the first) makes the grid strictly increasing for every
 element."
 [energies]
 (loop [i 1
   last-e (first energies)
   kept [0]]
  (cond (>= i (count energies)) kept
   (> (energies i) last-e) (recur (inc i) (energies i) (conj kept i))
   :else (recur (inc i) last-e kept))))

(defn ^:private add-chantler!
 "Copies the Chantler FFAST anomalous terms: one row per element, the energy grid and
 f1, f2 on it, packed as Float64 blobs. A missing atomic number is an error (LEFT
 JOIN, then checked) rather than a silently dropped element. Returns [elements
 grid-points]."
 [src dst]
 (let [rows (query
    src
    [(str
      "SELECT c.element AS element, c.energy AS energy, c.f1 AS f1, "
      "c.f2 AS f2, e.atomic_number AS z "
      "FROM Chantler c LEFT JOIN elements e ON e.element = c.element")])
   npts (for [{:keys [element energy f1 f2 z]} rows]
    (let [_ (when (nil? z)
       (throw (ex-info (str "Chantler " element
          " has no atomic number in "
          "the elements table")
         {})))
      e (numbers energy (str "Chantler " element " energy"))
      y1 (numbers f1 (str "Chantler " element " f1"))
      y2 (numbers f2 (str "Chantler " element " f2"))
      _ (when-not (= (count e) (count y1) (count y2))
       (throw (ex-info (str "Chantler "
          element
          ": grid lengths differ ("
          (count e)
          ", "
          (count y1)
          ", "
          (count y2)
          ")")
         {})))
      kept (dedupe-grid e)
      [e y1 y2] (map #(mapv % kept) [e y1 y2])]
     (when (not= (count kept) (count (numbers energy "")))
      (println (str "  deduped "
        element
        ": "
        (count (numbers energy ""))
        " -> "
        (count kept)
        " points")))
     (execute! dst
      ["INSERT INTO chantler VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
       (str/lower-case element) z (count e) (first e) (last e)
       (blob e) (blob y1) (blob y2)])
     (count e)))]
  [(count npts) (reduce + npts)]))

(defn ^:private add-deuterium!
 "Adds deuterium `d` as a copy of hydrogen `h` in both tables. X-ray scattering
 depends on the electron cloud only, and 2H has the same one as 1H, so f0, f' and
 f'' are identical (the nucleus differs, which matters for neutrons, not here)."
 [dst]
 (execute! dst
  [(str "INSERT INTO waasmaier SELECT 'd', 'd', z, c, a1, a2, a3, a4, a5, "
    "b1, b2, b3, b4, b5 FROM waasmaier WHERE ion = 'h'")])
 (execute! dst
  [(str
    "INSERT INTO chantler SELECT 'd', z, npts, emin, emax, energy, f1, f2 "
    "FROM chantler WHERE element = 'h'")])
 (execute!
  dst
  ["INSERT INTO provenance VALUES (?, ?)" "deuterium"
   "d is a copy of h: same electron cloud, hence the same f0, f1, f2 for X-rays"]))

(defn build
 "Reads the source database `src` and writes the compact database `dst` (which must
 not exist)."
 [src dst]
 (run! #(execute! dst [%]) schema)
 (let [n-w (add-waasmaier! src dst)
   [n-c tot] (add-chantler! src dst)]
  (doseq [[k v] provenance]
   (execute! dst ["INSERT INTO provenance VALUES (?, ?)" k v]))
  (add-deuterium! dst)
  ;; VACUUM packs the file
  (execute! dst ["VACUUM"])
  (println (format "waasmaier: %d species, chantler: %d elements / %d grid points"
    n-w
    n-c
    tot))))

(defn run
 "The tool's main program for the argument list `argv`; returns the exit status.
 Builds the database in a temporary file next to the destination and renames it over
 the destination only when it is complete, so a failure midway leaves any existing
 destination untouched and no partial file behind."
 [argv]
 (if (some #{"--help" "-h"} argv)
  (c/usage)
  (let [[src dst] argv]
   (cond (nil? dst)
    (do (binding [*out* *err*]
      (println (str "usage: " who " xraydb.sqlite form_factors.sqlite3")))
     2)
    (not (fs/regular-file? src))
    (do (binding [*out* *err*] (println (str "no such file: " src))) 1)
    :else (let [part (str dst ".part")]
     (fs/delete-if-exists part)
     (try (build src part)
      (fs/move part dst {:replace-existing true})
      (println (str "size: " (fs/size dst) " bytes"))
      (finally (fs/delete-if-exists part))))))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
 (c/main run *command-line-args*))
