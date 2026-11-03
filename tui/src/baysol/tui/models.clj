;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The models of a project: the structure files (`.cif` or `.pdb`) in its `models/`
;; folder. A model is always a COPY of the file the user named, never the file itself, so
;; adding one cannot lose anything; the only way a model leaves the folder is
;; `delete-model!`, which the screen asks twice for. A project with no `models/` folder,
;; or an empty one, or one whose files were all deleted, has no models: nothing here tells
;; these apart (`list-models` is empty for all three, and the folder is never removed).
;;
;; `hints` and `complete` are the autocompletion of a typed path.

(ns baysol.tui.models
 (:require [clojure.java.io :as io]
  [clojure.string :as str])
 (:import (java.io File)
  (java.nio.file Files StandardCopyOption)))

(def extensions
 "The file extensions a model may have, lower case."
 #{"cif" "pdb"})

(def ^:private max-hints
 "The most hints `hints` gives."
 50)

(defn models-dir
 "The `models/` folder (a File) of the project `project-dir`; it may not exist yet."
 [project-dir]
 (io/file project-dir "models"))

(defn accepted?
 "Whether the file name `file-name` has an extension a model may have (case does not
 matter)."
 [file-name]
 (let [dot (str/last-index-of file-name ".")]
  (boolean
   (and dot (contains? extensions (str/lower-case (subs file-name (inc dot))))))))

(defn list-models
 "The names of the models of the project `project-dir`, sorted without regard to case:
 the `.cif` and `.pdb` files in its `models/` folder. An empty vector when there are none,
 whether the folder is missing, empty or emptied."
 [project-dir]
 (->> (some->> (.listFiles (models-dir project-dir))
   (filter #(.isFile ^File %))
   (map #(.getName ^File %))
   (filter accepted?))
  (sort-by str/lower-case)
  vec))

(defn path-problem
 "What is wrong with `path` as the file to add as a model, as a short message (42
 characters at most), or nil if it is fine: it must be a full absolute path of a readable
 `.cif` or `.pdb` file whose name no model has yet (case does not matter). `existing` is
 the names of the models there are. The checks run in this order: empty, not absolute, not
 there, a folder, the wrong kind of file, not readable, name taken."
 [path existing]
 (let [file (io/file path)
   lower (str/lower-case (.getName file))]
  (cond (str/blank? path) "type a path first!"
   (not (.isAbsolute file)) "use a full absolute path"
   (not (.exists file)) "no such file"
   (.isDirectory file) "that is a folder, not a file"
   (not (accepted? (.getName file))) "only .cif and .pdb files"
   (not (.canRead file)) "cannot read that file"
   (some #(= lower (str/lower-case %)) existing)
   "a model with that name exists"
   :else nil)))

(defn add-model!
 "Copies the file at `path` into the `models/` folder of the project `project-dir`, made
 if need be, under the same name, and returns the copy (a File). The original is not
 touched, and a model that is there is never overwritten.

 Throws an exception (the file system's) if the copy cannot be made, a model of that name
 being there included; nothing is deleted then."
 [project-dir path]
 (let [source (io/file path)
   dir (models-dir project-dir)
   target (io/file dir (.getName source))]
  (.mkdirs dir)
  (Files/copy (.toPath source) (.toPath target) (into-array StandardCopyOption []))
  target))

(defn add-models!
 "Adds each of the files `paths` as `add-model!` does, the ones that fail `path-problem`
 (or whose copy fails) left out: a name that comes twice in `paths` is added once. Returns
 `{:copied [model name ...] :skipped [[path reason] ...]}`; nothing here throws."
 [project-dir paths]
 (reduce (fn [result path]
   (let [existing (into (list-models project-dir) (:copied result))
     problem (path-problem path existing)
     failed? (and (nil? problem)
      (try (add-model! project-dir path)
       false
       (catch Exception _ true)))
     reason (or problem (when failed? "could not copy the file!"))]
    (if reason
     (update result :skipped conj [path reason])
     (update result :copied conj (.getName (io/file path))))))
  {:copied [], :skipped []}
  paths))

(defn delete-model!
 "Deletes the model `model-name` from the `models/` folder of the project `project-dir`.
 This is destructive and there is no way back, so only a file that `list-models` lists is
 deleted, by its plain name (a name with a path in it is refused). Returns true if the
 file was deleted."
 [project-dir model-name]
 (boolean (when (some #{model-name} (list-models project-dir))
   (.delete (io/file (models-dir project-dir) model-name)))))

;; --- autocompletion of a typed path

(defn dir-part
 "The part of the typed path `text` up to and with its last separator (`/`, and the
 system's own); \"\" when there is none."
 [text]
 (let [cut (max (or (str/last-index-of text "/") -1)
    (or (str/last-index-of text File/separator) -1))]
  (if (neg? cut) "" (subs text 0 (inc cut)))))

(defn hints-for
 "The names that the typed path `text` can go on with, for the folder it is in: folders
 (with a `/` at the end) first, then the files whose name `accept?` takes, those that
 start with what is typed after the last separator (case does not matter). A name that
 starts with a dot is given only when a dot is typed. Empty when `text` is not an absolute
 path in a folder that exists. At most 50."
 [text accept?]
 (let [dir (dir-part text)
   prefix (str/lower-case (subs text (count dir)))
   folder (io/file dir)]
  (if (or (str/blank? dir) (not (.isAbsolute folder)) (not (.isDirectory folder)))
   []
   (->> (some->> (.listFiles folder)
     (filter (fn [^File f]
       (let [n (.getName f)]
        (and (str/starts-with? (str/lower-case n) prefix)
         (or (str/starts-with? prefix ".")
          (not (str/starts-with? n ".")))
         (or (.isDirectory f) (accept? n))))))
     (map (fn [^File f] [(not (.isDirectory f))
        (str (.getName f)
         (when (.isDirectory f) "/"))])))
    (sort-by (fn [[file? n]] [file? (str/lower-case n)]))
    (map second)
    (take max-hints)
    vec))))

(defn hints
 "The hints of [[hints-for]] for `.cif` and `.pdb` files."
 [text]
 (hints-for text accepted?))

(defn complete
 "The typed path `text` with its last part replaced by `hint`, one of `hints`."
 [text hint]
 (str (dir-part text) hint))
