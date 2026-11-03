;; SPDX-License-Identifier: LGPL-3.0-or-later

(ns baysol.tui.screens.page-load
 (:require [baysol.tui.text :as txt]
  [clojure.java.io :as io]
  [clojure.string :as str]))

;; The width of a tab in the art pages: the owner's editor shows a tab as 4 columns, so a
;; line that starts with a tab lines up with the others that start with 4 spaces.
(def ^:private tab-width 4)

(defn expand-tabs
 "`line` with each tab replaced by the spaces up to the next multiple of 4 columns, so
 that the terminal draws what the art was drawn as."
 [^String line]
 (let [sb (StringBuilder.)]
  (doseq [c line]
   (if (= c \tab)
    (dotimes [_ (- tab-width (mod (.length sb) tab-width))] (.append sb \space))
    (.append sb c)))
  (str sb)))

(defn load-ascii
 "The lines of the page file `filename` in
 resources/dir/pages/<filename>.txt, as a vector of strings, tabs expanded."
 [filename dir]
 (->> (-> (str dir "/pages/" filename ".txt")
   io/resource
   (slurp :encoding "UTF-8")
   str/split-lines)
  (mapv expand-tabs)))

(defn stamp
 "`lines` with `text` written on line `row`, centred in the columns from `from` (included)
 to `to` (excluded). What was there is replaced, a line that is too short is padded with
 spaces, and a text wider than the span is cut."
 [lines row from to text]
 (let [width (- to from)
   text (txt/take-width text width)
   w (txt/display-width text)
   left (+ from (quot (- width w) 2))
   line (str (nth lines row))]
  (assoc lines row (txt/splice-width line left (+ left w) text))))

(defn put-text
 "The line `line` with `text`, padded or cut to `width` cells (a wide character takes
 two), written from column `from`. A line shorter than that is padded with spaces first."
 [^String line from width text]
 (txt/splice-width line from (+ from width) (txt/pad-width text width)))
