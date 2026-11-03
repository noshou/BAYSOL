;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The saved recipes: a table (resources/recipes/pages/page.txt, drawn by
;; `baysol.tui.screens.table`) with one row for each recipe of `recipes.edn` in the BAYSOL
;; folder (`baysol.tui.recipe-store`). Columns: name | solutes (how many) | kinds (a summary
;; of the rows: `3 solute 1 polymer 2 custom 4 seq`, DNA, RNA, protein together as `seq`).
;; It is laid out and run like the solutes of a buffer (`solutes-menu`), the rows being the
;; recipes: a row that is new shows `*`, one marked to be removed `-`, both in the space
;; before its name. Nothing of THIS list is written until `^w`.
;;
;;   up, down   the previous and the next recipe (no wrapping)
;;   enter      rename and edit the recipe: asks its NAME first (prefilled; Enter accepts,
;;              Escape cancels the whole action), then opens the table of solutes
;;              (`baysol.tui.screens.solutes-menu`, the recipe as its target), where `^w`
;;              writes the recipe into `recipes.edn` at once, under its CURRENT name. A
;;              changed name is a DRAFT (`*`) until `^w` here, which writes the recipe under
;;              the new name (the old one goes, the solutes stay)
;;   ^n         a new recipe (never past 999: the footer's `new recipe` is gone then):
;;              asks a NAME the same way, makes the recipe EMPTY as a draft row and opens
;;              the table of solutes on it. A recipe never saved from there stays a draft
;;              row here and is written, empty or not, by `^w`
;;              A name is unique among the OTHER recipes (case does not matter: a recipe
;;              may keep its name or change only its case), not blank, at most 40
;;              characters, no control characters; a clash says `name in use` and changes
;;              nothing
;;   ^r         mark the recipe to be removed at the next save (`-`); a never saved one goes
;;              at once. A recipe is only removed from the global list: projects that loaded
;;              it keep their own `buffer.edn`
;;   ^u         undo: the removal mark of the row, else its draft
;;   ^w         save the list: removed recipes go, new ones are written
;;   ^x         back to the landing of the custom solutes and recipes     escape   quit
;; Leaving without `^w` drops what was not saved. Renaming touches no project. A
;; `recipes.edn` that cannot be used is told (`recipes.edn unusable!`), nothing is
;; editable and it is never written over. Linux-tested only; macOS and Windows untested.

(ns baysol.tui.screens.recipes-menu
 (:require [baysol.tui.core.app :as app]
  [baysol.tui.draft :as draft]
  [baysol.tui.recipe-store :as recipe-store]
  [baysol.tui.screens.landing :as landing]
  [baysol.tui.screens.loop :as lp]
  [baysol.tui.screens.page-load :as pgld]
  [baysol.tui.screens.solutes-menu :as solutes-menu]
  [baysol.tui.screens.table :as table]
  [baysol.tui.solutes :as solutes])
 (:import (com.googlecode.lanterna TextColor)
  (com.googlecode.lanterna.input KeyType)
  (com.googlecode.lanterna.screen TerminalScreen)))

(set! *warn-on-reflection* true)

(def screen-name "recipes")

(def art
 "The art of the table, parsed."
 (table/parse-art (pgld/load-ascii "page" screen-name)))

(def ^:private empty-hint "none: ^n adds")

(def ^:private unusable-note "recipes.edn unusable!")

(def ^:private prompt-at
 "Where the name prompt goes over the table: row, column, width."
 {:row 8, :col 12, :width 56})

(defn view-rows
 "The rows of the table for the state `s` (the recipes as rows of `baysol.tui.solutes`),
 as `table/frame` takes them."
 [s]
 (mapv (fn [row]
   (let [r (solutes/value row)]
    {:cells [(:name r) (str (count (:solutes r)))
      (recipe-store/kinds-summary (:solutes r))],
     :aligns [:left :right :left],
     :mark (solutes/mark row)}))
  (:rows s)))

(defn ^:private refresh
 "The state `s` with the news of the file after the table of solutes: a row whose recipe
 the editor wrote under the row's CURRENT name (an exact match) stands at what the file
 has. A renamed row (its saved recipe has another name, apart from case) stays a draft, as
 its old entry goes at `^w`, with the solutes the file has under the new name. A row the
 editor did not write (no entry of that exact name) is left as it is, drafts and marks
 included."
 [s root]
 (try
  (let [fresh (recipe-store/read-recipes root)]
   (update s
    :rows
    (fn [rows]
     (mapv (fn [row]
       (let [v (solutes/value row)
         e (first (filter #(= (:name %) (:name v)) fresh))
         renamed? (and (:saved row)
          (not (recipe-store/index-of-name
            [(:saved row)]
            (:name v))))]
        (cond (nil? e) row
         renamed? (assoc row :draft e)
         :else (assoc row :saved e :draft nil))))
      rows))))
  (catch Exception _ s)))

(defn ^:private save-step
 "The state `st` after `^w`: the list is written (the recipes not marked to go) and the
 state is what was saved."
 [st root]
 (table/save-rows st nil #(recipe-store/write-recipes! root %)))

(defn ^:private name-problem
 "What is wrong with `n` as the name of the recipe in row `except` (nil for a new recipe)
 in the state `s`: the store's rules, and a name that another row has already (a row
 marked to go too: undo it, or pick another)."
 [s n except]
 (or (recipe-store/name-problem n)
  (when (recipe-store/index-of-name
    (keep-indexed #(when (not= %1 except) (solutes/value %2)) (:rows s))
    n)
   "name in use")))

(defn ^:private page-lines
 "The page for the state `st`: the table, with the name prompt over it when it is open.
 Returns `{:lines :offset}`."
 [st unusable?]
 (let [{:keys [s cursor prompt]} st
   n (count (:rows s))
   {:keys [lines offset]} (table/frame
    art
    (view-rows s)
    cursor
    (:offset st)
    {:note (:note st),
     :empty-hint (when-not unusable? empty-hint),
     :hide-legends (cond unusable? ["edit" "new recipe"
       "save" "undo" "rmv"]
      (zero? n) ["edit"])})]
  {:offset offset,
   :lines (if prompt
    (landing/overlay
     lines
     (:row prompt-at)
     (:col prompt-at)
     (landing/prompt-box "recipe name" (:width prompt-at) prompt))
    lines)}))

(defn ^:private edit!
 "Opens the table of solutes on the recipe in row `i`, as it stands in the table (its
 current name, drafts included); returns its result."
 [screen background st i]
 (let [{recipe-name :name, recipe-solutes :solutes} (solutes/value
    (get-in st [:s :rows i]))]
  (solutes-menu/show! screen
   background
   (assoc (solutes-menu/recipe-target @app/app-dir recipe-name)
    :load!
    (fn [] (vec recipe-solutes))))))

(defn ^:private accept-name
 "The state `st` after the prompt accepted `n` for `target`: `:new` (a draft row at the
 end) or the index of the row whose recipe is renamed (a draft if the name changed). The
 cursor goes to the row."
 [st n target]
 (let [s (:s st)]
  (if (= target :new)
   (let [s (solutes/append-solutes s [{:name n, :solutes []}])]
    (assoc st :s s :cursor (dec (count (:rows s))) :prompt nil))
   (let [v (solutes/value (get-in s [:rows target]))
     s (if (= n (:name v)) s (solutes/set-solute s target (assoc v :name n)))]
    (assoc st :s s :cursor target :prompt nil)))))

(defn show!
 "Shows the recipes on `screen`, with the solid colour `background`, and handles the keys
 until one leaves it. Returns :back (to the landing it was opened from) or :quit."
 [^TerminalScreen screen ^TextColor background]
 (let [root @app/app-dir
   loaded (try (recipe-store/read-recipes root) (catch Exception _ ::unusable))
   unusable? (= loaded ::unusable)]
  ;; Ctrl-X (here and in the prompt): nothing was asked, the table is left unchanged
  (lp/run-table!
   screen
   background
   {:init {:s (solutes/initial (if unusable? [] loaded)),
     :cursor 0,
     :offset 0,
     :note (when unusable? unusable-note),
     :prompt nil},
    :frame #(page-lines % unusable?),
    :esc-quits? #(nil? (:prompt %)),
    :close #(assoc % :prompt nil),
    :handle
    (fn [st input]
     (let [{:keys [s cursor prompt]} st
       row (get-in s [:rows cursor])
       ;; an edit of the recipe in row `i`: back here with the file's news
       edit (fn [st i]
        (let [r (edit! screen background st i)]
         (if (= r :quit)
          :quit
          (assoc st :s (refresh (:s st) root) :cursor i))))]
      (cond
       prompt
       (let [r (landing/prompt-step prompt
          input
          #(name-problem s % (:for prompt))
          recipe-store/max-name)]
        (cond (= r :cancel) (assoc st :prompt nil)
         (:chosen r) (let [st (accept-name st (:chosen r) (:for prompt))]
          (edit st (:cursor st)))
         :else (assoc st
          :prompt (assoc (:state r) :for (:for prompt))
          :note (when (= "name in use" (:error (:state r)))
           "name in use"))))

       unusable? (assoc st :note unusable-note)

       (and (= input KeyType/Enter) row (not (:removed? row)))
       (assoc st
        :prompt
        (assoc (landing/prompt-initial)
         :text (:name (solutes/value row))
         :for cursor))

       (and (= input :ctrl-n) (draft/room? s))
       (assoc st :prompt (assoc (landing/prompt-initial) :for :new))

       (= input :ctrl-w) (save-step st root)

       :else (or (table/step st input) st))))})))
