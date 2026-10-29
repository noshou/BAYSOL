;; SPDX-License-Identifier: LGPL-3.0-or-later

(ns baysol.tui.screens.page-load
 (:require [clojure.java.io :as io]
  [clojure.string :as str]))

(defn load-ascii
 "The lines of the page file `filename` in
 resources/dir/pages/<filename>.ascii, as a vector of strings."
 [filename dir]
 (-> (str dir "/pages/" filename ".ascii")
  io/resource
  (slurp :encoding "UTF-8")
  str/split-lines
  vec))

(defn stamp
 "`lines` with `text` written on line `row`, centred in the columns from `from` (included)
 to `to` (excluded). What was there is replaced, a line that is too short is padded with
 spaces, and a text wider than the span is cut."
 [lines row from to text]
 (let [width (- to from)
   text (subs text 0 (min (count text) width))
   left (+ from (quot (- width (count text)) 2))
   line (str (nth lines row))
   padded (str line (apply str (repeat (max 0 (- to (count line))) \space)))]
  (assoc lines
   row
   (str (subs padded 0 left) text (subs padded (+ left (count text)))))))
