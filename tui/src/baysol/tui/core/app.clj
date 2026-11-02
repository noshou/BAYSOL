;; SPDX-License-Identifier: LGPL-3.0-or-later

;; BAYSOL itself: which release it is and where it lives. The version comes from the root
;; Project.toml; the BAYSOL folder of the user, where the program keeps what must last (the
;; BAYSOL-wide settings, the projects), lies in the place each operating system keeps the
;; data of a program, and `projects` is a folder inside it. What can be rebuilt (the font
;; list, the downloaded and generated structures) goes in the operating system's cache
;; folder instead (`cache-dir`), so that it never piles up among the user's data. The
;; folders are made the first time they are dereferenced (`app-dir`, `projects-dir`,
;; `cache-dir`).

(ns baysol.tui.core.app
 (:require [baysol.tui.core :as core]
  [clojure.java.io :as io]
  [clojure.string :as str])
 (:import (java.nio.file FileVisitResult Files LinkOption Path SimpleFileVisitor)
  (java.nio.file.attribute BasicFileAttributes)))

;; --- the version

(defn ^:private find-project-toml
 "The Project.toml of the BAYSOL package: the nearest one at or above the working
 directory that names the package BAYSOL, or nil."
 []
 (loop [dir (.getCanonicalFile (io/file "."))]
  (when dir
   (let [file (io/file dir "Project.toml")]
    (if (and (.isFile file)
      (re-find #"(?m)^name\s*=\s*\"BAYSOL\"" (slurp file :encoding "UTF-8")))
     file
     (recur (.getParentFile dir)))))))

(defn repo-root
 "The folder (a File) of the BAYSOL package the TUI runs from: the one that holds the
 Project.toml `find-project-toml` finds, or nil when there is none (a shipped program)."
 []
 (some-> (find-project-toml)
  .getParentFile))

(defn version-name
 "The release name `v<version>-<release_name>` (for example v0.4.0-yals-n-gɛsga) as the
 Project.toml of BAYSOL spells it, the one place the version is written; \"unknown\" if
 it cannot be read. (A shipped program has no Project.toml beside it and will ask the
 Julia command instead.)"
 []
 (or (when-let [file (find-project-toml)]
   (let [toml (slurp file :encoding "UTF-8")
     version (second (re-find #"(?m)^version\s*=\s*\"([^\"]*)\"" toml))
     release (second (re-find #"(?m)^release_name\s*=\s*\"([^\"]*)\"" toml))]
    (when (and version release) (str "v" version "-" release))))
  "unknown"))

;; --- the folders

(def ^:private home-var
 "The environment variable that names the BAYSOL folder instead of the default one."
 "BAYSOL_HOME")

(defn env-dir
 "The folder (a File) that the environment variable `k` of `system` names, or nil if it
 is missing, blank or not an absolute path."
 [system k]
 (let [v (str/trim (str (get (:env system) k)))]
  (when-not (str/blank? v)
   (let [dir (io/file v)] (when (.isAbsolute dir) dir)))))

(defn data-home
 "The folder (a File) in which the operating system of `system` keeps the data of a
 program:
 - Windows: %LOCALAPPDATA% (else <home>\\AppData\\Local);
 - macOS: <home>/Library/Application Support;
 - Linux and everything else (the freedesktop XDG convention, the same on every
   distribution): $XDG_DATA_HOME, with ~/.local/share as the default; a relative
   $XDG_DATA_HOME is ignored, as the specification says."
 [system]
 (let [home (:home system)]
  (cond
   (core/windows? system)
   (or (env-dir system "LOCALAPPDATA") (io/file home "AppData" "Local"))

   (core/mac? system)
   (io/file home "Library" "Application Support")

   :else
   (or (env-dir system "XDG_DATA_HOME") (io/file home ".local" "share")))))

(def ^:private cache-var
 "The environment variable that names the cache folder instead of the default one; the
 Julia side reads the same one."
 "BAYSOL_CACHE")

(defn cache-home
 "The folder (a File) in which the operating system of `system` keeps the caches of a
 program:
 - Windows: %LOCALAPPDATA% (else <home>\\AppData\\Local);
 - macOS: <home>/Library/Caches;
 - Linux and everything else: $XDG_CACHE_HOME, with ~/.cache as the default (a relative
   $XDG_CACHE_HOME is ignored)."
 [system]
 (let [home (:home system)]
  (cond
   (core/windows? system)
   (or (env-dir system "LOCALAPPDATA") (io/file home "AppData" "Local"))

   (core/mac? system)
   (io/file home "Library" "Caches")

   :else
   (or (env-dir system "XDG_CACHE_HOME") (io/file home ".cache")))))

(defn cache-root
 "The cache folder (a File): $BAYSOL_CACHE if that is set to an absolute path, otherwise
 `baysol/_cache` inside the cache home of the system (`cache-home`)."
 [system]
 (or (env-dir system cache-var) (io/file (cache-home system) "baysol" "_cache")))

(defn app-root
 "The BAYSOL folder (a File): $BAYSOL_HOME if that is set to an absolute path, otherwise
 `baysol` inside the data folder of the system (`data-home`)."
 [system]
 (or (env-dir system home-var) (io/file (data-home system) "baysol")))

(defn projects-root
 "The projects folder (a File) inside the BAYSOL folder `root`."
 [root]
 (io/file root "projects"))

(defn ensure-dir!
 "Makes the folder `dir` and any parent it lacks, and returns it. An exception that
 names the folder if that is not possible."
 [dir]
 (try
  (.mkdirs dir)
  (when-not (.isDirectory dir)
   (throw (ex-info "Failed to create directory" {:path (.getAbsolutePath dir)})))
  dir
  (catch Exception e
   (throw
    (ex-info "Could not initialize directory" {:path (.getAbsolutePath dir)} e)))))

;; The BAYSOL folder, made when this is first dereferenced.
(def app-dir (delay (ensure-dir! (app-root (core/read-system)))))

;; The projects folder, made when this is first dereferenced (the BAYSOL folder first).
(def projects-dir (delay (ensure-dir! (projects-root @app-dir))))

;; The marker file of a cache folder (the freedesktop cache directory tagging convention:
;; backup tools skip a folder that has it). `clear-cache!` empties only a folder that is
;; marked, the default one, or already empty.
(def ^:private cache-tag "CACHEDIR.TAG")

(def ^:private cache-tag-text
 (str "Signature: 8a477f597d28d172789f06886806bc55\n"
  "# This file is a cache directory tag created by BAYSOL.\n"
  "# It is safe to delete everything in this folder.\n"))

(defn tag-cache!
 "Marks the cache folder `dir` as BAYSOL's, if it is not marked yet and is either the
 default
 cache folder of `system` or empty (a folder named by BAYSOL_CACHE that already holds other
 things is never marked, so `clear-cache!` will not empty it). Returns `dir`."
 [system dir]
 (let [tag (io/file dir cache-tag)
   default? (= (.getCanonicalFile (cache-root (assoc system :env {})))
    (.getCanonicalFile dir))]
  (when (and (.isDirectory dir)
    (not (.exists tag))
    (or default? (empty? (.list dir))))
   (spit tag cache-tag-text :encoding "UTF-8"))
  dir))

;; The cache folder, made (and marked) when this is first dereferenced.
(def cache-dir
 (delay (let [system (core/read-system)]
   (tag-cache! system (ensure-dir! (cache-root system))))))

;; --- clearing the cache

(defn cache-size
 "The bytes the files under the folder `dir` (a File) take; 0 if it does not exist.
 Symbolic links count as themselves, never as what they point at."
 [dir]
 (let [total (long-array 1)]
  (when (.isDirectory dir)
   (Files/walkFileTree
    (.toPath dir)
    (proxy [SimpleFileVisitor] []
     (visitFile [_ ^BasicFileAttributes attrs]
      (aset total 0 (+ (aget total 0) (.size attrs)))
      FileVisitResult/CONTINUE))))
  (aget total 0)))

(defn ^:private refusable
 "Why the folder `dir` must not be emptied as a cache, or nil: it is a filesystem root
 or the home folder of `system` (a BAYSOL_CACHE set carelessly)."
 [system dir]
 (let [path (.toPath (.getCanonicalFile dir))
   home (some-> (:home system)
    io/file
    .getCanonicalFile
    .toPath)]
  (cond (nil? (.getParent path)) "it is a filesystem root"
   (= path home) "it is the home folder")))

(defn clear-cache!
 "Deletes everything inside the cache folder `dir` (default: `cache-dir`, for the
 system `system` default `read-system`) and keeps the folder itself, then returns the
 bytes freed (the marker stays). Symbolic links are removed, not followed. Throws
 `ex-info` and deletes
 nothing if `dir` is a filesystem root or the home folder, or if it is none of: marked as a
 cache (`CACHEDIR.TAG`), the default cache folder, empty; a missing folder frees 0."
 ([] (clear-cache! (core/read-system) @cache-dir))
 ([system dir]
  (when-let [why (and (.exists dir) (refusable system dir))]
   (throw (ex-info (str "Refusing to clear the cache folder: " why)
     {:path (.getAbsolutePath dir)})))
  (when (and (.isDirectory dir)
    (not (.exists (io/file dir cache-tag)))
    (seq (.list dir))
    (not= (.getCanonicalFile (cache-root (assoc system :env {})))
     (.getCanonicalFile dir)))
   (throw (ex-info (str "Refusing to clear "
      (.getAbsolutePath dir)
      ": it is not marked as a BAYSOL cache (no "
      cache-tag
      " in it)")
     {:path (.getAbsolutePath dir)})))
  (let [root (.toPath dir)
    tag (.resolve root cache-tag)
    tag-size (if (Files/isRegularFile tag (make-array LinkOption 0))
     (Files/size tag)
     0)
    freed (- (cache-size dir) tag-size)]
   (when (.isDirectory dir)
    (Files/walkFileTree
     root
     (proxy [SimpleFileVisitor] []
      (visitFile [^Path f _]
       ; the marker stays: a cleared cache is still a cache
       (when-not (= f tag) (Files/delete f))
       FileVisitResult/CONTINUE)
      (postVisitDirectory [^Path d _]
       (when-not (= d root) (Files/delete d))
       FileVisitResult/CONTINUE))))
   freed)))
