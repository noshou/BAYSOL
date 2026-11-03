;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The landing frames (pure): read from the owner's art, equal to it with no text, never
;; wider than the page, and the small boxes drawn over a page.

(ns baysol.tui.screens.landing-test
 (:require [baysol.tui.screens.landing :as landing]
  [baysol.tui.text :as txt]
  [baysol.tui.screens.page-load :as pgld]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))

(def ^:private arts
 (into {}
  (for [d ["buffer-landing" "custom-landing"]]
   [d (landing/parse-art (pgld/load-ascii "page" d))])))

(defn ^:private widths-ok? [lines] (every? #(<= (txt/display-width %) 79) lines))

(defn ^:private contiguous?
 [rows]
 (= rows (range (first rows) (+ (first rows) (count rows)))))

(deftest the-art-is-read-by-its-glyphs
 ;; the owner restyles the arts freely: nothing here pins a row number of one art, only
 ;; what the parser must find in any of them
 (doseq [[d art] arts]
  (testing d
   (is (= 24 (count (:lines art))))
   (is (= 4 (count (:options art))) "four slots in each art")
   (is (= 2 (count (:status art))))
   (is (= 21 (:footer-from art)))
   (is (= 1 (:row (:title art))))
   (is (contiguous? (map :row (:options art)))
    "the option slots are consecutive rows")
   (is (contiguous? (map :row (:status art))) "the status rows are consecutive")
   (is (< (:row (:title art))
     (first (map :row (:options art)))
     (first (map :row (:status art)))
     (:footer-from art)))
   (is (= 1 (count (distinct (map :width (:options art)))))
    "one width for the slots")
   (is (= [74] (distinct (map :width (:status art))))))))

(deftest no-text-no-change
 (doseq [[d art] arts]
  (is (= (:lines art) (landing/frame art {})) d)
  (is (= (:lines art) (landing/frame art {:cursor 2})) d)
  (is (widths-ok? (landing/frame art {})) d)))

(defn ^:private rows-of
 [art]
 (concat [(:row (:title art))] (map :row (:options art)) (map :row (:status art))))

(deftest the-text-goes-in-its-slots
 (let [art (arts "buffer-landing")
   [o0 o1 o2 o3] (map :row (:options art))
   [s0 s1] (map :row (:status art))
   lines (landing/frame art
    {:title "buffer · demo",
     :options ["edit current recipe (12 solutes)"
      "load a recipe" "new recipe"],
     :cursor 1,
     :status ["buffer.edn: 12 solutes"
      "no saved recipes!"]})]
  (is (str/includes? (nth lines (:row (:title art))) "│ buffer · demo"))
  (is (str/includes? (nth lines o0) "│   edit current recipe (12 solutes)"))
  (is (str/includes? (nth lines o1) "│ > load a recipe"))
  (is (str/includes? (nth lines o2) "│   new recipe"))
  (is (= (nth lines o3) (nth (:lines art) o3)) "a slot with no option is blank")
  (is (str/includes? (nth lines s0) "│ buffer.edn: 12 solutes"))
  (is (str/includes? (nth lines s1) "│ no saved recipes!"))
  (is (= 24 (count lines)))
  (is (widths-ok? lines))
  (testing "borders and the static boxes are untouched"
   (let [others (remove (set (rows-of art)) (range 24))]
    (is (= (map #(nth (:lines art) %) others) (map #(nth lines %) others)))
    (doseq [slot (concat [(:title art)] (:options art) (:status art))
      :let [line (nth lines (:row slot))]]
     (is (= \│ (.charAt ^String line (dec (:from slot)))))
     (is (= \│ (.charAt ^String line (+ (:from slot) (:width slot))))))))))

(deftest long-text-is-cut-never-overflows
 (let [art (arts "buffer-landing")
   long-text (apply str (repeat 120 "x"))
   lines (landing/frame art
    {:title long-text,
     :options [long-text long-text],
     :cursor 0,
     :status [long-text long-text]})
   filled (concat [(:row (:title art))]
    (take 2 (map :row (:options art)))
    (map :row (:status art)))]
  (is (widths-ok? lines))
  (is (every? #(str/includes? (nth lines %) "… │") filled))
  (doseq [slot (:options art)
    :let [line (nth lines (:row slot))]]
   (is (= \│ (.charAt ^String line (+ (:from slot) (:width slot))))))
  (is (every? #(= 79 (txt/display-width (nth lines %))) filled))))

(deftest boxes
 (let [b (landing/box "title" 20 ["a" "bbbbbbbbbbbbbbbbbbbbbbbbbbbb"])]
  (is (= 4 (count b)))
  (is (every? #(= 20 (txt/display-width %)) b))
  (is (str/starts-with? (first b) "╭─ title "))
  (is (str/ends-with? (last b) "╯"))
  (is (str/includes? (nth b 2) "… │")))
 (testing "a long title is cut"
  (let [b (landing/box (apply str (repeat 50 "t")) 20 [])]
   (is (= 20 (txt/display-width (first b))))))
 (testing "overlay writes over the lines in place"
  (let [base (vec (repeat 6 (apply str (repeat 30 ".."))))
    out (landing/overlay base 1 5 (landing/box "t" 10 ["x"]))]
   (is (= (nth base 0) (nth out 0)))
   (is (= "╭─ t ────╮" (subs (nth out 1) 5 15)))
   (is (= 60 (count (nth out 1)))))))

(deftest the-name-prompt
 (let [step #(landing/prompt-step %1 %2 (fn [n] (when (= n "bad") "no such!")) 5)
   typed
   (reduce (fn [st c] (:state (step st c))) (landing/prompt-initial) "abc")]
  (is (= "abc" (:text typed)))
  (is (= "ab" (:text (:state (step typed KeyType/Backspace)))))
  (is (= "" (:text (:state (step (landing/prompt-initial) KeyType/Backspace)))))
  (is (= {:chosen "abc"} (step typed KeyType/Enter)))
  (is (= {:chosen "abc"} (step (assoc typed :text "  abc ") KeyType/Enter))
   "the name is trimmed")
  (is (= :cancel (step typed KeyType/Escape)))
  (is (= :cancel (step typed KeyType/EOF)))
  (is (= "no such!"
    (:error (:state (step (assoc typed :text "bad") KeyType/Enter)))))
  (is (nil? (:error (:state (step (assoc typed :error "x") \d))))
   "typing clears the error")
  (is (= "abcde" (:text (reduce (fn [st c] (:state (step st c))) typed "defg")))
   "typing stops at the most")
  (is (= {:state typed} (step typed KeyType/ArrowUp)) "other keys do nothing")
  (is (= "abc" (:text (:state (step typed \u0001))))
   "a control character is not typed")))

(deftest prompt-and-question-boxes
 (let [p (landing/prompt-box "save as" 40 {:text "abc", :error nil})
   long-p (landing/prompt-box "save as"
    40
    {:text (apply str (repeat 40 "y")), :error nil})
   q (landing/question-box 40 (apply str (repeat 40 "n")))]
  (is (str/includes? (nth p 1) "name: abc_"))
  (is (str/includes? (nth p 2) "enter: accept  esc: cancel"))
  (is (every? #(= 40 (txt/display-width %)) (concat p long-p q)))
  (is (re-find #"…y+_ │" (nth long-p 1)))
  (is (str/includes? (nth q 1) "nn\"?"))
  (is (str/includes? (nth q 2) "enter: replace  esc: keep"))
  (is (str/includes?
    (nth (landing/prompt-box "t" 40 {:text "", :error "that name is taken!"}) 2)
    "that name is taken!"))))
