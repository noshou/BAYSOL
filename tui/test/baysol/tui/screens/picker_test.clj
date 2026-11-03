;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The dropdown that picks one name from a list, as a pure state and a pure step.

(ns baysol.tui.screens.picker-test
 (:require [baysol.tui.screens.picker :as picker]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))

(def ^:private names ["alpha" "Beta" "betamax" "gamma" "delta"])

(defn ^:private keys!
 "The result of feeding `inputs` to the picker `st`, one after another; the state, or the
 result (a map with `:chosen`, or `:cancel`) when it ends."
 [st & inputs]
 (reduce (fn [st input]
   (let [r (picker/step st input)]
    (cond (= r :cancel) (reduced :cancel)
     (:chosen r) (reduced r)
     :else (:state r))))
  st
  inputs))









(deftest the-dropdown
 (testing "what the dropdown shows"
  (let [many (mapv #(str "name" %) (range 40))
    st (picker/initial many nil)
    {:keys [items texts]} (picker/layout st 7 29)]
   (is (= 6 items))
   (is (= 7 (count texts)))
   (is (= " > name0" (first texts)))
   (is (= "   name1" (second texts)))
   (is (= " 1 of 40 matches    exit: esc" (last texts)))
   (is (every? #(<= (count %) 29) texts))
   (testing "it scrolls to keep the highlighted name in view"
    (let [down (apply keys! st (repeat 20 KeyType/ArrowDown))
      {:keys [texts]} (picker/layout down 7 29)]
     (is (some #(= " > name20" %) texts))
     (is (= " 21 of 40 matches   exit: esc" (last texts)))
     (is (= 6 (count (remove #(str/includes? % "matches") texts))))))
   (testing "no match says so"
    (is (= [" no match           exit: esc"]
      (:texts (picker/layout (keys! st \z) 7 29)))))
   (testing "an error replaces the status"
    (is (= " not in the list    exit: esc"
      (last (:texts (picker/layout (keys! st \z KeyType/Enter) 7 29))))))
   (testing "a long name is cut to the width"
    (is (= 10
      (count (first (:texts (picker/layout
          (picker/initial ["a very long name indeed"] nil)
          3
          10)))))))))

 (testing "laying it over a page"
  (let [page (vec (repeat 24 (apply str (repeat 79 "."))))
    st (picker/initial ["alpha" "beta"] nil)
    out (picker/overlay page st {:row 5, :col 50, :width 29, :rows 4})]
   (is (= 24 (count out)))
   (is (every? #(= 79 (count %)) out))
   (is (= (subvec page 0 5) (subvec out 0 5)))
   (is (str/includes? (nth out 5) " > alpha"))
   (is (str/includes? (nth out 6) "   beta"))
   (is (str/includes? (nth out 7) "1 of 2 matches"))
   (is (= (subs (nth page 5) 0 50) (subs (nth out 5) 0 50))
    "the columns before it are not touched")
   (is (= (subvec page 8) (subvec out 8))))))

(deftest picking
 (testing "narrowing"
  (is (= names (picker/narrow names "")))
  (is (= names (picker/narrow names "  ")))
  (is (= ["Beta" "betamax"] (picker/narrow names "be")))
  (is (= ["Beta" "betamax"] (picker/narrow names "BE")))
  (is (= ["alpha"] (picker/narrow names "alp")))
  (testing "no name starts with it, so those that have it inside"
   (is (= ["alpha"] (picker/narrow names "a"))
    "only alpha starts with a, though more have one")
   (is (= ["Beta" "betamax"] (picker/narrow names "eta")))
   (is (= ["betamax" "gamma"] (picker/narrow names "ma"))))
  (is (= [] (picker/narrow names "zzz")))
  (is (= [] (picker/narrow [] "a"))))

 (testing "the first position"
  (is (= 0 (picker/index-of-name names "alpha")))
  (is (= 3 (picker/index-of-name names "GAMMA")))
  (is (= 0 (picker/index-of-name names "nope")))
  (is (= 3 (:index (picker/initial names "gamma"))))
  (is (= 0 (:index (picker/initial names nil))))
  (is (= names (:matches (picker/initial names nil)))))

 (testing "keys in the picker"
  (let [st (picker/initial names nil)]
   (testing "down and up move, and go round"
    (is (= 1 (:index (keys! st KeyType/ArrowDown))))
    (is (= 4 (:index (keys! st KeyType/ArrowUp))))
    (is (= 0
      (:index (keys! st
        KeyType/ArrowDown
        KeyType/ArrowDown
        KeyType/ArrowDown
        KeyType/ArrowDown
        KeyType/ArrowDown)))))
   (testing "typing narrows and puts the first match first"
    (let [t (keys! st KeyType/ArrowDown \b \e)]
     (is (= "be" (:buffer t)))
     (is (= ["Beta" "betamax"] (:matches t)))
     (is (= 0 (:index t)))))
   (testing "Backspace widens again, and does nothing on an empty text"
    (is (= names (:matches (keys! st \b KeyType/Backspace))))
    (is (= "" (:buffer (keys! st KeyType/Backspace KeyType/Backspace)))))
   (testing "Tab takes the highlighted name into the text"
    (is (= "betamax" (:buffer (keys! st \b KeyType/ArrowDown KeyType/Tab)))))
   (testing "Enter picks the highlighted name"
    (is (= {:chosen "alpha"} (keys! st KeyType/Enter)))
    (is (= {:chosen "betamax"} (keys! st \b KeyType/ArrowDown KeyType/Enter)))
    (is (= {:chosen "Beta"} (keys! st \b \e \t KeyType/Enter))))
   (testing "Enter with nothing to pick says so and stays open"
    (let [t (keys! st \z KeyType/Enter)]
     (is (= "not in the list" (:error t)))
     (is (= [] (:matches t)))
     (testing "and typing again clears the error"
      (is (nil? (:error (keys! t KeyType/Backspace)))))))
   (testing "up and down do nothing with no match"
    (is (= 0 (:index (keys! st \z KeyType/ArrowDown KeyType/ArrowUp)))))
   (testing "Escape and the terminal going away give up"
    (is (= :cancel (keys! st \a KeyType/Escape)))
    (is (= :cancel (keys! st KeyType/EOF))))
   (testing "other keys change nothing"
    (is (= st (keys! st :ctrl-w KeyType/ArrowLeft KeyType/ArrowRight KeyType/F1))))
   (testing "the text has a limit"
    (is (= 40 (count (:buffer (apply keys! st (repeat 100 \a)))))))
   (testing "a control character is not typed"
    (is (= "" (:buffer (keys! st (char 7) (char 127) (char 0))))))))

 (testing "what is typed"
  (is (= "_" (picker/typed-text (picker/initial names nil) 10)))
  (is (= "abc_" (picker/typed-text {:buffer "abc"} 10)))
  (is (= "…ghij_" (picker/typed-text {:buffer "abcdefghij"} 6)))
  (is (<= (count (picker/typed-text {:buffer (apply str (repeat 50 "x"))} 12))
    12))))

(deftest the-status-row-reminds-how-to-leave-the-dropdown
 (testing "the reminder is at the right edge, in a row exactly as wide as the cell"
  (is (= " 1 of 3 matches     exit: esc" (picker/status-line "1 of 3 matches" 29)))
  (is (= 29 (count (picker/status-line "1 of 3 matches" 29)))))
 (testing "the word matches goes first when the room is short, the reminder stays"
  (is (= "1 of 1155 matches" (picker/count-status 0 1155 29)))
  (is (= "1155 of 1155" (picker/count-status 1154 1155 29)))
  (is (str/ends-with? (picker/status-line (picker/count-status 1154 1155 29) 29)
    "exit: esc")))
 (testing "a status too long for both is cut to the width, with no reminder"
  (is (= 12 (count (picker/status-line "a very long error" 12))))
  (is (not (str/includes? (picker/status-line "a very long error" 12) "exit")))))
