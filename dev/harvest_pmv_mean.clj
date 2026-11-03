#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Keeps the one number the Julia package and the terminal interface share for "an
;; uncertainty nobody stated": the mean of every stated uncertainty of
;; src/BulkElectronDensity/NonBiological/nonbiological.json, rounded to six decimals, as the
;; literal of `NONBIO_MEAN_UNCERTAINTY` in src/BulkElectronDensity/BulkElectronDensity.jl.
;;
;;     bb harvest-pmv-mean [--check]
;;
;;   (no option)  recomputes the mean from the JSON (the rows whose uncertainty is not
;;                null, in cm3/mol) and rewrites the line between the markers
;;                `# BEGIN harvested: nonbio-mean-uncertainty` and
;;                `# END harvested: nonbio-mean-uncertainty` of the module file; a second
;;                run changes nothing
;;   --check      changes nothing: exits 1 when the literal differs from the mean, that
;;                is, when it is out of date
;;
;; `bb precommit` runs the first form, so a changed literal belongs to the commit. The
;; unit suite compares the constant with the JSON as well, so a stale one fails there
;; even when the harvest was not run.

(ns harvest-pmv-mean
 (:require [babashka.classpath :refer [add-classpath]]
  [babashka.fs :as fs]
  [cheshire.core :as json]
  [clojure.string :as str]))

(add-classpath (str (fs/parent (fs/absolutize *file*))))

(require '[common :as c])

(def ^:private who "bb harvest-pmv-mean")

(def ^:private table-path
 ["src" "BulkElectronDensity" "NonBiological" "nonbiological.json"])

(def ^:private module-path ["src" "BulkElectronDensity" "BulkElectronDensity.jl"])

(def ^:private begin-mark "# BEGIN harvested: nonbio-mean-uncertainty")

(def ^:private end-mark "# END harvested: nonbio-mean-uncertainty")

(def ^:private decimals 6)

(defn mean-uncertainty
 "The mean of the stated (not null) uncertainties of the rows of the table text `json-text`
 (a map from name to [electrons, volume, uncertainty]), rounded to six decimals."
 [json-text]
 (let [us (->> (vals (json/parse-string json-text))
    (keep #(nth % 2 nil))
    (map double))]
  (when (empty? us)
   (throw (ex-info (str who ": the table states no uncertainty") {})))
  (/ (Math/round (* (/ (reduce + 0.0 us) (count us)) (Math/pow 10 decimals)))
   (Math/pow 10 decimals))))

(defn literal-line
 "The Julia line that defines the constant as `value`."
 [value]
 (str "const NONBIO_MEAN_UNCERTAINTY = " value))

(defn replace-literal
 "The module text `text` with the line between the markers replaced by the one for
 `value`; throws when the markers are missing or do not enclose exactly one line."
 [text value]
 (let [lines (str/split text #"\n" -1)
   b (.indexOf ^java.util.List lines begin-mark)
   e (.indexOf ^java.util.List lines end-mark)]
  (when (or (neg? b) (not= e (+ b 2)))
   (throw (ex-info (str who
      ": the module file needs the line " begin-mark
      ", one line, then " end-mark)
     {})))
  (str/join "\n" (assoc lines (inc b) (literal-line value)))))

(defn run
 "The tool's main program for the argument list `argv`; returns the exit status."
 [argv]
 (if (some #{"--help" "-h"} argv)
  (c/usage)
  (let [unknown (first (remove #{"--check"} argv))
    _ (when unknown
     (c/fail who
      (str "unknown option " unknown " (the only one is --check)")))
    module (apply c/in-root module-path)
    text (c/slurp8 module)
    value (mean-uncertainty (c/slurp8 (apply c/in-root table-path)))
    fresh (replace-literal text value)
    same? (= fresh text)]
   (cond (some #{"--check"} argv)
    (if same?
     (do (println
       (str who ": NONBIO_MEAN_UNCERTAINTY = " value " is up to date"))
      0)
     (do (binding [*out* *err*]
       (println (str who
         ": NONBIO_MEAN_UNCERTAINTY in "
         module
         " is out of date (the table gives "
         value
         "); run bb harvest-pmv-mean")))
      1))
    same? (do (println (str who ": already up to date (" value ")")) 0)
    :else (do (c/spit8 module fresh)
     (println (str who ": NONBIO_MEAN_UNCERTAINTY = " value))
     0)))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
 (c/main run *command-line-args*))
