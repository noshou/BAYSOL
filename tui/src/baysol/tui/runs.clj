;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The record of the runs of a project. Nothing here is ever deleted: a run adds a folder
;; named by its exact time (UTC) to `logs/` and, if it succeeded, one to `data/`, and the
;; two have the same name, so a log and its data belong together.
;;
;;   <project>/logs/<time>/models.edn    the names of the models of the run
;;                         settings.edn  the project's settings as they were (to restore
;;                                       by hand)
;;                         <name>.LOG    the run's log
;;   <project>/data/<time>/...           everything the run wrote: the workbook of each
;;                                       model, its plots (rendered or not) and its
;;                                       unicode plots
;;
;; `logs/` and `data/` are not made by the user or by a new project: a run makes them, a
;; failed one only `logs/`. Until then the project has no runs, which is `runs?`.

(ns baysol.tui.runs
 (:require [baysol.tui.settings :as settings]
  [clojure.java.io :as io])
 (:import (java.nio.file Files StandardCopyOption)
  (java.time Instant ZoneOffset)
  (java.time.format DateTimeFormatter)))

(def ^:private stamp-format
 "A time that sorts as text, and that every file system accepts (no colon)."
 (-> (DateTimeFormatter/ofPattern "yyyyMMdd'T'HHmmssSSS'Z'")
  (.withZone ZoneOffset/UTC)))

(defn stamp
 "The name of a run started at `instant`, such as `20261102T153045123Z`."
 [^Instant instant]
 (.format ^DateTimeFormatter stamp-format instant))

(defn run-ids
 "The names of the runs in the folder `kind` (`\"logs\"` or `\"data\"`) of the project
 `project-dir`, oldest first; an empty vector if the folder is not there."
 [^java.io.File project-dir kind]
 (->> (some->> (.listFiles (io/file project-dir kind))
   (filter #(.isDirectory ^java.io.File %))
   (map #(.getName ^java.io.File %)))
  sort
  vec))

(defn runs?
 "Whether the project `project-dir` has a run to show in its folder `kind`."
 [project-dir kind]
 (boolean (seq (run-ids project-dir kind))))

(defn ^:private new-run-dirs!
 "Makes the folder of a new run under `logs` and, with `with-data?`, under `data`, both
 named by the current time. A name already taken (two runs in the same millisecond) is
 never reused: it waits for the next. Returns `{:id :logs :data}`."
 [project-dir with-data?]
 (loop []
  (let [id (stamp (Instant/now))
    logs (io/file project-dir "logs" id)
    data (io/file project-dir "data" id)]
   (io/make-parents logs)
   (when with-data? (io/make-parents data))
   (if (and (.mkdir logs) (or (not with-data?) (.mkdir data)))
    {:id id, :logs logs, :data (when with-data? data)}
    (do (Thread/sleep 1) (recur))))))

(defn ^:private copy!
 "Copies the file `from` to `to`, never over a file that is there."
 [^java.io.File from ^java.io.File to]
 (Files/copy (.toPath from) (.toPath to) (into-array StandardCopyOption [])))

(defn ^:private copy-tree!
 "Copies everything under the folder `from` into the folder `to`."
 [^java.io.File from ^java.io.File to]
 (let [base (.toPath from)]
  (doseq [^java.io.File f (file-seq from)
    :when (.isFile f)
    :let [target (io/file to (str (.relativize base (.toPath f))))]]
   (io/make-parents target)
   (copy! f target))))

(defn record-run!
 "Records a run of the project `project-dir`. `models` is the names of its models,
 `log-file` its log (a File, or nil for none) and `output-dir` the folder the run wrote
 its results to (a File), nil if the run failed: a failed run leaves its record in `logs/`
 only. The project's settings are copied as they are now.

 Returns `{:id :logs :data}`, the run's name and its folders (`:data` is nil for a failed
 run). Nothing is deleted if something goes wrong halfway: what was written stays."
 [project-dir {:keys [models log-file output-dir]}]
 (let [{:keys [logs data], :as run} (new-run-dirs! project-dir (some? output-dir))]
  (spit (io/file logs "models.edn") (pr-str (vec models)) :encoding "UTF-8")
  (copy! (settings/settings-file project-dir) (settings/settings-file logs))
  (when log-file
   (copy! (io/file log-file) (io/file logs (.getName (io/file log-file)))))
  (when output-dir (copy-tree! (io/file output-dir) data))
  run))
