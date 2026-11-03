;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The solutes of the buffer of a project: a table (resources/solutes-menu/pages/page.txt,
;; drawn by `baysol.tui.screens.table`) of one row for each solute, with the cursor `>` on
;; one of them. The rows are as tall as the page leaves room for and scroll a row at a
;; time. Nothing is written until `^w`; a row that is new or edited shows `*`, one marked
;; to be removed shows `-` (both in the space before its name).
;;
;;   up, down   the previous and the next solute (no wrapping); the footer shows `↓` and
;;              `↑` only where there is a solute to go to
;;   enter      edit the solute under the cursor: its name (free text, the solute it is
;;              stays), the params of a polymer family or a custom polymer (its numbers),
;;              its mM, then its uncertainty (also in mM), each typed in its cell: Enter
;;              takes it and goes on, Escape stops (what was taken stays a draft)
;;   ^n, ^p, ^f, ^e   add a solute at the end, of one kind (never past 999 solutes,
;;              the most the counter has room for: the footer's `add` legends are gone
;;              then). `^n` a non-biological solute: the name cell opens with a dropdown
;;              of the non-biological solutes and the custom ones. `^p` a polymer: a
;;              dropdown of the polymer grades, the families and the custom polymers, then
;;              the numbers of a family or the counts of a custom one. `^f` a protein: no
;;              dropdown, the path of the sequence file at once (Tab does nothing at table
;;              level; in a dropdown or a path prompt it completes). `^e` nucleotides: a
;;              choice of DNA or RNA, then the path of the sequence file. Then mM and ±;
;;              see `baysol.tui.add-flow`. Escape anywhere in the flow drops the new row
;;   ^r         mark the solute under the cursor to be removed at the next save (`-`); a
;;              solute that was never saved goes at once
;;   ^u         undo: the removal mark of the solute under the cursor, else its draft
;;   ^w         save every change into the project's `buffer.edn` (a solute that is not
;;              complete is told, and nothing is saved); the solutes marked `-` go now
;;   ^x         back to the project menu     escape   quit the program
;; Leaving without `^w` drops what was not saved, as the settings sheets do. The flow is all
;; in `baysol.tui.add-flow` (pure); this file draws the table, the dropdown over it and
;; the keys that are not part of a flow.
;;
;; The same table edits any list of solutes through a TARGET (`show!`): where the rows come
;; from and where `^w` puts them. The buffer of a project is one (`project-target`), a
;; recipe of the recipes file another (`recipe-target`). The editor can also start from
;; given draft rows (a recipe loaded into the buffer): nothing of them is written until
;; `^w`.

(ns baysol.tui.screens.solutes-menu
 (:require [baysol.tui.add-flow :as add-flow]
  [baysol.tui.buffer :as buffer]
  [baysol.tui.core :as core]
  [baysol.tui.core.app :as app]
  [baysol.tui.draft :as draft]
  [baysol.tui.file-picker :as file-picker]
  [baysol.tui.limits :as limits]
  [baysol.tui.recipe-store :as recipe-store]
  [baysol.tui.screens.landing :as landing]
  [baysol.tui.screens.loop :as lp]
  [baysol.tui.screens.page-load :as pgld]
  [baysol.tui.screens.state :as state]
  [baysol.tui.screens.table :as table]
  [baysol.tui.solutes :as solutes])
 (:import (com.googlecode.lanterna TextColor)
  (com.googlecode.lanterna.input KeyType)
  (com.googlecode.lanterna.screen TerminalScreen)))

(set! *warn-on-reflection* true)

(def screen-name "solutes-menu")

(def art
 "The art of the table, parsed."
 (table/parse-art (pgld/load-ascii "page" screen-name)))

(def ^:private empty-hint "no solutes: ^n ^p ^f ^e")

(def ^:private replace-at
 "Where the question of a recipe that replaces the buffer goes over the table: row,
 column, width."
 {:row 8, :col 12, :width 56})

(def format-number
 "`x` as plain decimal text with no exponent and no trailing zeros; \"\" for nil
 ([[add-flow/format-number]])."
 add-flow/format-number)

(def parse-field
 "What the text typed for a field comes to, `{:value v}` or `{:error message}`
 ([[add-flow/parse-field]])."
 add-flow/parse-field)

(defn ^:private params-width
 "How many characters of text the params cell takes (the art's column less its edges)."
 []
 (let [[from to] (nth (:spans art) 3)]
  (- to from 2)))

(defn ^:private edit-room
 "How many characters of text typed fit the cell of column `col`, with its cursor."
 [col]
 (let [[from to] (nth (:spans art) col)]
  (- to from 3)))

(defn view-rows
 "The rows of the table for the state `s` of the solutes, as `table/frame` takes them,
 and `edit` (`{:i :col :text}` of the cell being typed into, or nil), whose text is shown
 with a cursor in place of the cell's."
 [s edit]
 (vec
  (map-indexed
   (fn [i row]
    (let [v (solutes/value row)
      params (add-flow/params-cell v (params-width))
      cells [(:name v) (format-number (:mM v)) (format-number (:sigma-mM v))
       (:text params)]
      cells (if (and edit (= i (:i edit)))
       (assoc cells
        (:col edit)
        (str (table/tail-text (:text edit) (edit-room (:col edit)))
         "_"))
       cells)]
     {:cells cells,
      :aligns [:left :right :right (:align params)],
      :mark (solutes/mark row)}))
   (:rows s))))

(defn project-target
 "The target of the buffer of the project in `project-dir`: its `buffer.edn`."
 [project-dir]
 {:title "buffer",
  :load! #(buffer/read-solutes project-dir),
  :save! #(buffer/write-solutes! project-dir %),
  :unusable-note "buffer.edn unusable!"})

(defn recipe-target
 "The target of the recipe named `recipe-name` in the `recipes.edn` of the BAYSOL folder
 `root`: it reads that recipe's solutes (none for a recipe the file does not have yet) and
 `^w` writes them back at once, the other recipes kept. The border says which recipe it is
 when nothing else is to be said."
 [root recipe-name]
 {:title recipe-name,
  :idle-note (str "recipe: " recipe-name),
  :load! #(vec (recipe-store/recipe-solutes root recipe-name)),
  :save! #(recipe-store/save-recipe! root recipe-name %),
  :unusable-note "recipes.edn unusable!"})

(defn ^:private save-step
 "The state `st` after `^w`: the first solute that is not complete is told, else the
 target's `save!` writes the rows and the state is what was saved."
 [st save!]
 (table/save-rows st (solutes/problems (:s st)) save!))

(defn ^:private nav-step
 "The state `st` after `input` while nothing is being typed into; `save!` is the
 target's."
 [st input save!]
 (let [{:keys [s cursor]} st
   n (count (:rows s))]
  (cond
   (and (= input KeyType/Enter) (pos? n) (not (get-in s [:rows cursor :removed?])))
   (add-flow/start-edit st)

   (and (#{:ctrl-n :ctrl-p :ctrl-f :ctrl-e} input) (draft/room? s))
   (add-flow/start-add st
    (add-flow/load-customs @app/app-dir)
    (case input
     :ctrl-n :nonbio
     :ctrl-p :polymer
     :ctrl-e :nucleotide
     :protein))

   (= input :ctrl-w) (save-step st save!)

   :else (or (table/step st input) st))))

(defn ^:private pick-file
 "Opens the desktop's file picker for one sequence file in the user's home folder and
 returns what it gave. The keys typed while its window was open are thrown away."
 [^TerminalScreen screen]
 (let [system (core/read-system)
   result (file-picker/pick! (str (or (:home system) (:cwd system))) :sequence)]
  (state/discard-pending! screen)
  result))

(defn ^:private page-lines
 "The lines of the page for the state `st` and the note to show: the table, with the
 dropdown of an open flow over it. Returns `{:lines :offset}`."
 [st]
 (let [{:keys [s cursor ui]} st
   {:keys [lines offset]}
   (table/frame
    art
    (view-rows s (add-flow/edit-view st))
    cursor
    (:offset st)
    {:note (or (:note st)
      (add-flow/ui-note st)
      (when-not ui
       (some-> (get-in s [:rows cursor])
        solutes/value
        add-flow/row-note))
      (when-not ui (:hint st))
      (when-not ui (:idle-note st))),
     :empty-hint (when-not (:unusable? st) empty-hint),
     :hide-legends (cond (:unusable? st) ["edit" "add nonbio" "add polymer"
       "add protein" "add nucleotide" "save"
       "undo" "rmv"]
      (zero? (count (:rows s))) ["edit" "undo"])})]
  {:offset offset,
   :lines
   (if ui
    (add-flow/dropdown-lines lines st (- cursor offset) art (table/window art))
    lines)}))

(defn ^:private ask-replace!
 "Asks, over the table in the state `st`, whether the `:replace` of the state (`{:n how
 many solutes the buffer has :recipe the recipe name}`) is to take the place of the buffer
 at `^w`: true for Enter, false for Escape or Ctrl-X, `:quit` when the terminal goes away."
 [^TerminalScreen screen ^TextColor background st]
 (let [{:keys [n recipe]} (:replace st)
   {:keys [row col width]} replace-at
   answer (do (state/draw-lines! screen
     background
     (landing/overlay
      (:lines (page-lines st))
      row
      col
      (landing/box
       "replace"
       width
       [(str "replace "
         n
         " solute"
         (when (not= n 1) "s")
         " with recipe \""
         (table/tail-text recipe (- width 42))
         "\"?")
        "enter: replace  esc: keep"])))
    (state/confirm! screen))]
  (if (= answer :back) false answer)))

(defn show!
 "Shows the solutes of a target on `screen`, with the solid colour `background`, and
 handles the keys until one leaves it. Returns :back (to where it was opened from) or
 :quit.

 The target is the folder of a project (its buffer, [[project-target]]) or a map `{:load!
 (fn [] rows) :save! (fn [rows]) :unusable-note text}` (also `:idle-note`, what the border
 says when it has nothing else to say), such as [[recipe-target]]. `opts` (a map) may have
 `:drafts`, rows that the table starts with as unsaved ones in place of what `load!` gives
 (nothing is written until `^w`, which then replaces the target's rows), `:hint`, a note
 for the border until the first `^w`, and `:replace`, `{:n :recipe}`, the number of solutes
 the target has now and the name of the recipe the drafts come from: the first `^w` asks
 `replace N solutes with recipe NAME?` (Enter replaces, Escape keeps editing) when the
 target is not empty. A target that cannot be used is told and left
 alone: the table is empty and nothing can be edited."
 ([^TerminalScreen screen ^TextColor background target]
  (show! screen background target {}))
 ([^TerminalScreen screen ^TextColor background target opts]
  (let [target (if (map? target) target (project-target target))
    loaded (try ((:load! target)) (catch Exception _ ::unusable))
    ;; more than the table can count is as unusable as a file that is not EDN
    loaded (if (and (vector? loaded) (> (count loaded) limits/max-rows))
     ::unusable
     loaded)
    unusable? (= loaded ::unusable)
    unusable-note (:unusable-note target)
    env {:pick-file #(pick-file screen)}
    start (cond unusable? (solutes/initial [])
     (:drafts opts) (solutes/append-solutes (solutes/initial [])
      (:drafts opts))
     :else (solutes/initial loaded))]
   ;; back from anywhere: also with the add or edit flow open (dropped with the table)
   (lp/run-table!
    screen
    background
    {:init {:s start,
      :cursor 0,
      :offset 0,
      :note (when unusable? unusable-note),
      :hint (:hint opts),
      :replace (when (and (:replace opts) (pos? (:n (:replace opts))))
       (:replace opts)),
      :unusable? unusable?,
      :idle-note (:idle-note target),
      :ui nil},
     :frame page-lines,
     :esc-quits? #(nil? (:ui %)),
     :close add-flow/close-flow,
     :handle
     (fn [st input]
      (cond unusable? (assoc st :note unusable-note)
       (:ui st) (add-flow/step st input env)
       (and (= input :ctrl-w)
        (:replace st)
        (nil? (solutes/problems (:s st))))
       (let [answer (ask-replace! screen background st)]
        (if (true? answer)
         (let [after (nav-step st input (:save! target))]
          (if (= "saved" (:note after)) (dissoc after :replace) after))
         (if (= answer :quit) :quit st)))
       :else (nav-step st input (:save! target))))}))))
