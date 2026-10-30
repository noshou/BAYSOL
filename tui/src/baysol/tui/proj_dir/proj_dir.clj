;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The folder of the projects: `projects` inside the BAYSOL
;; folder (see `baysol.tui.app-dir`), made the first time
;; `path` is dereferenced, which makes the BAYSOL folder first.

(ns baysol.tui.proj-dir.proj-dir
 (:require [baysol.tui.app-dir :as app-dir]
  [clojure.java.io :as io]))

(defn projects-root
 "The projects folder (a File) inside the BAYSOL folder `app-root`."
 [app-root]
 (io/file app-root "projects"))

;; The projects folder, made when this is first dereferenced.
(def path (delay (app-dir/ensure-dir! (projects-root @app-dir/path))))
