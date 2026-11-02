;; SPDX-License-Identifier: LGPL-3.0-or-later

(ns baysol.tui.screens.theme-test
 (:require [baysol.tui.screens.state :as state]
  [baysol.tui.screens.theme :as theme]
  [baysol.tui.support :as support]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna TextColor$Indexed TextColor$RGB)))

(defn ^:private sys [os env] {:os os, :env env, :home "/h", :cwd "/w"})

(deftest the-colours-follow-what-the-terminal-takes
 (testing "24-bit colour where the terminal says so"
  (doseq [v ["truecolor" "24bit" "TrueColor"]]
   (let [{:keys [background foreground]} (theme/colours (sys "Linux"
       {"COLORTERM" v}))]
    (is (= [255 217 241]
      [(.getRed ^TextColor$RGB background)
       (.getGreen ^TextColor$RGB background)
       (.getBlue ^TextColor$RGB background)]))
    (is (= 108 (.getRed ^TextColor$RGB foreground))))))
 (testing "Windows takes it without saying"
  (is (instance? TextColor$RGB
    (:background (theme/colours (sys "Windows 11" {}))))))
 (testing "else the white and black of the 256 colours"
  (doseq [env [{} {"COLORTERM" ""} {"COLORTERM" "yes"}]]
   (let [{:keys [background foreground]} (theme/colours (sys "Mac OS X" env))]
    (is (instance? TextColor$Indexed background))
    (is (= (TextColor$Indexed. 231) background))
    (is (= (TextColor$Indexed. 16) foreground))))))

(deftest every-cell-of-the-screen-is-painted-with-the-theme
 (let [vs (support/virtual-screen)
   page {:asset ["a line" "another"], :marks [[1 3 [255 0 0]]]}]
  (state/draw-page (:screen vs) page theme/background)
  (let [cells (for [row (range 24)
      col (range 80)]
     (.getFrontCharacter (:screen vs) col row))
    plain (remove nil? (map-indexed (fn [i c] (when-not (= i 83) c)) cells))]
   (is (= 1920 (count cells)))
   (is (every? #(= theme/background (.getBackgroundColor %)) (take 83 cells)))
   (is (every? #(= theme/foreground (.getForegroundColor %)) (take 83 cells)))
   (is (= (TextColor$RGB. 255 0 0) (.getBackgroundColor (nth cells 83)))
    "a swatch keeps its colour")
   (is (every? #(= theme/background (.getBackgroundColor %)) (drop 84 cells)))
   (is (seq plain)))))

(deftest a-panel-is-white-and-keeps-its-text
 (let [vs (support/virtual-screen)
   page {:asset ["0123456789"], :panel [[0 2 4] [1 2 4]]}]
  (state/draw-page (:screen vs) page theme/background)
  (let [cell (fn [col row] (.getFrontCharacter (:screen vs) col row))]
   (testing "inside the panel: white, the text still there, even on a blank row"
    (is (= theme/panel (.getBackgroundColor (cell 2 0))))
    (is (= \2 (.getCharacter (cell 2 0))))
    (is (= theme/panel (.getBackgroundColor (cell 5 1)))))
   (testing "outside it: the theme's background"
    (is (= theme/background (.getBackgroundColor (cell 1 0))))
    (is (= theme/background (.getBackgroundColor (cell 6 0))))
    (is (= theme/background (.getBackgroundColor (cell 2 2))))))))

(deftest the-page-is-centred-on-a-larger-terminal
 (testing "the offset of the corner of the page"
  (is (= [0 0] (state/page-offset 80 24)))
  (is (= [10 3] (state/page-offset 100 30)))
  (is (= [10 3] (state/page-offset 101 31))
   "the odd cell goes to the right and below")
  (is (= [0 0] (state/page-offset 60 10))
   "a terminal smaller than the page: the corner"))
 (testing "text, panel and swatches are all moved by the offset"
  (let [vs (support/virtual-screen)
    t (:terminal vs)]
   (.setTerminalSize t (com.googlecode.lanterna.TerminalSize. 100 30))
   (.doResizeIfNecessary (:screen vs))
   (state/draw-page (:screen vs)
    {:asset ["abc"], :marks [[0 1 [255 0 0]]], :panel [[0 2 1]]}
    theme/background)
   (let [cell (fn [col row] (.getFrontCharacter (:screen vs) col row))]
    (is (= \a (.getCharacter (cell 10 3))))
    (is (= (TextColor$RGB. 255 0 0) (.getBackgroundColor (cell 11 3))))
    (is (= theme/panel (.getBackgroundColor (cell 12 3))))
    (is (= theme/background (.getBackgroundColor (cell 0 0)))
     "the margin is painted")
    (is (= theme/background (.getBackgroundColor (cell 99 29))))))))

(deftest a-resize-while-waiting-for-a-key-draws-the-page-again-centred
 (let [vs (support/virtual-screen)
   t (:terminal vs)
   s (:screen vs)
   result (promise)]
  (state/draw-page s {:asset ["hello"]} theme/background)
  (is (= \h (.getCharacter (.getFrontCharacter s 0 0))))
  (future (result (state/read-input s)))
  (Thread/sleep 100)
  (.setTerminalSize t (com.googlecode.lanterna.TerminalSize. 100 30))
  (loop [n 0]
   (when (and (< n 100) (not= \h (.getCharacter (.getFrontCharacter s 10 3))))
    (Thread/sleep 25)
    (recur (inc n))))
  (is (= \h (.getCharacter (.getFrontCharacter s 10 3)))
   "redrawn at the new offset")
  (support/feed! vs \q)
  (is (= \q (deref result 2000 :none)))))

(deftest keys-typed-before-the-menu-is-ready-are-thrown-away
 (let [vs (support/virtual-screen)]
  (support/feed! vs
   com.googlecode.lanterna.input.KeyType/Enter
   "x"
   com.googlecode.lanterna.input.KeyType/Enter)
  (is (= 3 (state/discard-pending! (:screen vs))))
  (is (nil? (.pollInput (:screen vs))))
  (is (= 0 (state/discard-pending! (:screen vs)))
   "nothing waiting, nothing thrown")))
