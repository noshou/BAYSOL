;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The custom solutes screen run for real on a virtual terminal (entries are made in the
;; form pages it opens: ^n, ^p and Enter), and its key in the global settings menu (and not
;; in a project's).

(ns baysol.tui.screens.custom-solutes-menu-test
 (:require [baysol.tui.core.app :as app]
  [baysol.tui.custom-store :as store]
  [baysol.tui.screens.custom-solutes-menu :as menu]
  [baysol.tui.screens.settings-menu :as settings-menu]
  [baysol.tui.support :as support :refer [background enter down]]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))



(defn ^:private run!-keys
 "Runs the screen with `inputs` fed; returns what it returned and the text it ended on
 (`:timeout` for a screen still waiting for a key)."
 [& inputs]
 (apply support/run-keys! #(menu/show! % background) inputs))


(def ^:private right KeyType/ArrowRight)

(def ^:private left KeyType/ArrowLeft)

(def ^:private backspace KeyType/Backspace)

(def ^:private add-nonbio
 "^n, then in the form: name, formula (Z computed), PMV (Z skipped), ±; ^w accepts."
 [:ctrl-n enter "NACE" enter down enter "C7H13NO3S" enter down down enter "118.4"
  enter
  down enter "4" enter :ctrl-w])

(def ^:private add-polymer
 "^p, then in the form: name, unit A formula (label and Z follow), slope, ± of the unit,
 the ends: Z, PMV, ± blank; ^w accepts."
 [:ctrl-p enter "chain" enter down right enter "(C2H4O)n" enter right right enter
  "36.73"
  enter right enter "0.37" enter down down down down left left enter "10" enter
  right
  enter "19.24" enter :ctrl-w])

(def ^:private chain-4
 "The four-unit polymer of the frozen fixture."
 (nth (:solutes (edn/read-string
    (slurp
     (io/file ".." "test" "fixtures" "buffer" "custom-solutes.edn"))))
  3))

(deftest the-screen-runs
 (support/with-data-folder
  [root (support/temp-root)]
  (testing "empty: leaves, no rmv legend, both add legends there"
   (let [[r text] (run!-keys :ctrl-x)]
    (is (= :back r))
    (is (str/includes? text "[  0/0  ]"))
    (is (str/includes? text "add nonbio:"))
    (is (str/includes? text "add polymer:"))
    (is (not (str/includes? text "rmv:"))))
   (is (= :quit (first (run!-keys KeyType/Escape)))))
  (testing "a non-biological entry and a polymer are drafts until ^w"
   (let [[_ text] (apply run!-keys (concat add-nonbio add-polymer [:ctrl-x]))]
    (is (str/includes? text "*NACE"))
    (is (str/includes? text "C7H13NO3S"))
    (is (str/includes? text "102"))
    (is (str/includes? text "118.4"))
    (is (str/includes? text "*chain"))
    (is (str/includes? text "A:C2H4O"))
    (is (str/includes? text "24A+10"))
    (is (str/includes? text "36.73A+19"))
    (is (str/includes? text "0.37"))
    (is (str/includes? text "custom [  2/2  ]"))
    (is (str/includes? text "rmv:")))
   (is (= [] (store/read-solutes root)) "nothing was written"))
  (testing "^w writes them to the global file and the marks go"
   (let [[_ text] (apply run!-keys
      (concat add-nonbio add-polymer [:ctrl-w :ctrl-x]))]
    (is (not (str/includes? text "*NACE")))
    (is (str/includes? text "saved")))
   (is (= [{:kind :nonbiological,
       :name "NACE",
       :formula "C7H13NO3S",
       :z 102,
       :pmv 118.4,
       :sigma 4.0}
      {:kind :polymer,
       :name "chain",
       :z-ends 10,
       :pmv-ends 19.24,
       :sigma-ends nil,
       :units
       [{:label "A", :formula "C2H4O", :z 24, :slope 36.73, :sigma 0.37}]}]
     (store/read-solutes @app/app-dir))))
  (testing "^r marks with -, ^u takes it back, ^w then removes"
   (let [[_ text] (run!-keys :ctrl-r :ctrl-x)]
    (is (str/includes? text "-NACE")))
   (let [[_ text] (run!-keys :ctrl-r :ctrl-u :ctrl-x)]
    (is (not (str/includes? text "-NACE"))))
   (is (= 2 (count (store/read-solutes root))))
   (run!-keys :ctrl-r :ctrl-w :ctrl-x)
   (is (= ["chain"] (map :name (store/read-solutes root)))))
  (testing "Enter opens the form of the row; ^w there makes a draft, ^u drops it"
   (let [[_ text] (run!-keys enter enter "NEW" enter :ctrl-w :ctrl-x)
     [_ undone] (run!-keys enter enter "NEW" enter :ctrl-w :ctrl-u :ctrl-x)]
    (is (str/includes? text "*chainNEW") "the form starts from the row's name")
    (is (str/includes? undone "chain"))
    (is (not (str/includes? undone "NEW")))))
  (testing "Esc in the form changes nothing and adds no row"
   (let [[_ text] (run!-keys enter enter "NEW" enter KeyType/Escape :ctrl-x)]
    (is (not (str/includes? text "NEW")))
    (is (not (str/includes? text "*"))))
   (let [[_ text] (run!-keys :ctrl-n
      enter
      "ZZ"
      enter
      KeyType/Escape
      :ctrl-p
      KeyType/Escape
      :ctrl-x)]
    (is (str/includes? text "[  1/1  ]"))
    (is (not (str/includes? text "ZZ")))))
  (testing "blank ± shows the fallback or (2%); the stored ± is nil"
   (run!-keys :ctrl-r :ctrl-w :ctrl-x)
   (let [[_ text] (run!-keys
      :ctrl-n
      enter
      "A"
      enter
      down
      enter
      "NaCl"
      enter
      down
      down
      enter
      "10"
      enter
      :ctrl-w
      :ctrl-p
      enter
      "B"
      enter
      down
      right
      enter
      "C2H4O"
      enter
      right
      right
      enter
      "1"
      enter
      down
      down
      down
      down
      left
      enter
      "5"
      enter
      right
      enter
      "2" enter
      :ctrl-w :ctrl-x)]
    (is (str/includes? text "(3.04)"))
    (is (str/includes? text "(2%)")))
   (run!-keys :ctrl-n
    enter
    "A"
    enter
    down
    enter
    "NaCl"
    enter
    down
    down
    enter
    "10"
    enter
    :ctrl-w
    :ctrl-w
    :ctrl-x)
   (is (= {:kind :nonbiological,
      :name "A",
      :formula "NaCl",
      :z 28,
      :pmv 10.0,
      :sigma nil}
     (first (store/read-solutes root)))))
  (testing "the form refuses an incomplete, used or built-in entry and tells why"
   (let [[r text] (run!-keys :ctrl-n
      enter
      "x"
      enter
      down
      enter
      "Xx" enter
      :ctrl-w
      KeyType/EOF)]
    (is (= :quit r))
    (is (str/includes? text "╚═ formula unknown")))
   (let [[_ text] (run!-keys :ctrl-n
      enter
      "a"
      enter
      down
      enter
      "NaCl"
      enter
      down
      down
      enter
      "1" enter
      :ctrl-w KeyType/EOF)]
    (is (str/includes? text "╚═ name in use")))
   (let [[_ text] (run!-keys :ctrl-n
      enter
      "PEG"
      enter
      down
      enter
      "NaCl"
      enter
      down
      down
      enter
      "1" enter
      :ctrl-w KeyType/EOF)]
    (is (str/includes? text "╚═ name is built-in")))
   (let [[_ text] (run!-keys :ctrl-n
      enter
      "NaCl"
      enter
      down
      enter
      "NaCl"
      enter
      down
      down
      enter
      "1" enter
      :ctrl-w KeyType/EOF)]
    (is (str/includes? text "╚═ name is built-in")))
   (is (= 1 (count (store/read-solutes root)))))
  (testing "an unknown formula can still be given a Z by hand"
   (run!-keys :ctrl-n
    enter
    "q"
    enter
    down
    enter
    "Xx"
    enter
    down
    enter
    "77"
    enter
    down
    enter
    "1"
    enter
    :ctrl-w
    :ctrl-w
    :ctrl-x)
   (is (= 77 (:z (second (store/read-solutes root))))))
  (testing "the arrows come with the second row"
   (let [[_ text] (run!-keys KeyType/ArrowUp :ctrl-x)]
    (is (re-find #"move: +↓" text)))
   (let [[_ text] (run!-keys KeyType/ArrowDown :ctrl-x)]
    (is (re-find #"move: +↑" text))))))

(deftest polymer-display
 (support/with-data-folder
  [root (support/temp-root)]
  (let [two {:kind :polymer,
     :name "two",
     :z-ends 9,
     :pmv-ends 9.0,
     :sigma-ends nil,
     :units [{:label "A", :formula "C2H4O", :z 24, :slope 36.9, :sigma nil}
      {:label "B", :formula "CH2", :z 8, :slope 5.3, :sigma nil}]}
    neg {:kind :polymer,
     :name "neg",
     :z-ends 3,
     :pmv-ends 3,
     :sigma-ends nil,
     :units
     [{:label "X", :formula "C2H4O", :z 24, :slope -5.2, :sigma 0.25}]}
    diff (-> two
     (assoc :name "diff")
     (assoc-in [:units 0 :sigma] 0.1)
     (assoc-in [:units 1 :sigma] 0.2))]
   (store/write-solutes! root [two neg diff chain-4])
   (let [[_ text] (run!-keys :ctrl-x)
     line (fn [n] (first (filter #(str/includes? % n) (str/split-lines text))))]
    (testing "the unit formulas joined, Z and PMV by label, then the ends"
     (is (str/includes? (line "two") "A:C2H4O B:CH2"))
     (is (str/includes? (line "two") "24A+8B+9"))
     (is (str/includes? (line "two") "36.9A+5.3")))
    (testing "the first unit's ±, (2%) when blank, a leading minus kept"
     (is (str/includes? (line "two") "(2%)"))
     (is (str/includes? (line "neg") "0.25"))
     (is (str/includes? (line "neg") "-5.2X+3"))
     (is (str/includes? (line "neg") "24X+3")))
    (testing "units with different ± show an ellipsis"
     (is (re-find #"…\s*║\s*$" (line "diff")))
     (is (not (re-find #"…\s*║\s*$" (line "two")))))
    (testing "what the cells cannot hold is cut with an ellipsis"
     (is (str/includes? (line "chain-4") "A:C2H4O B:C3H"))
     (is (str/includes? (line "chain-4") "10A+20B+30"))
     (is (str/includes? (line "chain-4") "1A+2B+3C+")))))))

(deftest editing-a-multi-unit-polymer-in-its-form
 (support/with-data-folder
  [root (support/temp-root)]
  (store/write-solutes! root [chain-4])
  ;; Enter opens the form: the name gets an x, the slope of unit A goes from 1 to 2, the
  ;; slope of unit D from 4 to 8; accepted with ^w, saved with the table's ^w
  (run!-keys enter
   enter
   "x"
   enter
   down
   right
   right
   right
   enter
   backspace
   "2"
   enter
   down
   down
   down
   enter
   backspace
   "8"
   enter
   :ctrl-w
   :ctrl-w
   :ctrl-x)
  (let [saved (first (store/read-solutes root))]
   (is (= "chain-4x" (:name saved)))
   (is (= 4 (count (:units saved))))
   (is (= 2.0 (:slope (first (:units saved)))))
   (is (= 8.0 (:slope (last (:units saved)))) "unit D is editable now")
   (is (= (butlast (rest (:units chain-4))) (butlast (rest (:units saved))))
    "B and C untouched")
   (is (= (select-keys chain-4 [:z-ends :pmv-ends :sigma-ends])
     (select-keys saved [:z-ends :pmv-ends :sigma-ends]))))
  (testing "a unit is removed by clearing its row"
   (let [clear-d
     (mapcat
      (fn [col]
       (concat [enter] (repeat 20 backspace) [enter] (when (< col 4) [right])))
      (range 5))]
    (apply run!-keys
     (concat [enter down down down down] clear-d [:ctrl-w :ctrl-w :ctrl-x])))
   (is (= 3 (count (:units (first (store/read-solutes root)))))))))

(deftest a-polymer-without-end-groups-cannot-be-accepted
 (support/with-data-folder
  [root (support/temp-root)]
  (let [[_ text] (run!-keys :ctrl-p
     enter
     "c"
     enter
     down
     right
     enter
     "C2H4O"
     enter
     right
     right
     enter
     "1" enter
     :ctrl-w KeyType/EOF)]
   (is (str/includes? text "╚═ end groups needed")))
  (let [[_ text] (run!-keys :ctrl-p
     enter
     "c"
     enter
     down
     right
     enter
     "C2H4O"
     enter
     right
     right
     enter
     "1"
     enter
     :ctrl-w
     KeyType/Escape
     :ctrl-x)]
   (is (str/includes? text "[  0/0  ]") "left with Esc: no row"))
  (is (= [] (store/read-solutes root)))))

(deftest a-file-that-cannot-be-used
 (support/with-data-folder
  [root (support/temp-root)]
  (spit (store/custom-file root) "{:solutes")
  (let [[r text] (run!-keys :ctrl-n :ctrl-w :ctrl-x)]
   (is (= :back r))
   (is (str/includes? text "custom-solutes.e…")))
  (is (= "{:solutes" (slurp (store/custom-file root))))))

(deftest at-most-999-entries
 (support/with-data-folder
  [root (support/temp-root)]
  (let [e (fn [i]
     {:kind :nonbiological,
      :name (str "s" i),
      :formula "NaCl",
      :z 28,
      :pmv 1.0,
      :sigma nil})]
   (store/write-solutes! root (mapv e (range 999)))
   (let [[r text] (run!-keys :ctrl-n :ctrl-p :ctrl-x)]
    (is (= :back r))
    (is (str/includes? text "[  1/999]"))
    (is (not (str/includes? text "add nonbio:")))
    (is (not (str/includes? text "add polymer:")))
    (is (str/includes? text "rmv:")))
   (is (= 999 (count (store/read-solutes root)))))))

(deftest ctrl-e-in-the-global-settings-menu-only
 (support/with-data-folder
  [root (support/temp-root)]
  (testing
   "global: ctrl-e opens the landing, its `solutes` the table; ctrl-x goes back"
   (let [vs (support/virtual-screen)]
    (support/feed! vs
     :ctrl-e
     KeyType/ArrowDown
     enter
     :ctrl-n
     enter
     "G"
     enter
     down
     enter
     "NaCl"
     enter
     down
     down
     enter
     "5"
     enter
     :ctrl-w
     :ctrl-w :ctrl-x
     :ctrl-x :ctrl-x)
    (is (= :back (settings-menu/show! (:screen vs) background)))
    (is (= 1 (count (store/read-solutes root))))
    (is (str/includes? (support/screen-text vs) "solutes: ctrl+e"))))
  (testing "global: escape in the table quits the program"
   (let [vs (support/virtual-screen)]
    (support/feed! vs :ctrl-e KeyType/ArrowDown enter KeyType/Escape)
    (is (= :quit (settings-menu/show! (:screen vs) background)))))
  (testing "a project's settings menu has no such key"
   (let [vs (support/virtual-screen)]
    (support/feed! vs :ctrl-e :ctrl-x)
    (is (= :back
      (settings-menu/show! (:screen vs)
       background
       (settings-menu/project-opts (support/temp-root)))))
    (is (not (str/includes? (support/screen-text vs) "custom [")))))))
