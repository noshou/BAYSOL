;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The projects: one folder for each in the `projects` folder of the BAYSOL folder, named
;; by its id (the name the user typed). A folder is a project when it has a `project.edn`
;; that says so (`{:id "name" :created "<time>"}` with the id of the folder's own name);
;; any other folder or file there is not one and is left alone, but its name is taken.
;;
;; A new project gets an exact copy of the global `settings.edn` as its own, which is its
;; starting point; what it changes after that is the project's alone
;; (`baysol.tui.settings/load-project!`).
;;
;; A name must be new in the folder, without regard to case (a file system that does not
;; tell `Run` from `run` would not keep two apart), and a name that every system accepts:
;; letters, digits, `.`, `_` and `-`, starting with a letter or a digit, not ending in `.`,
;; at most 40 characters, and not a name a Windows device has (`con`, `nul`, `com1`, ...).

(ns baysol.tui.projects
 (:require [baysol.tui.core.app :as app]
  [baysol.tui.edn-store :as store]
  [baysol.tui.settings :as settings]
  [baysol.tui.text :as txt]
  [clojure.java.io :as io]
  [clojure.string :as str])
 (:import (java.time Instant)))

(def max-name
 "The most characters a project name may have."
 40)

(def ^:private reserved
 "Names a Windows file system keeps for devices, whatever the extension."
 (into #{"con" "prn" "aux" "nul"}
  (concat (map #(str "com" %) (range 1 10))
   (map #(str "lpt" %) (range 1 10)))))

(defn name-problem
 "What is wrong with `id` as the name of a new project, as a short message (the main
 menu has room for 29 characters; the one for a broken folder is longer and the menu
 makes room), or nil if it is fine. `existing` is
 every name already in the projects folder. The checks run in this order: empty, too long,
 characters, a trailing dot, a reserved name, a name taken. `broken` (optional, see
 [[broken-names]]) are the names of folders that have a `project.edn` that cannot be used:
 a name among them says so, as it is neither listed nor free."
 ([id existing] (name-problem id existing []))
 ([id existing broken]
  (let [lower (str/lower-case id)
    same? (fn [names] (some #(= lower (str/lower-case %)) names))]
   (cond (str/blank? id) "type a name first!"
    (> (count id) max-name) (txt/too-long "name" max-name)
    (not (re-matches #"[A-Za-z0-9._-]+" id)) "use only a-z 0-9 . _ -"
    (not (re-matches #"[A-Za-z0-9].*" id)) "start with a letter or digit"
    (str/ends-with? id ".") "must not end with a dot"
    (contains? reserved (first (str/split lower #"\.")))
    "reserved name, pick another"
    (same? broken) "that name is taken by a broken project folder!"
    (same? existing) "that project already exists!"
    :else nil))))

(defn project-dir
 "The folder (a File) of the project `id` in the projects folder `projects-root`."
 [projects-root id]
 (io/file projects-root id))

(defn read-project
 "The `project.edn` of the project folder `dir` as a map, or nil if `dir` is not a project:
 no such file, text that is not EDN, not a map, or an `:id` that is not the folder's name."
 [^java.io.File dir]
 (let [file (io/file dir "project.edn")]
  (when (.isFile file)
   (let [project (store/read-edn file nil)]
    (when (and (map? project) (= (:id project) (.getName dir))) project)))))

(defn entry-names
 "The names of everything in the projects folder `projects-root` (an empty list when there
 is no such folder), projects or not."
 [projects-root]
 (vec (some->> (.listFiles (io/file projects-root))
   (map #(.getName ^java.io.File %)))))

(defn broken-names
 "The names of the folders of the projects folder `projects-root` that have a `project.edn`
 that cannot be used (see [[read-project]]): [[list-projects]] hides them, but their names
 are taken.

 # Returns
 A vector of names.

 # Exceptions
 None."
 [projects-root]
 (vec (some->> (.listFiles (io/file projects-root))
   (filter #(.isDirectory ^java.io.File %))
   (filter #(.isFile (io/file ^java.io.File % "project.edn")))
   (remove read-project)
   (map #(.getName ^java.io.File %)))))

(defn list-projects
 "The ids of the projects in the projects folder `projects-root`, sorted without regard to
 case; an empty vector if there is none."
 [projects-root]
 (->> (some->> (.listFiles (io/file projects-root))
   (filter #(.isDirectory ^java.io.File %)))
  (filter read-project)
  (map #(.getName ^java.io.File %))
  (sort-by str/lower-case)
  vec))

(defn ^:private delete-tree!
 "Deletes the folder `dir` and everything in it."
 [^java.io.File dir]
 (doseq [^java.io.File f (reverse (file-seq dir))] (.delete f)))

(defn create!
 "Makes the project `id` in the BAYSOL folder `app-root`: its folder, its `project.edn` and
 an exact copy of the global `settings.edn` (which is made and checked first, `load!`).
 Returns the project's folder (a File).

 Throws an exception (`:type ::invalid-name`, with `:reason`, the message `name-problem`
 gives) if the name is not valid or is taken, and any exception that making the global
 settings throws; a project that was half made is removed again."
 [app-root id]
 (let [projects (app/projects-root app-root)
   _ (app/ensure-dir! projects)
   problem (name-problem id (entry-names projects) (broken-names projects))
   _ (when problem
    (throw (ex-info problem {:type ::invalid-name, :reason problem, :id id})))
   dir (project-dir projects id)]
  (settings/load! app-root)
  (when-not (.mkdir dir)
   (throw (ex-info
     "that project already exists!"
     {:type ::invalid-name, :reason "that project already exists!", :id id})))

  ; copy over the project
  (try (spit (io/file dir "project.edn")
    (pr-str {:id id, :created (str (Instant/now))})
    :encoding
    "UTF-8")
   (store/copy-over! (settings/settings-file app-root)
    (settings/settings-file dir))
   dir
   (catch Exception e (delete-tree! dir) (throw e)))))
