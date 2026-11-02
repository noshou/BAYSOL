;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Loading the art pages: tabs in the art are drawn as the spaces they were drawn as, and
;; text is written into a page without changing its width.

(ns baysol.tui.screens.page-load-test
 (:require [baysol.tui.screens.page-load :as pgld]
  [clojure.java.io :as io]
  [clojure.test :refer [deftest is testing]]))







(deftest page-loading
 (testing "tabs"
  (is (= "    abc" (pgld/expand-tabs "\tabc")))
  (is (= "ab  c" (pgld/expand-tabs "ab\tc")))
  (is (= "abc d" (pgld/expand-tabs "abc\td")))
  (is (= "abcd    e" (pgld/expand-tabs "abcd\te")))
  (is (= "        x" (pgld/expand-tabs "\t\tx")))
  (is (= "no tabs here" (pgld/expand-tabs "no tabs here")))
  (is (= "" (pgld/expand-tabs "")))
  (testing "a glyph counts as one column"
   (is (= "┌───┐       x" (pgld/expand-tabs "┌───┐\t\tx"))
    "five columns, then a tab to 8 and another to 12")))

 (testing "no page has a tab after loading"
  (doseq [dir ["main-menu" "settings-menu" "project-menu" "project-settings-menu"]
    n (range 1 7)
    :let [res (str dir "/pages/page" n ".txt")]
    :when (io/resource res)]
   (is (every? #(not (re-find #"\t" %)) (pgld/load-ascii (str "page" n) dir)) res)))

 (testing "a page with tabs lines up with its neighbours"
  (let [page (pgld/load-ascii "page1" "project-settings-menu")
    top (first (filter #(re-find #"┌───┐" %) page))
    middle (first (filter #(re-find #"│ > │" %) page))]
   (is (= 4 (.indexOf ^String top "┌")) "the first tab became 4 columns")
   (is (= 4 (.indexOf ^String middle "│"))
    "as the row below it, which has 4 spaces")))

 (testing "writing text into a page"
  (is (= "abcdXYghij" (pgld/put-text "abcdefghij" 4 2 "XY")))
  (is (= "abcdXY  ij" (pgld/put-text "abcdefghij" 4 4 "XY"))
   "a text shorter than the cell is padded")
  (is (= "abcdXYZhij" (pgld/put-text "abcdefghij" 4 3 "XYZ")))
  (is (= "abcdXYg" (pgld/put-text "abcdefg" 4 2 "XYZW"))
   "and one that is longer is cut")
  (is (= "ab    XY" (pgld/put-text "ab" 6 2 "XY"))
   "a line that is too short is padded first")
  (is (= "abc" (pgld/put-text "abc" 1 0 "")) "a cell of no width changes nothing")))
