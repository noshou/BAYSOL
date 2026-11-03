;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The recipes table run for real on a virtual terminal: the cells, adding with a name,
;; renaming, removing, saving, the 999 cap, long names, the file that cannot be used.

(ns baysol.tui.screens.recipes-menu-test
 (:require [baysol.tui.recipe-store :as store]
  [baysol.tui.screens.recipes-menu :as menu]
  [baysol.tui.screens.table :as table]
  [baysol.tui.support :as support :refer
   [background enter esc down up eof has?]]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))


(def ^:private bs (vec (repeat 45 KeyType/Backspace)))

(def ^:private fixture-recipes
 (slurp (io/file ".." "test" "fixtures" "buffer" "recipes.edn")))

(defn ^:private with-recipes
 "Calls `f` with a temporary BAYSOL folder holding the fixture recipes (or `text`)."
 ([f] (with-recipes fixture-recipes f))
 ([text f]
  (support/with-data-folder
   [root (support/temp-root)]
   (when text (spit (store/recipes-file root) text))
   (f root))))

(defn ^:private run!-keys
 [& inputs]
 (apply support/run-keys! #(menu/show! % background) inputs))

(defn ^:private snap [& inputs] (second (apply run!-keys (concat inputs [eof]))))


(defn ^:private names [root] (mapv :name (store/read-recipes root)))

(defn ^:private frame-ok?
 "Whether every table row of the frame has its borders where the art has them and no
 line is wider than the screen."
 [text]
 (let [lines (str/split-lines text)
   bounds (:bounds menu/art)]
  (and (= 24 (count lines))
   (every? #(<= (count %) 80) lines)
   (every? (fn [i]
     (every? #(= \║ (.charAt ^String (nth lines i) %))
      [(first bounds) (last bounds)]))
    (range 2 20)))))

(deftest the-art
 (is (= 18 (table/window menu/art)))
 (is (= 3 (count (:spans menu/art))))
 (is (some? (:counter menu/art)))
 (is (some? (:arrows menu/art))))

(deftest rows-and-columns
 (with-recipes
  (fn [_root]
   (let [text (snap)]
    (is (frame-ok? text))
    (is (has? text "name"))
    (is (has? text "solutes"))
    (is (has? text "SEC buffer"))
    (is (has? text "1 solute 2 polymer"))
    (is (has? text "1 solute 3 polymer 4 custom 3 seq") "fits the 36-wide column")
    (is (has? text "none") "the empty recipe")
    (is (has? text "recipes [  1/4  ]"))
    (is (has? text "new recipe:"))
    (is (has? text "rmv:")))
   (testing "the cursor"
    (is (re-find #">\s+║ SEC" (snap)))
    (is (has? (snap down down) "recipes [  3/4  ]"))
    (is (has? (snap up) "recipes [  1/4  ]"))
    (is (has? (snap down down down down down) "recipes [  4/4  ]"))))))

(deftest keys-that-leave
 (with-recipes
  (fn [_root]
   (is (= :back (first (run!-keys :ctrl-x))))
   (is (= :quit (first (run!-keys esc))))
   (is (= :quit (first (run!-keys eof))))
   (testing "escape in the editor of a recipe quits the program"
    (is (= :quit (first (run!-keys enter enter esc)))))
   (testing "ctrl-x in the editor comes back to the table"
    (is (= :back (first (run!-keys enter enter :ctrl-x :ctrl-x))))))))

(deftest no-recipes
 (with-recipes nil
  (fn [_root]
   (let [text (snap)]
    (is (frame-ok? text))
    (is (has? text "none: ^n adds"))
    (is (has? text "recipes [  0/0  ]"))
    (is (not (has? text "rmv:")))
    (is (not (has? text "edit:")))
    (is (has? text "new recipe:")))
   (testing "keys with nothing to act on do nothing"
    (is (has? (snap enter :ctrl-r :ctrl-u down up)
      "none: ^n adds"))))))

(deftest removing-undoing-saving
 (with-recipes
  (fn [root]
   (is (has? (snap down :ctrl-r) "-Everything"))
   (is (not (has? (snap down :ctrl-r :ctrl-u) "-Everything")))
   (testing "leaving without ^w drops the mark"
    (run!-keys down :ctrl-r :ctrl-x)
    (is (= 4 (count (names root)))))
   (testing "^w removes what is marked, and only that"
    (let [text (snap down :ctrl-r :ctrl-w)]
     (is (has? text "saved"))
     (is (not (has? text "Everything"))))
    (is (= ["SEC buffer" "Customs" "empty"] (names root)))
    (is (= 3 (count (store/recipe-solutes root "SEC buffer")))))
   (testing "Enter on a row marked for removal does nothing"
    (is (not (has? (snap :ctrl-r enter) "recipe name"))))
   (testing "the last recipe removed leaves rmv and edit gone"
    (let [text (snap :ctrl-r :ctrl-w :ctrl-r :ctrl-w :ctrl-r :ctrl-w)]
     (is (has? text "none: ^n adds"))
     (is (not (has? text "rmv:"))))
    (is (= [] (names root)))))))

(deftest a-new-recipe
 (with-recipes
  (fn [root]
   (testing "^n asks a name over the table"
    (let [text (snap :ctrl-n "Fresh")]
     (is (has? text "recipe name"))
     (is (has? text "name: Fresh_"))
     (is (frame-ok? (str/join "\n" (take 24 (str/split-lines text))))
      "the frame stays")))
   (testing "Enter opens the editor on the empty recipe; nothing is written yet"
    (let [text (snap :ctrl-n "Fresh" enter)]
     (is (has? text "recipe: Fresh"))
     (is (has? text "no solutes: ^n ^p ^f ^e")))
    (is (= 4 (count (names root)))))
   (testing "back at the table it is a draft row, written empty by ^w"
    (let [text (snap :ctrl-n "Fresh" enter :ctrl-x)]
     (is (has? text "*Fresh"))
     (is (has? text "recipes [  5/5  ]")))
    (is (= 4 (count (names root))))
    (run!-keys :ctrl-n "Fresh" enter :ctrl-x :ctrl-w :ctrl-x)
    (is (= ["SEC buffer" "Everything" "Customs" "empty" "Fresh"] (names root)))
    (is (= [] (store/recipe-solutes root "fresh"))))
   (testing "Escape cancels the prompt: nothing added"
    (is (has? (snap :ctrl-n "x" esc) "recipes [  1/5  ]"))
    (is (not (has? (snap :ctrl-n "x" esc) "name:"))))
   (testing "a blank name and a bad one are told"
    (is (has? (snap :ctrl-n enter) "type a name first!"))
    (is (has? (snap :ctrl-n "a\tb") "name: ab_") "a tab is not typed")))))

(deftest the-editor-writes-the-recipe-at-once
 (with-recipes
  (fn [root]
   (run!-keys :ctrl-n
    "Mine"
    enter
    :ctrl-p
    "tris"
    enter
    "10"
    enter
    "0.5"
    enter
    :ctrl-w
    :ctrl-x
    :ctrl-x)
   (is (= 5 (count (names root))) "written by the editor's ^w, no table ^w needed")
   (is (= 1 (count (store/recipe-solutes root "Mine"))))
   (testing "the row is no longer a draft"
    (let [text (snap :ctrl-n "Mine2" enter :ctrl-x)]
     (is (has? text "*Mine2"))))
   (testing "adding with the name of the written recipe is refused"
    (is (has? (snap :ctrl-n "Mine" enter) "name in use") "Mine exists now"))
   (testing "editing an existing recipe through Enter"
    (run!-keys enter enter :ctrl-r :ctrl-w :ctrl-x :ctrl-x)
    (is (= 2 (count (store/recipe-solutes root "SEC buffer"))))))))

(deftest names-clash-case-insensitively
 (with-recipes
  (fn [root]
   (testing "adding with a clashing name is refused, the prompt stays"
    (let [text (snap :ctrl-n "everything" enter)]
     (is (has? text "name in use"))
     (is (has? text "name: everything_"))
     (is (not (has? text "recipe: everything"))))
    (is (has? (snap :ctrl-n "EMPTY " enter) "name in use"))
    (is (= 4 (count (names root)))))
   (testing "a rejected name can be corrected"
    (let [text (snap :ctrl-n "everything" enter bs "ok" enter)]
     (is (has? text "recipe: ok"))))
   (testing "a name marked for removal still counts"
    (is (has? (snap down :ctrl-r :ctrl-n "everything" enter) "name in use"))))))

(deftest renaming
 (with-recipes
  (fn [root]
   (testing "Enter asks the name first, prefilled"
    (let [text (snap enter)]
     (is (has? text "recipe name"))
     (is (has? text "name: SEC buffer_"))
     (is (not (has? text "recipe: SEC")) "the editor is not open yet")))
   (testing "Escape cancels the whole action"
    (let [text (snap enter bs "x" esc)]
     (is (has? text "SEC buffer"))
     (is (not (has? text "*"))))
    (is (not (has? (snap enter esc) "recipe: SEC"))))
   (testing "to a free name: a draft, the editor opens on the new name"
    (let [text (snap enter bs "Renamed" enter)]
     (is (has? text "recipe: Renamed"))
     (is (has? text "NaCl") "the solutes came along")
     (is (has? text "[  1/3  ]")))
    (let [text (snap enter bs "Renamed" enter :ctrl-x)]
     (is (has? text "*Renamed"))
     (is (not (has? text "SEC buffer")))
     (is (has? text "recipes [  1/4  ]")))
    (is (= "SEC buffer" (first (names root))) "a rename is a draft until ^w"))
   (testing "^w writes it under the new name: the old one is gone, the solutes stay"
    (run!-keys enter bs "Renamed" enter :ctrl-x :ctrl-w :ctrl-x)
    (is (= ["Renamed" "Everything" "Customs" "empty"] (names root)))
    (is (= 3 (count (store/recipe-solutes root "Renamed")))))
   (testing "to another recipe's name: refused, in any case, nothing changes"
    (let [text (snap enter bs "EVERYTHING" enter)]
     (is (has? text "name in use"))
     (is (not (has? text "recipe: EVERYTHING"))))
    (let [text (snap enter bs "customs" enter esc)]
     (is (not (has? text "*"))))
    (is (= ["Renamed" "Everything" "Customs" "empty"] (names root))))
   (testing "a case-only rename is allowed"
    (let [text (snap enter bs "RENAMED" enter :ctrl-x)]
     (is (has? text "*RENAMED")))
    (run!-keys enter bs "RENAMED" enter :ctrl-x :ctrl-w :ctrl-x)
    (is (= ["RENAMED" "Everything" "Customs" "empty"] (names root))))
   (testing "keeping the name opens the editor with no draft"
    (let [text (snap enter enter :ctrl-x)]
     (is (not (has? text "*")))))
   (testing "^u undoes a rename"
    (let [text (snap enter bs "Other" enter :ctrl-x :ctrl-u)]
     (is (has? text "RENAMED"))
     (is (not (has? text "Other")))
     (is (not (has? text "*"))))))))

(deftest rename-then-the-editors-save-then-the-tables
 (testing "the editor's ^w writes the recipe under its CURRENT name, at once"
  (with-recipes
   (fn [root]
    (run!-keys enter bs "Renamed" enter :ctrl-r :ctrl-w :ctrl-x :ctrl-x)
    (is (some #{"Renamed"} (names root)))
    (is (= 2 (count (store/recipe-solutes root "Renamed")))))))
 (testing "the row still shows as a draft until the table's ^w"
  (with-recipes
   (fn [_root]
    (let [text (snap enter bs "Renamed" enter :ctrl-r :ctrl-w :ctrl-x)]
     (is (has? text "*Renamed"))
     (is (not (has? text "SEC buffer")))))))
 (testing "the table's ^w leaves exactly one recipe under the new name"
  (with-recipes
   (fn [root]
    (run!-keys enter bs "Renamed" enter :ctrl-r :ctrl-w :ctrl-x :ctrl-w :ctrl-x)
    (is (= ["Renamed" "Everything" "Customs" "empty"] (names root)))
    (is (= 1 (count (filter #(= "renamed" (str/lower-case %)) (names root)))))
    (is (= 2 (count (store/recipe-solutes root "Renamed")))))))
 (testing "a case-only rename saved by the editor needs no second save"
  (with-recipes
   (fn [root]
    (let [text (snap enter bs "sec BUFFER" enter :ctrl-w :ctrl-x)]
     (is (has? text "sec BUFFER"))
     (is (not (has? text "*"))))
    (is (= "sec BUFFER" (first (names root))))))))

(deftest the-cap-long-names-and-three-digit-rows
 (let [long-name (apply str (repeat 40 "W"))
   many (mapv (fn [i]
     {:name (if (= i 5) long-name (str "recipe " i)), :solutes []})
    (range 999))]
  (with-recipes (pr-str {:recipes many})
   (fn [_root]
    (let [text (snap)]
     (is (frame-ok? text))
     (is (has? text "recipes [  1/999]"))
     (is (not (has? text "new recipe:")) "the legend is gone at 999")
     (is (has? text "rmv:"))
     (is (has? text "undo:")))
    (testing "^n does nothing at 999"
     (is (not (has? (snap :ctrl-n) "recipe name"))))
    (testing "three-digit row numbers and the scroll"
     (let [text (apply snap (repeat 100 down))]
      (is (frame-ok? text))
      (is (has? text "recipes [101/999]"))
      (is (has? text "recipe 100"))))
    (testing "a long name is cut or whole, never over the border"
     (let [text (apply snap (repeat 5 down))]
      (is (frame-ok? text))
      (is (has? text (subs long-name 0 20)))))
    (testing "the last row"
     (let [text (apply snap (repeat 1100 down))]
      (is (has? text "recipes [999/999]"))
      (is (frame-ok? text))))))))

(deftest a-recipe-name-in-a-prompt-is-never-over-the-border
 (let [long-name (apply str (repeat 40 "W"))]
  (with-recipes (pr-str {:recipes [{:name long-name, :solutes []}]})
   (fn [_root]
    (let [text (snap enter)]
     (is (frame-ok? text))
     (is (every? #(<= (count %) 80) (str/split-lines text)))
     (is (has? text (str "name: " long-name "_"))))))))

(deftest a-file-that-cannot-be-used
 (doseq [bad ["{:recipes [1]}" "[1 2]" "{:recipes ["]]
  (with-recipes bad
   (fn [root]
    (let [text (snap)]
     (is (has? text "recipes.edn unusable!"))
     (is (not (has? text "none: ^n adds"))
      "no invitation to add to a file never written")
     (is (frame-ok? text))
     (is (not (has? text "new recipe:"))))
    (testing "nothing is editable, nothing is written"
     (is (has? (snap :ctrl-n "x" enter :ctrl-w enter :ctrl-r)
       "recipes.edn unusable!"))
     (is (= bad (slurp (store/recipes-file root)))))
    (is (= :back (first (run!-keys :ctrl-x))))
    (is (= :quit (first (run!-keys esc))))))))
