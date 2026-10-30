;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The BAYSOL folder of the user: the one place the program keeps what must last (the
;; BAYSOL-wide settings, the projects). It lies in the place each operating system keeps the
;; data of a program, and is made the first time `path` is dereferenced.

(ns baysol.tui.app-dir
 (:require [baysol.tui.terminal :as terminal]
  [clojure.java.io :as io]
  [clojure.string :as str]))

(def ^:private home-var
 "The environment variable that names the BAYSOL folder instead of the default one."
 "BAYSOL_HOME")

(defn env-dir
 "The folder (a File) that the environment variable `k` of `env` names, or nil if it is
 missing, blank or not an absolute path."
 [env k]
 (let [v (str/trim (str (get env k)))]
  (when-not (str/blank? v)
   (let [dir (io/file v)] (when (.isAbsolute dir) dir)))))

(defn data-home
 "The folder (a File) in which the operating system `os` (the `os.name` property) keeps
 the data of a program, from the environment `env` and the user's home folder `home`:
 - Windows: %LOCALAPPDATA% (else <home>\\AppData\\Local);
 - macOS: <home>/Library/Application Support;
 - Linux and everything else (the freedesktop XDG convention, the same on every
   distribution): $XDG_DATA_HOME, with ~/.local/share as the default; a relative
   $XDG_DATA_HOME is ignored, as the specification says."
 [os env home]
 (let [os-clean (str/lower-case (str os))]
  (cond
   (terminal/windows? os-clean)
   (or (env-dir env "LOCALAPPDATA") (io/file home "AppData" "Local"))

   (str/includes? os-clean "mac")
   (io/file home "Library" "Application Support")

   :else
   (or (env-dir env "XDG_DATA_HOME") (io/file home ".local" "share")))))

(defn app-root
 "The BAYSOL folder (a File): $BAYSOL_HOME if that is set to an absolute path, otherwise
 `baysol` inside the data folder of the system (`data-home`)."
 [os env home]
 (or (env-dir env home-var) (io/file (data-home os env home) "baysol")))

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
(def path
 (delay (ensure-dir! (app-root (System/getProperty "os.name")
    (System/getenv)
    (System/getProperty "user.home")))))
