;; SPDX-License-Identifier: LGPL-3.0-or-later

(ns baysol.tui.text-test
 (:require [baysol.tui.text :as txt]
  [clojure.test :refer [deftest is]])
 (:import (com.googlecode.lanterna.input KeyType)))

(deftest spaces-test
 (is (= "" (txt/spaces 0)))
 (is (= "" (txt/spaces -3)))
 (is (= "   " (txt/spaces 3))))

(deftest printable-test
 (is (txt/printable? \a))
 (is (txt/printable? \space))
 (is (txt/printable? \é))
 (is (not (txt/printable? (char 31))))
 (is (not (txt/printable? (char 127))))
 (is (not (txt/printable? :enter)))
 (is (not (txt/printable? nil))))

(deftest clamp-cursor-test
 (let [s {:rows [1 2 3]}]
  (is (= 0 (txt/clamp-cursor -1 s)))
  (is (= 1 (txt/clamp-cursor 1 s)))
  (is (= 2 (txt/clamp-cursor 9 s)))
  (is (= 0 (txt/clamp-cursor 5 {:rows []})))))

(deftest format-number-test
 (is (= "" (txt/format-number nil)))
 (is (= "200" (txt/format-number 200.0)))
 (is (= "200" (txt/format-number 200)))
 (is (= "0.00001" (txt/format-number 1.0E-5)))
 (is (= "1.5" (txt/format-number 1.50))))

(deftest number-text-test
 (is (= 12.5 (txt/number-text "12.5")))
 (is (= -3.0 (txt/number-text "-3.")))
 (is (= 0.5 (txt/number-text ".5")))
 (is (= 1.0E-5 (txt/number-text "1e-5")))
 (is (nil? (txt/number-text "")))
 (is (nil? (txt/number-text "abc")))
 (is (nil? (txt/number-text " 1")))
 (is (nil? (txt/number-text "1e999")) "infinite is no number"))

(deftest fold-test
 (is (= "nacl" (txt/fold "  NaCl ")))
 (is (= "" (txt/fold nil)))
 (is (= (txt/fold "A") (txt/fold " a "))))

(deftest typing-test
 (is (txt/edits? KeyType/Backspace "" 3))
 (is (txt/edits? \a "ab" 3))
 (is (not (txt/edits? \a "abc" 3)))
 (is (not (txt/edits? KeyType/Enter "a" 3)))
 (is (not (txt/edits? (char 7) "a" 3)))
 (is (= "ab" (txt/typed "abc" KeyType/Backspace 5)))
 (is (= "" (txt/typed "" KeyType/Backspace 5)))
 (is (= "abc" (txt/typed "ab" \c 5)))
 (is (= "abc" (txt/typed "abc" \d 3)))
 (is (= "ab" (txt/typed "ab" KeyType/ArrowUp 3)))
 (is (= "ab" (txt/typed "abc" KeyType/Backspace 3))))

(deftest cycle-index-test
 (is (= 1 (txt/cycle-index 0 3 true)))
 (is (= 0 (txt/cycle-index 2 3 true)))
 (is (= 2 (txt/cycle-index 0 3 false)))
 (is (= 0 (txt/cycle-index 1 3 false))))

(deftest display-width-test
 (is (= 3 (txt/display-width "abc")))
 (is (= 0 (txt/display-width nil)))
 (is (= 6 (txt/display-width "日本語")) "East Asian wide: two cells each")
 (is (= 2 (txt/display-width "Ａ")) "fullwidth")
 (is (= 2 (txt/display-width "😀")) "an astral emoji is two cells, one code point")
 (is (= 1 (txt/display-width "é")))
 (is (= 1 (txt/display-width (str "e" (char 0x301))))
  "a combining mark takes no cell")
 (is (= 2 (txt/display-width (str "a" (char 0x200d) "b")))
  "zero-width joiner takes none")
 (is (= 2 (txt/display-width (str "👍" (String. (Character/toChars 0x1F3FD)))))
  "a skin-tone modifier takes none")
 (is (= 2 (txt/display-width "a\tb")) "control characters take none"))

(deftest cutting-by-width-test
 (is (= "ab" (txt/take-width "abcd" 2)))
 (is (= "日本" (txt/take-width "日本語" 4)))
 (is (= "日" (txt/take-width "日本語" 3)) "a wide character is never split")
 (is (= "" (txt/take-width "日" 1)))
 (is (= "cd" (txt/take-last-width "abcd" 2)))
 (is (= "語" (txt/take-last-width "日本語" 3)))
 (is (= "日本語" (txt/take-last-width "日本語" 9)))
 (is (= "日 " (txt/pad-width "日本" 3))
  "the cell a wide character would cross is a space")
 (is (= "ab   " (txt/pad-width "ab" 5)))
 (doseq [s ["日本語abc😀é" "😀😀😀" "abc"]
   n (range 0 12)]
  (is (<= (txt/display-width (txt/take-width s n)) n))
  (is (<= (txt/display-width (txt/take-last-width s n)) n))
  (is (= n (txt/display-width (txt/pad-width s n))))))

(deftest splice-width-test
 (is (= "abcXY g h" (txt/splice-width "abcdefg h" 3 6 "XY ")))
 (is (= "ab   XY" (txt/splice-width "ab" 5 7 "XY")) "a short line is padded")
 (let [line (txt/splice-width (apply str (repeat 10 "x")) 0 4 "日本")
   again (txt/splice-width line 6 8 "日")]
  (is (= 10 (txt/display-width line)))
  (is (= 10 (txt/display-width again))
   "a second splice after wide text lands right")
  (is (= "日本xxxx日xx" (txt/splice-width "日本xxxx日xx" 10 10 ""))))
 (is (= "x 日" (txt/splice-width "日日" 0 1 "x"))
  "half a wide character stays as a space"))

(deftest the-cap-is-told-test
 (is (txt/at-cap? \a "abc" 3))
 (is (not (txt/at-cap? \a "ab" 3)))
 (is (not (txt/at-cap? KeyType/Enter "abc" 3)))
 (is (not (txt/at-cap? KeyType/Backspace "abc" 3)))
 (is (= "name too long (40 at most)" (txt/too-long "name" 40))))
