;; SPDX-License-Identifier: LGPL-3.0-or-later

(ns baysol.tui.main-test
 (:require [baysol.tui.main :as main]
  [clojure.test :refer [deftest is]]))

(deftest the-program-runs-itself-again-through-the-entry-point
 (is (= ["/jdk/bin/java" "-cp" "src:resources" "clojure.main" "-m"
    "baysol.tui.main"]
   (main/program-command "/jdk/bin/java" "src:resources"))))
