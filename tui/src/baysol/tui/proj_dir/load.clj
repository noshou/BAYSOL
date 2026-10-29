;; SPDX-License-Identifier: LGPL-3.0-or-later

(require '[clojure.java.io :as io])

(def project-dir (io/file "/home/user/baysol_projects"))

(file-seq project-dir)
