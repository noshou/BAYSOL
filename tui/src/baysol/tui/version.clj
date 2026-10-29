;; SPDX-License-Identifier: LGPL-3.0-or-later

(ns baysol.tui.version
 (:require [clojure.java.io :as io]))

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
