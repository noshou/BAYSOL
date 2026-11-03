;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The landing page of the buffer of a project (resources/buffer-landing/pages/page.txt,
;; drawn by `baysol.tui.screens.landing`): what to do with the project's recipe, which is
;; its `buffer.edn`, before the table of solutes opens. The `recipe` box lists the options
;; that apply, in this order, with the cursor `>` before the highlighted one:
;;
;;   edit current recipe (N solutes)
;;       only when the project's buffer has solutes: the table of the buffer
;;       (`baysol.tui.screens.solutes-menu`)
;;   load a recipe
;;       always: a dropdown of the saved recipes (`recipes.edn` of the BAYSOL folder; type
;;       to narrow, up and down, Tab, Enter, Escape), then the table with the recipe's
;;       solutes as DRAFTS (`*`): nothing is written until `^w`, and if the project has a
;;       buffer the border says the recipe replaces it then. With no saved recipe the
;;       status box says `no saved recipes!`
;;   new recipe
;;       the table, empty, as a draft; nothing is replaced until `^w`
;;   save current recipe globally
;;       only when the buffer has solutes: asks a NAME (at most 40 characters, no control
;;       characters; Enter accepts, Escape cancels), a second question if a recipe of that
;;       name exists (Enter replaces, Escape keeps), then writes the buffer as it is ON
;;       DISK into `recipes.edn`
;;
;; The `this project` box says what the project has (`buffer.edn: 12 solutes`, `none yet`,
;; `unusable!`) and, under it, what the last action did until the next key. A `buffer.edn`
;; or `recipes.edn` that cannot be used is told and never written over.
;;
;;   up, down   the previous and the next option (no wrapping)
;;   enter      do it     ctrl-x   back to the project menu     escape   quit the program
;;
;; Recipes are TUI-side only: the Julia side reads a project's `buffer.edn`, never the
;; recipes. Linux-tested only; macOS and Windows untested.

(ns baysol.tui.screens.buffer-landing
 (:require [baysol.tui.buffer :as buffer]
  [baysol.tui.core.app :as app]
  [baysol.tui.edn-store :as edn-store]
  [baysol.tui.limits :as limits]
  [baysol.tui.recipe-store :as recipe-store]
  [baysol.tui.screens.landing :as landing]
  [baysol.tui.screens.page-load :as pgld]
  [baysol.tui.screens.picker :as picker]
  [baysol.tui.screens.solutes-menu :as solutes-menu]
  [baysol.tui.screens.state :as state]
  [clojure.java.io :as io])
 (:import (com.googlecode.lanterna TextColor)
  (com.googlecode.lanterna.input KeyType)
  (com.googlecode.lanterna.screen TerminalScreen)))

(set! *warn-on-reflection* true)

(def screen-name "buffer-landing")

(def art
 "The art of the landing, parsed."
 (landing/parse-art (pgld/load-ascii "page" screen-name)))

(def ^:private box-row
 "The row and column of the status box, and its width: what a prompt or a dropdown is
 drawn over."
 {:row 9, :col 3, :width 76})

(def ^:private pick-rows
 "How tall the dropdown of recipes is (borders included): from the status box to the
 blank rows above the footer."
 12)

(defn buffer-count
 "How many solutes the buffer of the project in `project-dir` has, or `::unusable`."
 [project-dir]
 (try (count (buffer/read-solutes project-dir)) (catch Exception _ ::unusable)))

(defn ^:private plural
 [n word]
 (str n " " word (when (not= n 1) "s")))

(defn options
 "The options of the landing for a buffer of `n` solutes (`::unusable` for one that cannot
 be used), as `[{:id :label} ...]` in order: `:edit` and `:save` only for a buffer that has
 solutes."
 [n]
 (let [has? (and (number? n) (pos? n))]
  (vec (remove nil?
    [(when has?
      {:id :edit,
       :label (str "edit current recipe (" (plural n "solute") ")")})
     {:id :load, :label "load a recipe"}
     {:id :new, :label "new recipe"}
     (when has? {:id :save, :label "save current recipe globally"})]))))

(defn status-text
 "What the `this project` box says of a buffer of `n` solutes."
 [n]
 (cond (= n ::unusable) "buffer.edn unusable!"
  (zero? n) "buffer.edn: none yet"
  :else (str "buffer.edn: " (plural n "solute"))))

(defn lines
 "The lines of the landing of the project `project-name` with a buffer of `n` solutes, the
 cursor on option `cursor` and `message` (or nil) under the status."
 [project-name n cursor message]
 (landing/frame art
  {:title (str "buffer · " project-name),
   :options (mapv :label (options n)),
   :cursor cursor,
   :status [(status-text n) (or message "")]}))

(defn ^:private over
 "`ls` with a box of the lines `box-lines` over the status box."
 [ls box-lines]
 (landing/overlay ls (:row box-row) (:col box-row) box-lines))

(defn ^:private pick-recipe!
 "Lets the user pick one of `recipes` from a dropdown over the lower half of `base`, each
 shown with its number of solutes. Returns the recipe, nil for Escape, `:back` for Ctrl-X,
 `:quit` when the terminal goes away."
 [screen background base recipes]
 (let [shown (mapv #(str (:name %) " (" (count (:solutes %)) ")") recipes)
   r (state/run-prompt!
    screen
    (picker/initial shown nil)
    #(state/draw-lines!
     screen
     background
     (landing/overlay
      base
      (:row box-row)
      (:col box-row)
      (landing/pick-box "load a recipe" (:width box-row) pick-rows %)))
    picker/step
    true)]
  (if (string? r) (nth recipes (.indexOf ^java.util.List shown r)) r)))

(defn ^:private ask-name!
 "Asks for a name over the status box; returns it, nil for Escape, `:back` for Ctrl-X,
 `:quit` when the terminal goes away."
 [screen background base]
 (state/run-prompt!
  screen
  (landing/prompt-initial)
  #(state/draw-lines! screen
   background
   (over base (landing/prompt-box "save as" (:width box-row) %)))
  #(landing/prompt-step %1 %2 recipe-store/name-problem recipe-store/max-name)
  true))

(defn ^:private replace?
 "Asks whether the recipe `n` is to be replaced: true for Enter, false for Escape, `:back`
 for Ctrl-X, `:quit` when the terminal goes away."
 [screen background base n]
 (state/draw-lines! screen
  background
  (over base (landing/question-box (:width box-row) n)))
 (state/confirm! screen))

(defn ^:private save-globally!
 "Saves the buffer of `project-dir` as it is on disk as a recipe under a name asked for.
 Returns the message to show, `:back` (Ctrl-X in the name prompt or the question) or
 `:quit`."
 [screen background project-dir base]
 (let [n (ask-name! screen background base)]
  (cond
   (#{:quit :back} n) n
   (nil? n) "not saved"
   :else
   (try
    (let [root @app/app-dir
      recipes (recipe-store/read-recipes root)
      taken? (recipe-store/index-of-name recipes n)
      ok (if taken? (replace? screen background base n) true)]
     (cond (#{:quit :back} ok) ok
      (and (nil? taken?) (>= (count recipes) limits/max-rows))
      "999 recipes at most!"
      (not ok) "not saved"
      :else
      (do (recipe-store/save-recipe! root n (buffer/read-solutes project-dir))
       (str "saved as \"" n "\""))))
    (catch clojure.lang.ExceptionInfo e
     (case (:type (ex-data e))
      :baysol.tui.recipe-store/unusable "recipes.edn unusable!"
      :baysol.tui.buffer/unusable "buffer.edn unusable!"
      "could not save!"))
    (catch Exception _ "could not save!")))))

;; the table of solutes returns :back when it is left with Ctrl-X: that brings the user
;; back to this landing, which goes on; only the landing's own sub-modes return :back
;; from it
(defn ^:private child
 [r]
 (when-not (= r :back) r))

(defn ^:private load-recipe!
 "Picks a recipe and opens the table of the buffer on its solutes as drafts. Returns
 `:quit`, `:back` for Ctrl-X in the dropdown, or the message to show (nil for none). The
 table that opens has its own `:back` (to this landing), which is no message."
 [screen background project-dir n base]
 (let [recipes (try (recipe-store/read-recipes @app/app-dir)
    (catch Exception _ ::unusable))]
  (cond (= n ::unusable) "buffer.edn unusable!"
   (= recipes ::unusable) "recipes.edn unusable!"
   (empty? recipes) "no saved recipes!"
   :else (let [recipe (pick-recipe! screen background base recipes)]
    (cond (#{:quit :back} recipe) recipe
     (nil? recipe) nil
     :else (child (solutes-menu/show!
       screen
       background
       project-dir
       {:drafts (:solutes recipe),
        :replace {:n n, :recipe (:name recipe)},
        :hint
        (when (pos? n)
         "replaces the current recipe at ^w")})))))))

(defn ^:private reset-buffer!
 "Asks whether the `buffer.edn` of `project-dir`, which cannot be used, is to be reset to
 empty, over `base`, and does it: the old file is renamed `buffer.edn.corrupt` (an older
 one replaced). Returns the message to show, `:back` (Ctrl-X: no message) or `:quit`."
 [screen background project-dir base]
 (state/draw-lines! screen
  background
  (over base (landing/reset-box (:width box-row) "buffer.edn")))
 (let [ok (state/confirm! screen)]
  (cond (= ok :quit) :quit
   (true? ok) (try (edn-store/quarantine! (buffer/buffer-file project-dir))
    "buffer.edn reset, old file kept as buffer.edn.corrupt"
    (catch Exception _ "could not reset!"))
   :else nil)))

(defn show!
 "Shows the landing of the buffer of the project whose folder is `project-dir` on
 `screen`, with the solid colour `background`, and handles the keys until one leaves it;
 returns :back (to the project menu) or :quit."
 [^TerminalScreen screen ^TextColor background project-dir]
 (let [project-name (.getName (io/file (str project-dir)))]
  (loop [cursor 0
    message nil]
   (let [n (buffer-count project-dir)
     opts (options n)
     cursor (max 0 (min cursor (dec (count opts))))
     ;; what the status box says is not said twice; an unusable file says where it is
     message (if (= message (status-text n)) nil message)
     message (or message
      (when (= n ::unusable)
       (landing/unusable-hint (str (buffer/buffer-file
          project-dir)))))
     base (lines project-name n cursor message)
     _ (state/draw-lines! screen background base)
     input (state/read-input screen)
     id (:id (nth opts cursor))]
    (cond
     (state/leave-key input) (state/leave-key input)
     (= input KeyType/ArrowDown) (recur (inc cursor) nil)
     (= input KeyType/ArrowUp) (recur (dec cursor) nil)
     (and (= input \r) (= n ::unusable))
     (let [r (reset-buffer! screen background project-dir base)]
      (if (= r :quit) r (recur cursor r)))
     (= input KeyType/Enter)
     (let [r (case id
        :edit (child (solutes-menu/show! screen background project-dir))
        :load (load-recipe! screen background project-dir n base)
        :new (if (= n ::unusable)
         "buffer.edn unusable!"
         (child (solutes-menu/show! screen
           background
           project-dir
           {:drafts [],
            :hint
            (when (pos? n)
             "nothing is replaced until ^w")})))
        :save (save-globally! screen background project-dir base))]
      (if (#{:quit :back} r) r (recur cursor (when (string? r) r))))
     :else (recur cursor nil))))))
