;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The scaffolding the screens share: the loop of the table screens, the prompt driver, the
;; yes-or-no question and the menu navigation, run on a virtual terminal.

(ns baysol.tui.screens.loop-test
 (:require [baysol.tui.screens.loop :as lp]
  [baysol.tui.screens.picker :as picker]
  [baysol.tui.screens.state :as state]
  [baysol.tui.support :as support :refer [background]]
  [clojure.test :refer [deftest is]])
 (:import (com.googlecode.lanterna.input KeyType)))


(defn ^:private run
 "Runs `(f screen)` on a virtual terminal with `inputs` fed; `:timeout` if it waits on."
 [f & inputs]
 (let [vs (support/virtual-screen)
   r (future (f (:screen vs)))]
  (apply support/feed! vs inputs)
  (let [out (deref r 5000 :timeout)]
   (when (= out :timeout)
    (support/feed! vs KeyType/Escape KeyType/Escape KeyType/EOF)
    (deref r 3000 nil))
   out)))

(defn ^:private table
 "A table loop whose state counts the keys `a` and records what was drawn."
 [esc-quits? seen]
 #(lp/run-table!
  %
  background
  {:init {:n 0, :offset 0, :note "old"},
   :frame (fn [st]
    (swap! seen conj (select-keys st [:n :offset :note]))
    {:lines ["frame"], :offset (inc (:n st))}),
   :esc-quits? esc-quits?,
   :handle (fn [st input]
    (cond (= input \a) (update st :n inc)
     (= input \q) :quit
     (= input \b) :back
     :else st))}))

(deftest table-loop-ends-on-the-shared-keys
 (is (= :quit (run (table (constantly true) (atom [])) KeyType/Escape)))
 (is (= :quit (run (table (constantly true) (atom [])) KeyType/EOF)))
 (is (= :back (run (table (constantly true) (atom [])) :ctrl-x)))
 (is (= :quit (run (table (constantly true) (atom [])) \q)))
 (is (= :back (run (table (constantly true) (atom [])) \b))))

(deftest table-loop-escape-is-the-screens-to-allow
 (let [seen (atom [])]
  ;; Escape is handed to the handler (which ignores it) while the screen says no
  (is (= :back (run (table #(>= (:n %) 2) seen) \a KeyType/Escape :ctrl-x)))
  (is (= :quit (run (table #(>= (:n %) 2) seen) \a \a KeyType/Escape)))))

(deftest table-loop-sets-the-offset-and-clears-the-note
 (let [seen (atom [])]
  (run (table (constantly true) seen) \a \a KeyType/Escape)
  ;; the first frame has the start state; later ones the offset of the frame before and no
  ;; note
  (is (= [{:n 0, :offset 0, :note "old"} {:n 1, :offset 1, :note nil}
     {:n 2, :offset 2, :note nil}]
    @seen))))

(deftest prompt-driver-results
 (let [drawn (atom 0)
   go (fn [eof-quits? & ks]
    (apply run
     (fn [screen]
      (state/run-prompt! screen
       (picker/initial ["alpha" "beta"] nil)
       (fn [_] (swap! drawn inc))
       picker/step
       eof-quits?))
     ks))]
  (is (= "beta" (go true KeyType/ArrowDown KeyType/Enter)))
  (is (= "beta" (go false \b KeyType/Enter)))
  (is (nil? (go true KeyType/Escape)))
  (is (= :back (go false :ctrl-x)))
  (is (= :quit (go true KeyType/EOF)))
  ;; without `eof-quits?` the step sees the end of the input and cancels
  (is (nil? (go false KeyType/EOF)))
  (is (pos? @drawn))))

(deftest confirm-answers
 (let [ask #(apply run (fn [screen] (state/confirm! screen)) %&)]
  (is (true? (ask KeyType/Enter)))
  (is (false? (ask KeyType/Escape)))
  (is (= :quit (ask KeyType/EOF)))
  (is (= :back (ask :ctrl-x)))
  (is (true? (ask \x \y KeyType/ArrowUp KeyType/Enter)))))

(deftest menu-navigation
 (let [pages {:page1 {:actions {KeyType/ArrowRight :page2, KeyType/Enter :open}},
    :page2 {:actions {KeyType/ArrowLeft :page1}}}
   hotkeys {\o :page1}]
  (is (= :back (state/menu-after pages hotkeys :page1 :ctrl-x)))
  (is (= :quit (state/menu-after pages hotkeys :page1 KeyType/Escape)))
  (is (= :quit (state/menu-after pages hotkeys :page1 KeyType/EOF)))
  (is (= :open (state/menu-after pages hotkeys :page2 \o)))
  (is (= :page2 (state/menu-after pages hotkeys :page1 KeyType/ArrowRight)))
  (is (= :page2 (state/menu-after pages hotkeys :page2 \z)))
  (is (= :back (state/leave-key :ctrl-x)))
  (is (= :quit (state/leave-key KeyType/EOF)))
  (is (nil? (state/leave-key \a)))))

(deftest hotkey-preview
 (let [drawn (atom [])]
  (state/show-hotkey! #(swap! drawn conj %) nil :page1)
  (state/show-hotkey! #(swap! drawn conj %) :page1 :page1)
  (is (= [] @drawn))
  (state/show-hotkey! #(swap! drawn conj %) :page2 :page1)
  (is (= [:page2] @drawn))))
