;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The names a colour or font setting may take: the harvested colours with their colour, and
;; the fonts of the machine (whatever it has, so only the shape is checked).

(ns baysol.tui.catalog-test
 (:require [baysol.tui.catalog :as catalog]
  [clojure.test :refer [deftest is testing]]))

(deftest the-colours-have-names-and-colours
 (let [names (catalog/names "PLOT_COLOUR_MAP" :colour)]
  (testing "the names of the harvest, sorted, with the ones the defaults use"
   (is (< 600 (count names)))
   (is (= names (sort names)))
   (is (every? (set names)
     ["crimson" "darkorange" "gray20" "gray40" "mediumturquoise" "black"
      "antiquewhite4"])))
  (testing "a swatch is the colour of a name, as red, green and blue"
   (is (= [220 20 60] (catalog/swatch "crimson")))
   (is (= [139 131 120] (catalog/swatch "antiquewhite4")))
   (is (every? #(<= 0 % 255) (catalog/swatch "gray20"))))
  (testing "a colour written #rrggbb is its own swatch; an unknown name has none"
   (is (= [255 0 0] (catalog/swatch "#ff0000")))
   (is (nil? (catalog/swatch "nope")))
   (is (nil? (catalog/swatch "#ff00"))))))

(deftest the-fonts-are-the-math-fonts-or-the-text-fonts
 (binding [catalog/*fonts* {:math ["Neo Euler" "TeX Gyre Pagella Math"],
    :text ["Pagella" "Times"]}]
  (testing "a setting with MATH in its name is offered the math fonts"
   (is (= ["Neo Euler" "TeX Gyre Pagella Math"]
     (catalog/names "PLOT_MATH_FONT" :font))))
  (testing "any other font setting the text fonts, which leave the math fonts out"
   (is (= ["Pagella" "Times"] (catalog/names "PLOT_TEXT_FONT" :font)))
   (is (not-any? (set (catalog/names "PLOT_MATH_FONT" :font))
     (catalog/names "PLOT_TEXT_FONT" :font))))
  (testing "a kind with no list is empty"
   (is (= [] (catalog/names "X" :other)))))
 (testing "a machine with no fonts has no list"
  (binding [catalog/*fonts* {:math [], :text []}]
   (is (= [] (catalog/names "PLOT_TEXT_FONT" :font)))
   (is (= [] (catalog/names "PLOT_MATH_FONT" :font))))))
