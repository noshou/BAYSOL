;; SPDX-License-Identifier: LGPL-3.0-or-later

;; What leaving a table or a sheet with changes that were not saved asks (`discard N
;; changes?`), the question before a recipe replaces a buffer that has solutes, the reset of
;; a file that cannot be used, and the tables that do not invite adding to such a file. Each
;; test runs the real screen on a virtual terminal. The texts are read from the frame the
;; screen drew last, which the end of the input (`eof`) leaves on the screen.

(ns baysol.tui.screens.discard-test
 (:require [baysol.tui.buffer :as buffer]
  [baysol.tui.custom-store :as custom-store]
  [baysol.tui.draft :as draft]
  [baysol.tui.recipe-store :as recipe-store]
  [baysol.tui.screens.buffer-landing :as buffer-landing]
  [baysol.tui.screens.custom-landing :as custom-landing]
  [baysol.tui.screens.custom-solutes-menu :as custom-menu]
  [baysol.tui.screens.loop :as lp]
  [baysol.tui.screens.recipes-menu :as recipes-menu]
  [baysol.tui.screens.sheets :as sheets]
  [baysol.tui.screens.solutes-menu :as solutes-menu]
  [baysol.tui.settings :as settings]
  [baysol.tui.support :as support :refer
   [background enter esc down eof has? in-project]]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))

(def ^:private rows
 (:solutes (edn/read-string
   (slurp (io/file ".." "test" "fixtures" "buffer" "buffer.edn")))))

(def ^:private fixture-recipes
 (slurp (io/file ".." "test" "fixtures" "buffer" "recipes.edn")))

(def ^:private backspace KeyType/Backspace)

(defn ^:private run-with
 "`(show! screen)` run with `inputs` fed: `[result text]`."
 [show! & inputs]
 (apply support/run-keys! show! inputs))

(defn ^:private snap
 "The text of the frame of `show!` after `inputs`, ended by the terminal going away."
 [show! & inputs]
 (second (apply run-with show! (concat inputs [eof]))))

;; one solute made in the table of a buffer: a draft row `*tris`
(def ^:private add-tris [:ctrl-n "tris" enter "10" enter "0.5" enter])

;; --- draft and the shared loop

(deftest the-changes-of-a-state
 (let [s (draft/initial [:a :b :c])]
  (is (= 0 (draft/changes s)))
  (is (= 1 (draft/changes (draft/set-draft s 0 :a2))))
  (is (= 2
    (draft/changes (-> s
      (draft/set-draft 0 :a2)
      (draft/remove-row 1)))))
  (is (= 3
    (draft/changes (-> s
      (draft/add-draft :d)
      (draft/add-draft :e)
      (draft/remove-row 0)))))
  (is (= 0 (draft/changes (draft/commit (draft/add-draft s :d)))))
  (is (= 0 (draft/changes nil)))))

(defn ^:private loop-screen
 "A table loop over a state with one draft row (`dirty?`) or none; `\\q` ends it with :quit.
 The frame shows the note."
 [dirty?]
 #(lp/run-table! %
  background
  {:init {:s (cond-> (draft/initial []) dirty? (draft/add-draft :x)),
    :offset 0},
   :frame (fn [st] {:lines [(str "note: " (:note st))], :offset 0}),
   :handle (fn [st input] (if (= input \q) :quit st))}))

(deftest the-loop-asks-before-leaving-with-changes
 (testing "nothing unsaved: no question"
  (is (= :back (first (run-with (loop-screen false) :ctrl-x))))
  (is (= :quit (first (run-with (loop-screen false) esc)))))
 (testing "the question is in the note, with its keys"
  (let [text (snap (loop-screen true) :ctrl-x)]
   (is (has? text "discard 1 change?"))
   (is (has? text "enter: discard"))
   (is (has? text "esc: keep"))))
 (testing "Enter leaves as the key meant, Escape and Ctrl-X stay"
  (is (= :back (first (run-with (loop-screen true) :ctrl-x enter))))
  (is (= :quit (first (run-with (loop-screen true) esc enter))))
  (is (= :quit (first (run-with (loop-screen true) :ctrl-x esc \q))))
  (is (= :quit (first (run-with (loop-screen true) :ctrl-x :ctrl-x \q))))
  (let [text (snap (loop-screen true) :ctrl-x esc)]
   (is (not (has? text "discard")) "the question is gone")))
 (testing "the terminal going away is not asked"
  (is (= :quit (first (run-with (loop-screen true) eof))))))

;; --- the solutes of a buffer

(deftest the-buffer-table-asks-before-dropping-a-draft
 (in-project
  (fn [_root dir]
   (let [show! #(solutes-menu/show! % background dir)]
    (testing "a clean table is left at once"
     (is (= :back (first (run-with show! :ctrl-x))))
     (is (= :quit (first (run-with show! esc)))))
    (testing "a new row asks, and Enter drops it: nothing was written"
     (is (has? (apply snap show! (concat add-tris [:ctrl-x])) "discard 1 change?"))
     (is (= :back (first (apply run-with show! (concat add-tris [:ctrl-x enter])))))
     (is (= [] (buffer/read-solutes dir)))
     (is (= :quit (first (apply run-with show! (concat add-tris [esc enter])))))
     (is (= [] (buffer/read-solutes dir))))
    (testing "Escape keeps editing: the draft is still there and ^w saves it"
     (let [[r text]
       (apply run-with show! (concat add-tris [:ctrl-x esc :ctrl-w eof]))]
      (is (= :quit r))
      (is (has? text "saved")))
     (is (= 1 (count (buffer/read-solutes dir))))
     (is (= :back (first (run-with show! :ctrl-x))) "saved: nothing to ask"))
    (testing "a removal mark counts"
     (is (has? (snap show! :ctrl-r :ctrl-x) "discard 1 change?"))
     (is (= 1 (count (buffer/read-solutes dir)))))
    (testing "a flow that is open is dropped first; its row does not count"
     (is (= :back (first (run-with show! :ctrl-n "tri" :ctrl-x))))
     (let [text (snap show! :ctrl-r :ctrl-n "tri" :ctrl-x)]
      (is (has? text "discard 1 change?"))
      (is (not (has? text "tri_"))
       "the flow is closed while the question is asked"))
     (is (= :back
       (first
        (run-with show! :ctrl-r :ctrl-n "tri" :ctrl-x esc :ctrl-x enter)))
      "after Escape the flow stays closed"))))))

(deftest the-footer-of-an-empty-buffer-table
 (in-project
  (fn [_root dir]
   (let [show! #(solutes-menu/show! % background dir)
     empty-text (snap show! esc)]
    (is (not (has? empty-text "edit:")) "nothing to edit")
    (is (not (has? empty-text "undo:")) "nothing to undo")
    (is (has? empty-text "add nonbio:"))
    (is (has? empty-text "save:")))
   (buffer/write-solutes! dir (vec (take 2 rows)))
   (let [text (snap #(solutes-menu/show! % background dir))]
    (is (has? text "edit:"))
    (is (has? text "undo:"))))))

(deftest an-unusable-buffer-does-not-invite-adding
 (in-project
  (fn [_root dir]
   (spit (buffer/buffer-file dir) "{:solutes [1]}")
   (let [show! #(solutes-menu/show! % background dir)
     text (snap show! down)]
    (is (has? text "buffer.edn unusable!"))
    (is (not (has? text "no solutes: ^n")))
    (is (not (has? text "add nonbio:"))))
   (is (= "{:solutes [1]}" (slurp (buffer/buffer-file dir)))))))

;; --- a recipe that replaces a buffer

(deftest a-recipe-replaces-a-buffer-only-after-a-question
 (in-project
  (fn [root dir]
   (buffer/write-solutes! dir (vec (take 3 rows)))
   (let [opts {:drafts (vec (take 1 rows)), :replace {:n 3, :recipe "my recipe"}}
     show! #(solutes-menu/show! % background dir opts)]
    (testing "the question names the count and the recipe"
     (let [text (snap show! :ctrl-w)]
      (is (has? text "replace 3 solutes with recipe \"my recipe\"?"))
      (is (has? text "enter: replace  esc: keep"))))
    (testing "Escape keeps the buffer, ^x too"
     (run-with show! :ctrl-w esc :ctrl-x enter)
     (is (= 3 (count (buffer/read-solutes dir))))
     (run-with show! :ctrl-w :ctrl-x :ctrl-x enter)
     (is (= 3 (count (buffer/read-solutes dir)))))
    (testing "Enter replaces it, and a second ^w does not ask again"
     (let [text (snap show! :ctrl-w enter :ctrl-w)]
      (is (has? text "saved"))
      (is (not (has? text "replace 3"))))
     (is (= 1 (count (buffer/read-solutes dir)))))
    (testing "a buffer with one solute says `solute`"
     (buffer/write-solutes! dir (vec (take 1 rows)))
     (let [text (snap #(solutes-menu/show! %
         background
         dir
         {:drafts [],
          :replace {:n 1, :recipe "e"}})
        :ctrl-w)]
      (is (has? text "replace 1 solute with recipe \"e\"?")))))
   (testing "an empty buffer is replaced with no question"
    (buffer/write-solutes! dir [])
    (let [text (snap #(solutes-menu/show! %
        background
        dir
        {:drafts (vec (take 2 rows)),
         :replace {:n 0, :recipe "r"}})
       :ctrl-w)]
     (is (has? text "saved"))
     (is (not (has? text "replace 0"))))
    (is (= 2 (count (buffer/read-solutes dir)))))
   (testing "through the landing: load a recipe over a buffer"
    (spit (recipe-store/recipes-file root) fixture-recipes)
    (buffer/write-solutes! dir (vec (take 2 rows)))
    (let [show! #(buffer-landing/show! % background dir)
      text (snap show! down enter "sec" enter :ctrl-w)]
     (is (has? text "replace 2 solutes with recipe \"SEC buffer\"?")))
    (is (= 2 (count (buffer/read-solutes dir))))))))

;; --- the recipes and the custom solutes

(deftest the-recipes-table-asks-before-dropping-drafts
 (support/with-data-folder
  [root (support/temp-root)]
  (spit (recipe-store/recipes-file root) fixture-recipes)
  (let [show! #(recipes-menu/show! % background)
    before (slurp (recipe-store/recipes-file root))]
   (is (= :back (first (run-with show! :ctrl-x))))
   (is (has? (snap show! :ctrl-r :ctrl-x) "discard 1 change?"))
   (is (has? (snap show! :ctrl-r esc) "discard 1 change?"))
   (is (= :back (first (run-with show! :ctrl-r :ctrl-x enter))))
   (testing "the name prompt is dropped first, a new row counts"
    (is (= :back (first (run-with show! :ctrl-n "brand" :ctrl-x))))
    (is (has? (snap show! :ctrl-r :ctrl-n "brand" :ctrl-x) "discard 1 change?"))
    (is (= :back
      (first (run-with show! :ctrl-n "brand" enter :ctrl-x :ctrl-x enter)))))
   (testing "Escape keeps editing"
    (is (= :quit (first (run-with show! :ctrl-r :ctrl-x esc esc enter)))))
   (is (= before (slurp (recipe-store/recipes-file root))) "nothing was written"))))

(def ^:private custom-entry
 {:kind :nonbiological,
  :name "mine",
  :formula "NaCl",
  :z 28,
  :pmv 17.0,
  :sigma nil})

(deftest the-custom-table-asks-before-dropping-drafts
 (support/with-data-folder
  [root (support/temp-root)]
  (custom-store/write-solutes! root [custom-entry])
  (let [show! #(custom-menu/show! % background)
    before (slurp (custom-store/custom-file root))]
   (is (= :back (first (run-with show! :ctrl-x))))
   (is (has? (snap show! :ctrl-r :ctrl-x) "discard 1 change…"))
   (is (= :back (first (run-with show! :ctrl-r :ctrl-x enter))))
   (is (= :quit (first (run-with show! :ctrl-r esc enter))))
   (is (= before (slurp (custom-store/custom-file root))) "nothing was written"))))

;; --- the sheets

(defn ^:private sheet-run
 "`sheets/show!` of the output sheet with `inputs` fed: `[result text saved]`."
 [& inputs]
 (let [saved (atom [])
   sheet (sheets/load-sheet "output-settings")
   entries (settings/screen-entries
    (settings/merge-defaults (settings/read-defaults) nil)
    :output)
   [r text] (apply run-with
    #(sheets/show! %
     sheet
     background
     {:entries entries,
      :catalog (constantly []),
      :swatch (constantly nil),
      :relations (settings/read-relations),
      :save! (fn [setting v]
       (swap! saved conj [setting v]))})
    inputs)]
  [r text @saved]))

;; TABLE_SIGFIGS is the first setting, 17: erase it and type 5
(def ^:private draft-sigfigs [enter backspace backspace "5" enter])

(deftest a-sheet-asks-before-dropping-drafts
 (testing "no draft: left at once"
  (is (= :back (first (sheet-run :ctrl-x))))
  (is (= :quit (first (sheet-run esc)))))
 (testing "a draft: the question is in the description column"
  (let [[_ text] (apply sheet-run (concat draft-sigfigs [:ctrl-x eof]))]
   (is (has? text "discard 1 change?"))
   (is (has? text "enter: discard"))
   (is (has? text "esc: keep editing"))))
 (testing "Enter leaves for both keys and saves nothing"
  (let [[r _ saved] (apply sheet-run (concat draft-sigfigs [:ctrl-x enter]))]
   (is (= :back r))
   (is (= [] saved)))
  (let [[r _ saved] (apply sheet-run (concat draft-sigfigs [esc enter]))]
   (is (= :quit r))
   (is (= [] saved))))
 (testing "Escape keeps editing, and ^w then saves the draft"
  (let [[r _ saved] (apply sheet-run
     (concat draft-sigfigs [:ctrl-x esc :ctrl-w :ctrl-x]))]
   (is (= :back r))
   (is (= 1 (count saved)))
   (is (= "TABLE_SIGFIGS" (ffirst saved)))))
 (testing "an edit that is open is dropped with the question, the draft stays"
  (let [[r _ saved] (apply sheet-run
     (concat draft-sigfigs
      [down enter "1" :ctrl-x esc :ctrl-w :ctrl-x]))]
   (is (= :back r))
   (is (= ["TABLE_SIGFIGS"] (map first saved))))))

;; --- a file that cannot be used: where it is, and a reset

(deftest the-buffer-landing-resets-an-unusable-buffer
 (in-project
  (fn [_root dir]
   (let [file (buffer/buffer-file dir)
     show! #(buffer-landing/show! % background dir)]
    (spit file "{:solutes [{:kind :nope}]}")
    (testing "the status names the file's path once and offers `r`"
     (let [text (snap show!)]
      (is (has? text "projects/demo/buffer.edn") "the end of the full path")
      (is (has? text "r: reset"))
      (is (= 1 (count (re-seq #"buffer\.edn unusable!" text))))))
    (testing "an action that says it again does not repeat the status"
     (is (= 1 (count (re-seq #"buffer\.edn unusable!" (snap show! enter))))))
    (testing "Escape or a key other than Enter leaves the file alone"
     (let [text (snap show! \r)]
      (is (has? text "reset buffer.edn to empty?"))
      (is (has? text "the old file is kept as buffer.edn.corrupt")))
     (snap show! \r esc)
     (is (.isFile file))
     (is (not (.exists (io/file dir "buffer.edn.corrupt")))))
    (testing "Enter keeps the old file as .corrupt and starts empty"
     (let [text (snap show! \r enter)]
      (is (has? text "buffer.edn: none yet"))
      (is (has? text "buffer.edn.corrupt")))
     (is (not (.exists file)))
     (is (= "{:solutes [{:kind :nope}]}"
       (slurp (io/file dir "buffer.edn.corrupt"))))
     (is (= [] (buffer/read-solutes dir))))
    (testing "an older .corrupt is replaced"
     (spit file "garbage (")
     (snap show! \r enter)
     (is (= "garbage (" (slurp (io/file dir "buffer.edn.corrupt"))))))
   (testing "`r` does nothing with a usable buffer"
    (let [text (snap #(buffer-landing/show! % background dir) \r)]
     (is (not (has? text "reset buffer.edn")))))
   (testing "the question's Ctrl-X and the terminal"
    (spit (buffer/buffer-file dir) "garbage (")
    (is (= :quit
      (first (run-with #(buffer-landing/show! % background dir) \r eof))))
    (is (.isFile (buffer/buffer-file dir)))))))

(deftest the-custom-landing-resets-the-file-under-the-cursor
 (support/with-data-folder
  [root (support/temp-root)]
  (let [recipes (recipe-store/recipes-file root)
    customs (custom-store/custom-file root)
    show! #(custom-landing/show! % background)]
   (spit recipes "{:recipes [1]}")
   (spit customs "{:solutes [1]}")
   (testing "each option names its own file"
    (is (has? (snap show!) "/recipes.edn  r: reset"))
    (is (has? (snap show! down) "/custom-solutes.edn  r: reset"))
    (is (has? (snap show!) "r: reset")))
   (testing "`r` resets the file of the option under the cursor only"
    (is (has? (snap show! \r) "reset recipes.edn to empty?"))
    (snap show! \r enter)
    (is (not (.exists recipes)))
    (is (= "{:recipes [1]}" (slurp (io/file root "recipes.edn.corrupt"))))
    (is (= "{:solutes [1]}" (slurp customs)) "the other file is untouched")
    (is (has? (snap show! down \r) "reset custom-solutes.edn to empty?"))
    (snap show! down \r enter)
    (is (not (.exists customs)))
    (is (= "{:solutes [1]}" (slurp (io/file root "custom-solutes.edn.corrupt")))))
   (testing "Escape cancels, and a usable file has no `r`"
    (spit recipes "{:recipes [1]}")
    (snap show! \r esc)
    (is (= "{:recipes [1]}" (slurp recipes)))
    (spit recipes "{:recipes []}")
    (is (not (has? (snap show! \r) "reset recipes.edn")))))))

(deftest the-tables-of-unusable-files-do-not-invite-adding
 (support/with-data-folder
  [root (support/temp-root)]
  (spit (custom-store/custom-file root) "{:solutes [1]}")
  (let [text (snap #(custom-menu/show! % background) down)]
   (is (has? text "custom-solutes.e…"))
   (is (not (has? text "none: ^n ^p add")))
   (is (not (has? text "add nonbio:"))))))
