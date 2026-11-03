;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The project menu: six pre-rendered pages (resources/project-menu/pages), one for each
;; part of a project, laid out as a grid of three rows and two columns with the cursor `>`
;; on one of them, and run the way the main menu is: a table of pages with the key that
;; leads from each page to which other page, and hotkeys that jump to a page and press
;; Enter there.
;;
;;               models (page1)    data (page2)
;;               buffer (page3)    logs (page4)
;;               settings (page5)  run (page6)
;;
;;   arrows     move the cursor to the neighbour in that direction, where there is one
;;   enter      open the part under the cursor: `models` adds a model by path and lists them
;;              (`models-menu`); `settings` opens; `data` and `logs` pick a run from a
;;              dropdown, or tell "no runs exist!" until a run has made their folder; the
;;              others stay on their page
;;   m d b l s r  jump to models, data, buffer, logs, settings or run and open it (the
;;              letter in the brackets next to each name); the page shows the choice for a
;;              moment first
;;   ctrl-x     back to the main menu (`main menu: ctrl+x`)
;;   escape     quit the program (`quit: esc`)

(ns baysol.tui.screens.project-menu
 (:require [baysol.tui.core.app :as app]
  [baysol.tui.runs :as runs]
  [baysol.tui.screens.buffer-landing :as buffer-landing]
  [baysol.tui.screens.landing :as landing]
  [baysol.tui.screens.models-menu :as models-menu]
  [baysol.tui.screens.page-load :as pgld]
  [baysol.tui.screens.picker :as picker]
  [baysol.tui.screens.settings-menu :as settings-menu]
  [baysol.tui.screens.state :as state]
  [baysol.tui.settings :as settings])
 (:import (com.googlecode.lanterna TextColor)
  (com.googlecode.lanterna.input KeyType)
  (com.googlecode.lanterna.screen TerminalScreen)))

(set! *warn-on-reflection* true)

(def screen-name "project-menu")

(defn ^:private page-asset
 "The lines of the page file `filename`."
 [filename]
 (pgld/load-ascii filename screen-name))

;; page mappings for the project menu: the key that leads from each page to which page or
;; action. Enter on a part that does nothing yet leads to its own page. The grid is the
;; same as before the parts were rearranged; only what each place holds changed.
(def pages
 {:page1 ; models
  {:asset (page-asset "page1"),
   :actions
   {KeyType/ArrowRight :page2, KeyType/ArrowDown :page3, KeyType/Enter :models}},
  :page2 ; data
  {:asset (page-asset "page2"),
   :actions
   {KeyType/ArrowLeft :page1, KeyType/ArrowDown :page4, KeyType/Enter :data}},
  :page3 ; buffer
  {:asset (page-asset "page3"),
   :actions {KeyType/ArrowUp :page1,
    KeyType/ArrowRight :page4,
    KeyType/ArrowDown :page5,
    KeyType/Enter :buffer}},
  :page4 ; logs
  {:asset (page-asset "page4"),
   :actions {KeyType/ArrowUp :page2,
    KeyType/ArrowLeft :page3,
    KeyType/ArrowDown :page6,
    KeyType/Enter :logs}},
  :page5 ; settings
  {:asset (page-asset "page5"),
   :actions {KeyType/ArrowUp :page3,
    KeyType/ArrowRight :page6,
    KeyType/Enter :settings}},
  :page6 ; run
  {:asset (page-asset "page6"),
   :actions
   {KeyType/ArrowUp :page4, KeyType/ArrowLeft :page5, KeyType/Enter :page6}}})

;; hotkeys: a letter jumps to a page and then presses Enter on it
(def hotkeys {\m :page1, \d :page2, \b :page3, \g :page4, \s :page5, \r :page6})

(def no-runs "no runs exist!")

;; The parts that list runs: the page each is on, its folder in the
;; project, and where its dropdown goes, in the blank row under the part
;; (`row`, the note and the `find:` text) with the dropdown under it
;; down to the bottom of the page (`rows`, the names and a status row).
(def ^:private run-parts
 {:data {:page :page2, :folder "data", :row 16, :col 49, :width 29, :rows 7},
  :logs {:page :page4, :folder "logs", :row 20, :col 49, :width 29, :rows 3}})

(defn ^:private with-note
 "`page` with `text` written in the blank row under the part `part`."
 [page part text]
 (let [{:keys [row col width]} (run-parts part)]
  (update page :asset update row pgld/put-text col width text)))

(defn ^:private with-dropdown
 "`page` of the part `part` with everything under its note row blanked in the columns of
 the dropdown (the art of the parts under it must not show through), the `find:` text in
 the note row and the dropdown of the picker `st` under it."
 [page part st]
 (let [{:keys [row col width rows]} (run-parts part)]
  (-> page
   (update :asset
    (fn [lines]
     (vec (map-indexed
       (fn [i line]
        (if (>= i row) (pgld/put-text line col width "") line))
       lines))))
   (update :asset
    picker/overlay
    st
    {:row (inc row), :col col, :width width, :rows rows})
   (update :asset
    update
    row
    pgld/put-text
    col
    width
    (str "find: " (picker/typed-text st 22))))))

(defn ^:private pick-run!
 "Lets the user pick one of the runs `ids` of the part `part` (`:data` or `:logs`) from a
 dropdown under it, like a project is picked: type to narrow the list, up and down to
 move, Tab to complete, Enter to pick. Returns the name of the run, nil if the user gives
 up with Escape, `:back` for Ctrl-X. The newest run is highlighted first."
 [screen background part ids]
 (let [page (pages (:page (run-parts part)))]
  (state/run-prompt!
   screen
   (picker/initial ids (peek ids))
   #(state/draw-page screen (with-dropdown page part %) background)
   picker/step
   false)))

(defn page-after
 "What `input` leads to from `page`: another page, the same page when nothing happens,
 `:models`, `:buffer`, `:settings` (the settings of the project open), `:data` or
 `:logs` (its runs), `:back` (to the main menu) or `:quit` (the program). A hotkey
 goes to its page and then does what Enter does there."
 [page input]
 (state/menu-after pages hotkeys page input))

(defn ^:private settings-reset?
 "Whether the `settings.edn` of the project in `project-dir` could not be read and was
 replaced just now (the old file is kept as `settings.edn.corrupt`): opening the project's
 settings does it, once, so this is the one chance to say so."
 [project-dir]
 (try (boolean (:reset? (meta (settings/load-project! project-dir @app/app-dir))))
  (catch Exception _ false)))

(defn ^:private settings-note!
 "Tells, in a box over the first page, that the settings of the project were unreadable
 and what was done, and waits for a key. Returns :quit if the terminal went away, else
 nil."
 [screen background]
 (state/draw-page
  screen
  {:asset (landing/overlay
    (:asset (pages :page1))
    8
    3
    (landing/box "settings"
     76
     ["settings.edn was unreadable: global settings used,"
      "old file kept as settings.edn.corrupt" "any key: ok"]))}
  background)
 (when (= KeyType/EOF (state/read-raw screen)) :quit))

(defn ^:private menu-loop!
 "The loop of [[show!]]."
 [^TerminalScreen screen ^TextColor background project-dir]
 (let [draw! (state/page-drawer screen pages background)]
  (draw! :page1)
  ;; `noted?`: the page has the note "no runs exist!" on it, which goes at the next key
  (loop [page :page1
    noted? false]
   (let [input (state/read-input screen)
     target (hotkeys input)

     ; a hotkey first shows its page selected, waits, and only then presses Enter
     _ (state/show-hotkey! draw! target page)
     next-page (page-after page input)]
    (cond
     (contains? run-parts next-page)
     (let [{shown :page, folder :folder} (run-parts next-page)]
      (if (runs/runs? project-dir folder)
       (if (= :back
         (pick-run! screen
          background
          next-page
          (runs/run-ids project-dir folder)))
        :back
        (do (draw! shown) (recur shown false)))
       (do (state/draw-page screen
         (with-note (pages shown) next-page no-runs)
         background)
        (recur shown true))))

     ;; models: the prompt to add one (and the list of them) runs over the page
     ;; buffer: the landing of the project's buffer (recipes, then the table of solutes)
     (= next-page :buffer)
     (let [r (buffer-landing/show! screen background project-dir)]
      (if (= r :quit) :quit (do (draw! :page3) (recur :page3 false))))

     (= next-page :models)
     (if (= :quit (models-menu/show! screen background (pages :page1) project-dir))
      :quit
      (do (draw! :page1) (recur :page1 false)))

     (= next-page :settings)
     (if (= :quit
       (settings-menu/show! screen
        background
        (settings-menu/project-opts project-dir)))
      :quit
      (do (draw! :page5) (recur :page5 false)))

     (contains? pages next-page)
     (if (and (= next-page page) (not noted?))
      (recur page false)
      (do (draw! next-page) (recur next-page false)))

     :else next-page))))) ; :back or :quit

(defn show!
 "Shows the menu of the project whose folder is `project-dir` on `screen`, with the solid
 colour `background`, and handles the keys until one leaves it; returns :back or :quit.
 The settings of the project open from here and come back here on `settings`; `data` and
 `logs` pick a run, which is not shown anywhere yet, so the page is back either way.
 If the project's `settings.edn` could not be read and was replaced (the old file is kept
 as `settings.edn.corrupt`), a box says so first, once."
 [^TerminalScreen screen ^TextColor background project-dir]
 (if (and (settings-reset? project-dir)
   (= :quit (settings-note! screen background)))
  :quit
  (menu-loop! screen background project-dir)))
