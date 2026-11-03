;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The settings menu: what maps where. Its four pages are art laid out as a grid, so the
;; tests read each page (where the cursor is, which arrows the footer shows) and check them
;; against the table of links.

(ns baysol.tui.screens.settings-menu-test
 (:require [baysol.tui.screens.settings-menu :as settings-menu]
  [baysol.tui.screens.sheets :as sheets]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))

;; page for page: what each arrow and Enter lead to
(def ^:private links
 {:page1 {:right :page4, :down :page2, :enter :output}, ; output, top left
  :page2 {:up :page1, :right :page3, :enter :sampler}, ; sampler, bottom left
  :page3 {:up :page4, :left :page2, :enter :plots}, ; plots, bottom right
  :page4 {:left :page1, :down :page3, :enter :model}}) ; model, top right

(def ^:private keys-of
 {:up KeyType/ArrowUp,
  :down KeyType/ArrowDown,
  :left KeyType/ArrowLeft,
  :right KeyType/ArrowRight,
  :enter KeyType/Enter})

(deftest every-page-leads-where-the-table-says
 (doseq [[page expected] links
   direction [:up :down :left :right :enter]]
  (is (= (get expected direction page)
    (settings-menu/page-after page (keys-of direction)))
   (str page " " direction))))

(deftest a-hotkey-opens-its-own-sheet-from-any-page
 (doseq [page (keys links)]
  (is (= :output (settings-menu/page-after page \u)))
  (is (= :sampler (settings-menu/page-after page \a)))
  (is (= :plots (settings-menu/page-after page \p)))
  (is (= :model (settings-menu/page-after page \m)))))

(deftest ctrl-x-goes-back-escape-quits-and-other-keys-do-nothing
 (doseq [page (keys links)]
  (is (= :back (settings-menu/page-after page :ctrl-x)))
  (is (= :quit (settings-menu/page-after page KeyType/Escape)))
  (is (= :quit (settings-menu/page-after page KeyType/EOF)))
  (is (every? #(= page (settings-menu/page-after page %)) [:ctrl-w :ctrl-m \x]))))

(deftest every-kind-opens-a-sheet
 (is (= (set (keep :enter (vals links))) (set (keys settings-menu/sheet-dirs))))
 (is (every? #(pos? (sheets/page-count %)) (vals settings-menu/sheet-dirs))))

(defn ^:private lines-of
 "The lines of page `page` of the menu."
 [page]
 (get-in settings-menu/pages [page :asset]))

(defn ^:private arrows
 "The arrows the footer of the page shows beside `move:`, as a set of directions. The up
 arrow is above the `move:` line, the down arrow below it, left and right on it."
 [lines]
 (let [move-line (first (keep-indexed #(when (str/includes? %2 "move:") %1) lines))
   at #(nth lines % "")]
  (cond-> #{}
   (str/includes? (at (dec move-line)) "↑") (conj :up)
   (str/includes? (at (inc move-line)) "↓") (conj :down)
   (str/includes? (at move-line) "←") (conj :left)
   (str/includes? (at move-line) "→") (conj :right))))

(defn ^:private position
 "Where the cursor box is on a page: `[row column]`, each :top/:bottom and :left/:right.
 A tab counts as four columns, as the screen draws it."
 [lines]
 (let [i (first (keep-indexed #(when (str/includes? %2 "┌───┐") %1) lines))
   column (str/index-of (str/replace (nth lines i) "\t" "    ") "┌───┐")]
  [(if (< i 15) :top :bottom) (if (< column 20) :left :right)]))

(deftest the-arrows-on-every-page-are-the-links
 (doseq [[page expected] links]
  (is (= (set (filter #{:up :down :left :right} (keys expected)))
    (arrows (lines-of page)))
   (str page " shows the arrows it has links for"))))

(deftest the-links-follow-the-grid-of-the-cursor
 (let [at (into {} (for [page (keys links)] [page (position (lines-of page))]))
   neighbour (fn [[row column] direction]
    (case direction
     :up [:top column]
     :down [:bottom column]
     :left [row :left]
     :right [row :right]))
   page-at (into {} (map (fn [[page p]] [p page]) at))]
  (testing "each page has its own place on the grid"
   (is (= 4 (count (set (vals at))))))
  (doseq [[page expected] links
    direction [:up :down :left :right]
    :let [target (get expected direction)
     here (at page)
     there (neighbour here direction)]]
   (is (= (when (not= here there) (page-at there)) target)
    (str page " " direction)))))
