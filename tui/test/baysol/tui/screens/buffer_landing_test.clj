;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The landing of the buffer run for real on a virtual terminal: every option, a project
;; with and without a buffer, with and without saved recipes, files that cannot be used,
;; cancelling everywhere, the prompts for a name and for a replacement.

(ns baysol.tui.screens.buffer-landing-test
 (:require [baysol.tui.buffer :as buffer]
  [baysol.tui.recipe-store :as recipe-store]
  [baysol.tui.screens.buffer-landing :as landing]
  [baysol.tui.support :as support :refer
   [background enter esc down up eof has? in-project]]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]]))



(def ^:private rows
 (:solutes (edn/read-string
   (slurp (io/file ".." "test" "fixtures" "buffer" "buffer.edn")))))

(def ^:private fixture-recipes
 (slurp (io/file ".." "test" "fixtures" "buffer" "recipes.edn")))

(defn ^:private run!-keys
 "Runs the landing for `dir` with `inputs` fed; returns what it returned and the text it
 ended on. A screen still waiting after 20 seconds is given escapes (`:timeout`)."
 [dir & inputs]
 (apply support/run-keys! #(landing/show! % background dir) inputs))

(defn ^:private snap
 "The text of the frame after `inputs`, ended by the terminal going away."
 [dir & inputs]
 (second (apply run!-keys dir (concat inputs [eof]))))

(defn ^:private save-buffer!
 [dir n]
 (buffer/write-solutes! dir (vec (take n rows))))


(deftest options-and-status
 (is (= ["load a recipe" "new recipe"] (map :label (landing/options 0))))
 (is (= ["load a recipe" "new recipe"]
   (map :label (landing/options ::landing/unusable))))
 (is (= ["edit current recipe (1 solute)" "load a recipe" "new recipe"
    "save current recipe globally"]
   (map :label (landing/options 1))))
 (is (= "edit current recipe (12 solutes)" (:label (first (landing/options 12)))))
 (is (= [:edit :load :new :save] (map :id (landing/options 3))))
 (is (= "buffer.edn: none yet" (landing/status-text 0)))
 (is (= "buffer.edn: 1 solute" (landing/status-text 1)))
 (is (= "buffer.edn: 12 solutes" (landing/status-text 12)))
 (is (= "buffer.edn unusable!" (landing/status-text ::landing/unusable)))
 (let [ls (landing/lines "demo" 12 0 nil)]
  (is (= 24 (count ls)))
  (is (every? #(<= (count %) 79) ls))
  (is (has? (nth ls 1) "buffer · demo"))
  (is (some #(has? % "> edit current recipe (12 solutes)") ls))
  (is (some #(has? % "buffer.edn: 12 solutes") ls)))
 (let [ls (landing/lines (apply str (repeat 200 "p")) 999 3 "m")]
  (is (every? #(<= (count %) 79) ls) "a long project name is cut")))

(deftest a-project-without-a-buffer
 (in-project
  (fn [_root dir]
   (let [text (snap dir)]
    (is (has? text "buffer · demo"))
    (is (has? text "> load a recipe"))
    (is (has? text "new recipe"))
    (is (has? text "buffer.edn: none yet"))
    (is (not (has? text "edit current")))
    (is (not (has? text "save current"))))
   (testing "the cursor moves, without wrapping"
    (let [text (snap dir down)]
     (is (has? text "> new recipe"))
     (is (not (has? text "> load a recipe"))))
    (is (has? (snap dir down down down) "> new recipe"))
    (is (has? (snap dir up) "> load a recipe")))
   (testing "keys that leave"
    (is (= :back (first (run!-keys dir :ctrl-x))))
    (is (= :quit (first (run!-keys dir esc))))
    (is (= :quit (first (run!-keys dir eof))))
    (is (= :quit (first (run!-keys dir "x" esc))) "letters do nothing")
    (is (= [] (buffer/read-solutes dir)) "nothing was written")))))

(deftest edit-current
 (in-project
  (fn [_root dir]
   (save-buffer! dir 3)
   (let [text (snap dir)]
    (is (has? text "> edit current recipe (3 solutes)"))
    (is (has? text "buffer.edn: 3 solutes"))
    (is (has? text "save current recipe globally")))
   (testing "Enter opens the table of the buffer, ctrl-x comes back to the landing"
    (let [[r text] (run!-keys dir enter :ctrl-x :ctrl-x)]
     (is (= :back r))
     (is (has? text "buffer · demo")))
    (let [text (snap dir enter)]
     (is (has? text "NaCl"))
     (is (has? text "[  1/3  ]"))))
   (testing "Escape in the table quits the program"
    (is (= :quit (first (run!-keys dir enter esc)))))
   (testing "what the table saves shows in the landing's count"
    (let [text (snap dir enter down :ctrl-r :ctrl-w :ctrl-x)]
     (is (has? text "edit current recipe (2 solutes)")))
    (is (= 2 (count (buffer/read-solutes dir))))))))

(deftest load-with-no-saved-recipes
 (in-project
  (fn [_root dir]
   (let [text (snap dir enter)]
    (is (has? text "no saved recipes!"))
    (is (has? text "> load a recipe")))
   (testing "the message goes at the next key"
    (is (not (has? (snap dir enter down) "no saved recipes!"))))
   (testing "an empty recipes file is no recipes either"
    (spit (recipe-store/recipes-file (io/file (.getParentFile (.getParentFile
         dir))))
     "{:recipes []}")
    (is (has? (snap dir enter) "no saved recipes!"))))))

(deftest load-a-recipe-without-a-buffer
 (in-project
  (fn [root dir]
   (spit (recipe-store/recipes-file root) fixture-recipes)
   (testing "the dropdown lists every recipe with its solute count"
    (let [text (snap dir enter)]
     (is (has? text "load a recipe  find: _"))
     (is (has? text "> SEC buffer (3)"))
     (is (has? text "Everything (11)"))
     (is (has? text "Customs (4)"))
     (is (has? text "empty (0)"))
     (is (has? text "1 of 4 matches"))))
   (testing "typing narrows it, Tab completes, up and down move"
    (is (has? (snap dir enter "eve") "> Everything (11)"))
    (is (not (has? (snap dir enter "eve") "SEC buffer (3)")))
    (is (has? (snap dir enter down) "> Everything (11)")))
   (testing "Escape cancels: the landing again, nothing written"
    (let [[r text] (run!-keys dir enter esc :ctrl-x)]
     (is (= :back r))
     (is (has? text "buffer · demo"))
     (is (not (has? text "find:"))))
    (is (= [] (buffer/read-solutes dir))))
   (testing "Enter opens the table with the recipe as drafts, nothing written"
    (let [text (snap dir enter "eve" enter)]
     (is (has? text "*NaCl"))
     (is (has? text "[  1/11 ]"))
     (is (not (has? text "replaces the current recipe"))))
    (is (= [] (buffer/read-solutes dir))))
   (testing "^w writes it; leaving without ^w drops it"
    (run!-keys dir enter "eve" enter :ctrl-x :ctrl-x)
    (is (= [] (buffer/read-solutes dir)))
    (run!-keys dir enter "eve" enter :ctrl-w :ctrl-x :ctrl-x)
    (is (= rows (buffer/read-solutes dir)))
    (is (has? (snap dir) "edit current recipe (11 solutes)")))
   (testing "an empty recipe loads as an empty draft table"
    (let [text (snap dir down enter "empty" enter)]
     (is (has? text "[  0/0  ]"))
     (is (has? text "replaces the current re…")))))))

(deftest load-a-recipe-over-a-buffer
 (in-project
  (fn [root dir]
   (spit (recipe-store/recipes-file root) fixture-recipes)
   (save-buffer! dir 2)
   (let [text (snap dir down enter "sec" enter)]
    (is (has? text "*NaCl"))
    (is (has? text "[  1/3  ]"))
    (is (has? text "replaces the current re…")))
   (is (= 2 (count (buffer/read-solutes dir))) "the buffer stands until ^w")
   (testing "^w replaces the buffer with the recipe, the note goes"
    (let [text (snap dir down enter "sec" enter :ctrl-w enter)]
     (is (has? text "saved"))
     (is (not (has? text "replaces the current recipe"))))
    (is (= (vec (take 3 rows)) (buffer/read-solutes dir)))))))

(deftest load-with-a-long-name-and-many-solutes
 (in-project
  (fn [root dir]
   (let [long-name (apply str (repeat 40 "N"))]
    (recipe-store/save-recipe! root long-name (vec (take 11 (cycle rows))))
    (recipe-store/save-recipe! root "big" (vec (take 150 (cycle rows))))
    (let [ls (str/split-lines (snap dir enter))]
     (is (every? #(<= (count %) 80) ls))
     (is (some #(has? % (str long-name " (11)")) ls))
     (is (some #(has? % "big (150)") ls)))
    (let [text (snap dir enter "big" enter)]
     (is (has? text "[  1/150]")))))))

(deftest new-recipe
 (in-project
  (fn [_root dir]
   (testing "without a buffer: an empty draft table, no note"
    (let [text (snap dir down enter)]
     (is (has? text "[  0/0  ]"))
     (is (has? text "no solutes: ^n ^p ^f ^e"))
     (is (not (has? text "nothing is replaced")))))
   (save-buffer! dir 3)
   (testing "over a buffer: the note says nothing is replaced until ^w"
    (let [text (snap dir down down enter)]
     (is (has? text "[  0/0  ]"))
     (is (has? text "nothing is replaced unt…")))
    (is (= 3 (count (buffer/read-solutes dir)))))
   (testing "leaving drops it, ^w replaces the buffer with the empty recipe"
    (is (= :back (first (run!-keys dir down down enter :ctrl-x :ctrl-x))))
    (is (= 3 (count (buffer/read-solutes dir))))
    (run!-keys dir down down enter :ctrl-w enter :ctrl-x :ctrl-x)
    (is (= [] (buffer/read-solutes dir)))))))

(deftest save-the-current-recipe-globally
 (in-project
  (fn [root dir]
   (save-buffer! dir 3)
   (let [to-save [down down down enter]]
    (testing "the prompt for a name is over the status box"
     (let [text (snap dir to-save "My buffer")]
      (is (has? text "save as"))
      (is (has? text "name: My buffer_"))
      (is (has? text "enter: accept  esc: cancel"))))
    (testing "Escape cancels: nothing saved"
     (let [text (snap dir to-save "x" esc)]
      (is (has? text "buffer.edn: 3 solutes"))
      (is (not (has? text "name:"))))
     (is (= [] (recipe-store/read-recipes root))))
    (testing "a blank name, a long name and a control character"
     (is (has? (snap dir to-save enter) "type a name first!"))
     (is (has? (snap dir to-save "   " enter) "type a name first!"))
     (let [text (snap dir to-save (apply str (repeat 41 "z")))]
      (is (has? text (apply str (repeat 40 "z"))))
      (is (not (has? text (apply str (repeat 41 "z")))) "typing stops at 40")))
    (testing "Enter saves the buffer as it is on disk"
     (let [text (snap dir to-save "My buffer" enter)]
      (is (has? text "saved as \"My buffer\""))
      (is (has? text "buffer.edn: 3 solutes")))
     (is (= [{:name "My buffer", :solutes (vec (take 3 rows))}]
       (recipe-store/read-recipes root))))
    (testing "the message goes at the next key"
     (is (not (has? (snap dir to-save "Other" enter up) "saved as"))))
    (testing "an existing name asks; Escape keeps, Enter replaces"
     (save-buffer! dir 1)
     (let [text (snap dir to-save "my BUFFER" enter)]
      (is (has? text "replace \"my BUFFER\"?"))
      (is (has? text "enter: replace  esc: keep")))
     (let [text (snap dir to-save "my BUFFER" enter esc)]
      (is (has? text "not saved"))
      (is (not (has? text "replace \""))))
     (is (= 3 (count (recipe-store/recipe-solutes root "My buffer"))))
     (let [text (snap dir to-save "my BUFFER" enter enter)]
      (is (has? text "saved as \"my BUFFER\"")))
     (is (= 1 (count (recipe-store/recipe-solutes root "my buffer"))))
     (is (= ["my BUFFER" "Other"] (map :name (recipe-store/read-recipes root)))
      "replaced in place, the other kept"))
    (testing "a draft in the table is not what is saved: the saved buffer is"
     (run!-keys dir enter :ctrl-p esc :ctrl-x :ctrl-x)
     (is (= 1 (count (recipe-store/recipe-solutes root "my buffer")))))))))

(deftest files-that-cannot-be-used
 (in-project
  (fn [root dir]
   (testing "an unusable recipes.edn: told on load and on save, never written over"
    (save-buffer! dir 2)
    (spit (recipe-store/recipes-file root) "{:recipes [1]}")
    (is (has? (snap dir down enter) "recipes.edn unusable!"))
    (is (has? (snap dir down down down enter "x" enter) "recipes.edn unusable!"))
    (is (= "{:recipes [1]}" (slurp (recipe-store/recipes-file root)))))
   (testing "an unusable buffer.edn: told, no edit and no save, nothing opens"
    (spit (buffer/buffer-file dir) "{:solutes [{:kind :nope}]}")
    (let [text (snap dir)]
     (is (has? text "buffer.edn unusable!"))
     (is (not (has? text "edit current")))
     (is (not (has? text "save current"))))
    (is (has? (snap dir enter) "buffer.edn unusable!"))
    (is (has? (snap dir down enter) "buffer.edn unusable!"))
    (is (has? (snap dir down enter) "> new recipe"))
    (is (= "{:solutes [{:kind :nope}]}" (slurp (buffer/buffer-file dir))))))))
