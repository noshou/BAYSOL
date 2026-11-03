;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The record of a run: what goes where, that nothing is overwritten, and what a failed run
;; leaves.

(ns baysol.tui.runs-test
 (:require [baysol.tui.projects :as projects]
  [baysol.tui.runs :as runs]
  [baysol.tui.support :as support]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.test :refer [deftest is testing]])
 (:import (java.time Instant)))

(defn ^:private names
 [^java.io.File dir]
 (set (map #(.getName ^java.io.File %) (.listFiles dir))))

(deftest stamps
 (is (= "20261102T153045123Z"
   (runs/stamp (Instant/parse "2026-11-02T15:30:45.123Z"))))
 (is (not (re-find #"[:/\\]" (runs/stamp (Instant/now))))))

(deftest a-run-is-recorded
 (support/with-data-folder
  [root (support/temp-root)]
  (let [dir (projects/create! root "demo")
    out (support/temp-root)
    _ (spit (io/file out "m1.xlsx") "x")
    _ (spit (io/file out "m1.txt") "plot")
    _ (io/make-parents (io/file out "plots" "m1.tex"))
    _ (spit (io/file out "plots" "m1.tex") "tex")
    log (io/file (support/temp-root) "demo.LOG")]
   (testing "a new project has no logs/ or data/, so no runs"
    (is (not (.exists (io/file dir "logs"))))
    (is (not (runs/runs? dir "logs")))
    (is (not (runs/runs? dir "data"))))
   (testing "a successful run fills logs/<time> and data/<time>"
    (spit log "log")
    (let [{:keys [id logs data]} (runs/record-run!
       dir
       {:models ["m1"], :log-file log, :output-dir out})]
     (is (= #{"models.edn" "settings.edn" "demo.LOG"} (names logs)))
     (is (= ["m1"] (edn/read-string (slurp (io/file logs "models.edn")))))
     (is (= (slurp (io/file dir "settings.edn"))
       (slurp (io/file logs "settings.edn"))))
     (is (= #{"m1.xlsx" "m1.txt" "plots"} (names data)))
     (is (.isFile (io/file data "plots" "m1.tex")))
     (is (= [id] (runs/run-ids dir "logs") (runs/run-ids dir "data")))))
   (testing "a failed run leaves a log record and no data"
    (let [{:keys [id data]} (runs/record-run! dir {:models ["m1"], :log-file log})]
     (is (nil? data))
     (is (= 2 (count (runs/run-ids dir "logs"))))
     (is (= 1 (count (runs/run-ids dir "data"))))
     (is (not (some #{id} (runs/run-ids dir "data"))))))
   (testing "runs in quick succession never share or overwrite a folder"
    (dotimes [_ 5] (runs/record-run! dir {:models []}))
    (is (= 7 (count (set (runs/run-ids dir "logs")))))))))
