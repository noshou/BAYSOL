;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The settings sheets: what maps where. The blocs are read from the page files, so these
;; tests check the files against the key map: a bloc starts at its first page, right and
;; left go to the next and the previous bloc, and the footer of every page (the hints for
;; moving and for the blocs) says exactly what the keys do.

(ns baysol.tui.screens.sheets-test
 (:require [baysol.tui.screens.settings-menu :as settings-menu]
  [baysol.tui.screens.sheets :as sheets]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))

(defn ^:private blocs-of
 "The bloc numbers of the sheet in the resource folder `dir`, page by page."
 [dir]
 (:blocs (sheets/load-sheet dir)))

(defn ^:private sizes
 "`[n1 n2 ...]` as the bloc numbers of a sheet whose bloc 1 has n1 pages, bloc 2 n2, ..."
 [& counts]
 (vec (mapcat (fn [bloc n] (repeat n bloc)) (iterate inc 1) counts)))

(deftest the-blocs-are-read-from-the-footers
 (testing "the pages of each sheet and the bloc each belongs to"
  (is (= (sizes 4 3 3 2 2 4 3 2) (blocs-of "sampler-settings")))
  (is (= (sizes 4 3 4 3 2) (blocs-of "model-settings")))
  (is (= (sizes 3 2) (blocs-of "output-settings")))
  (is (= (sizes 5 4 5 4 5 3 5 5) (blocs-of "plots-settings")))))

(deftest a-bloc-starts-at-its-first-page
 (let [sampler (sheets/load-sheet "sampler-settings")
   starts [0 4 7 10 12 14 18 21 23]
   blocs (partition 2 1 starts)]
  (testing "right goes to the first page of the next bloc, from any page of a bloc"
   (doseq [[[from to] next-start] (map vector (butlast blocs) (rest starts))]
    (is (every? #(= next-start (sheets/move sampler % KeyType/ArrowRight))
      (range from to)))))
  (testing
   "left goes to the first page of the previous bloc, from any page of a bloc"
   (doseq [[[from to] prev-start] (map vector (rest blocs) starts)]
    (is (every? #(= prev-start (sheets/move sampler % KeyType/ArrowLeft))
      (range from to)))))
  (testing "there is nothing past the first and the last bloc"
   (is (every? #(= % (sheets/move sampler % KeyType/ArrowLeft)) (range 0 4)))
   (is (every? #(= % (sheets/move sampler % KeyType/ArrowRight)) (range 21 23))))))

(deftest down-and-up-stay-in-the-bloc
 (let [sampler (sheets/load-sheet "sampler-settings")]
  (is (= 1 (sheets/move sampler 0 KeyType/ArrowDown)))
  (is (= 0 (sheets/move sampler 0 KeyType/ArrowUp)))
  (testing "the last page of a bloc does not go down into the next one"
   (is (= 3 (sheets/move sampler 3 KeyType/ArrowDown)))
   (is (= 4 (sheets/move sampler 4 KeyType/ArrowUp))))))

(deftest the-other-keys
 (let [sampler (sheets/load-sheet "sampler-settings")]
  (testing
   "ctrl-x (`menu: ^x`) goes back to the settings menu from any page; escape quits"
   (is (every? #(= :back (sheets/move sampler % :ctrl-x)) (range 23)))
   (is (every? #(= :quit (sheets/move sampler % KeyType/Escape)) (range 23)))
   (is (= :quit (sheets/move sampler 3 KeyType/EOF))))
  (testing "the commands that do nothing yet, and any other key, stay on the page"
   (is (every? #(= 3 (sheets/move sampler 3 %))
     [KeyType/Enter :ctrl-w :ctrl-u :ctrl-r :ctrl-m \m \x
      KeyType/Backspace])))))

(defn ^:private footer
 "The three footer lines of a page."
 [lines]
 (subvec (vec lines) (- (count lines) 3)))

(defn ^:private hint
 "The arrows in the `move:` field of the first footer line."
 [line]
 (second (re-find #"move:\s*([↓↑ ]*)║" line)))

(defn ^:private setting-rows
 "The names of the settings of a page, top to bottom, with the one under the cursor `>`
 first marked: `[names marked-index]`."
 [lines]
 (let [rows (filter #(re-find #"^( > |   )╠[^═╩]" %) lines)
   marked (first (keep-indexed #(when (str/starts-with? %2 " > ") %1) rows))]
  [(mapv #(str/trim (subs % 4 28)) rows) marked]))

(defn ^:private every-page
 "A sequence of [dir page-index sheet] for every page of every sheet."
 []
 (for [dir (vals settings-menu/sheet-dirs)
   :let [sheet (sheets/load-sheet dir)]
   i (range (count (:pages sheet)))]
  [dir i sheet]))

(deftest the-footer-of-every-page-says-what-the-keys-do
 (doseq [[dir i sheet] (every-page)
   :let [[hints next-line prev-line] (footer (nth (:pages sheet) i))
    moves? #(not= i (sheets/move sheet i %))]]
  (testing (str dir " page" (inc i))
   (is (str/includes? next-line "menu: ^x")
    "the footer names ctrl-x as the menu key")
   (is (not (str/includes? next-line "^m"))
    "ctrl-m is Enter in a terminal: not offered")
   (is (= (str/includes? next-line "next bloc: →") (moves? KeyType/ArrowRight))
    "next bloc")
   (is (= (str/includes? prev-line "prev bloc: ←") (moves? KeyType/ArrowLeft))
    "prev bloc")
   (is (= (str/includes? (hint hints) "↓") (moves? KeyType/ArrowDown)) "down")
   (is (= (str/includes? (hint hints) "↑") (moves? KeyType/ArrowUp)) "up"))))

(deftest the-cursor-of-every-page-is-on-its-own-setting
 (doseq [[dir i sheet] (every-page)
   :let [lines (nth (:pages sheet) i)
    first-page (first (keep-indexed #(when (= %2 (nth (:blocs sheet) i))
       %1)
      (:blocs sheet)))
    pages-in-bloc (count (filter #{(nth (:blocs sheet) i)}
      (:blocs sheet)))
    [names marked] (setting-rows lines)]]
  (testing (str dir " page" (inc i))
   (is (= 24 (count lines)) "every page is 24 lines")
   (is (every? #(= 79 (count %)) (butlast lines)) "every line is 79 columns")
   (is (= 1 (count (filter #(str/starts-with? % " > ") lines))) "one cursor")
   (is (= (- i first-page) marked)
    "the cursor is on the setting of its page in the bloc")
   (is (= pages-in-bloc (count names)) "a page for every setting of the bloc"))))
