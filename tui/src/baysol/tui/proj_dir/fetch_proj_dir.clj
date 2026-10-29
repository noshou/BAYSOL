;; SPDX-License-Identifier: LGPL-3.0-or-later

(ns baysol.tui.proj-dir.fetch-proj-dir
 (:require [clojure.java.io :as io]))

(defn ^:private init!
 "Lazily initializes baysol_projects"
 []
 (let [home-dir (System/getProperty "user.home")
   proj-dir (io/file home-dir "baysol_projects")]
  (try
   (.mkdirs proj-dir)
   (when-not (.isDirectory proj-dir)
    (throw
     (ex-info "Failed to create project directory"
      {:path (.getAbsolutePath proj-dir)})))
   proj-dir
   (catch Exception e
    (throw
     (ex-info "Could not initialize project directory"
      {:path (.getAbsolutePath proj-dir)}
      e))))))

(def project-dir (delay (init!)))
