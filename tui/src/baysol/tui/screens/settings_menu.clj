;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The settings menu: four pre-rendered pages (resources/settings-menu/pages), one for each
;; kind of setting, laid out as a grid of two rows and two columns with the cursor `>` on
;; one of them, and run the way the main menu is: a table of pages with the key that leads
;; from each page to which other page, and hotkeys that jump to a page and press Enter
;; there.
;;
;;               output (page1)   model (page4)
;;               sampler (page2)  plots (page3)
;;
;;   arrows     move the cursor to the neighbour in that direction, where there is one (the
;;              arrows beside `move:` on each page say which)
;;   enter      open the sheet of the kind under the cursor (`baysol.tui.screens.sheets`)
;;   u a p m    jump to output, sampler, plots or model and open it (the letter in the
;;              brackets next to each name); the page shows the choice for a moment first
;;   ctrl-e     the landing of the custom solutes and recipes (the global menu only:
;;              `solutes: ctrl+e`), over the page the cursor is on; ctrl-x there comes back
;;              to this page
;;   ctrl-x     back to the main menu (`main-menu: ctrl+x`)
;;   escape     quit the program (`quit: esc`)

(ns baysol.tui.screens.settings-menu
 (:require [baysol.tui.catalog :as catalog]
  [baysol.tui.core.app :as app]
  [baysol.tui.screens.custom-landing :as custom-landing]
  [baysol.tui.screens.page-load :as pgld]
  [baysol.tui.screens.sheets :as sheets]
  [baysol.tui.screens.state :as state]
  [baysol.tui.settings :as settings])
 (:import (com.googlecode.lanterna TextColor)
  (com.googlecode.lanterna.input KeyType)
  (com.googlecode.lanterna.screen TerminalScreen)))

(set! *warn-on-reflection* true)

(def screen-name "settings-menu")

;; The resource folder of the sheet each kind of setting opens.
(def sheet-dirs
 {:output "output-settings",
  :sampler "sampler-settings",
  :plots "plots-settings",
  :model "model-settings"})

;; page mappings for the settings menu screen: the key that leads from each page to which
;; page or action (Enter opens the sheet of the page's kind)
(defn make-pages
 "The table of the pages of the menu whose art is in the resource folder `dir`
 (`settings-menu` or `project-settings-menu`: the same four pages in the same grid)."
 [dir]
 (let [asset #(pgld/load-ascii % dir)]
  {:page1 ; output
   {:asset (asset "page1"),
    :actions
    {KeyType/ArrowRight :page4, KeyType/ArrowDown :page2, KeyType/Enter :output}},
   :page2 ; sampler
   {:asset (asset "page2"),
    :actions
    {KeyType/ArrowUp :page1, KeyType/ArrowRight :page3, KeyType/Enter :sampler}},
   :page3 ; plots
   {:asset (asset "page3"),
    :actions
    {KeyType/ArrowUp :page4, KeyType/ArrowLeft :page2, KeyType/Enter :plots}},
   :page4 ; model
   {:asset (asset "page4"),
    :actions
    {KeyType/ArrowLeft :page1, KeyType/ArrowDown :page3, KeyType/Enter :model}}}))

(def pages (make-pages screen-name))

;; the menu of the settings of a project: the same grid, its own art
(def project-screen-name "project-settings-menu")

(def project-pages (make-pages project-screen-name))

;; hotkeys: a letter jumps to a page and then presses Enter on it
(def hotkeys {\u :page1, \a :page2, \p :page3, \m :page4})

(defn page-after
 "What `input` leads to from `page` of the table `table` (`pages`, the default, or
 `project-pages`): another page, the same page when nothing happens, a kind of setting
 (`:output`, `:sampler`, `:plots`, `:model`) whose sheet opens, `:back` (to the menu this
 one was opened from) or `:quit` (the program). A hotkey goes to its page and then does
 what Enter does there."
 ([page input] (page-after pages page input))
 ([table page input]
  (state/menu-after table hotkeys page input)))

(defn ^:private global-opts
 "The options of the menu of the global settings, in the BAYSOL folder."
 []
 {:pages pages,
  :custom-solutes? true,
  :load! (fn [] (settings/load! @app/app-dir)),
  :save! (fn [kind setting v] (settings/save! @app/app-dir kind setting v))})

(defn project-opts
 "The options of the menu of the settings of the project whose folder is `project-dir`:
 its own pages, and settings that go back to the global ones (`load-project!`)."
 [project-dir]
 {:pages project-pages,
  :load! (fn [] (settings/load-project! project-dir @app/app-dir)),
  :save! (fn [kind setting v]
   (settings/save-project! project-dir @app/app-dir kind setting v))})

(defn show!
 "Shows the settings menu on `screen`, with the solid colour `background`, and handles the
 keys until one leaves it; returns :back or :quit. A sheet opens from the page the cursor
 is on, and the menu is back on that page when the sheet is left with ctrl-x.

 `opts` says which settings it is the menu of; it has `:pages` (the table of pages),
 `:custom-solutes?` (true for the global menu: ctrl-e opens the custom landing), `:load!`
 (a function that gives the checked settings) and `:save!` (a function of a kind, a
 setting name and a value). The default is the global settings; `project-opts`
 gives those of a project."
 ([^TerminalScreen screen ^TextColor background]
  (show! screen background (global-opts)))
 ([^TerminalScreen screen
   ^TextColor background
   {table :pages, :keys [load! save! custom-solutes?]}]
  (let [draw! (state/page-drawer screen table background)]
   (draw! :page1)
   (loop [page :page1]
    (let [input (state/read-input screen)
      target (hotkeys input)

      ; a hotkey first shows its page selected, waits, and only then presses Enter
      _ (state/show-hotkey! draw! target page)
      next-page (page-after table page input)]
     (cond (and custom-solutes? (= input :ctrl-e))
      (if (= :quit (custom-landing/show! screen background))
       :quit
       (do (draw! page) (recur page)))

      (contains? table next-page)
      (if (= next-page page)
       (recur page)
       (do (draw! next-page) (recur next-page)))

      (contains? sheet-dirs next-page)
      (let [shown (or target page)
        sheet (sheets/load-sheet (sheet-dirs next-page))
        entries (settings/screen-entries (load!) next-page)
        relations (second (settings/ensure-defaults!))]
       (if (= :quit
         (sheets/show! screen
          sheet
          background
          {:entries entries,
           :catalog catalog/names,
           :swatch catalog/swatch,
           :relations relations,
           :save! #(save! next-page %1 %2)}))
        :quit
        (do (draw! shown) (recur shown))))

      :else next-page)))))) ; :back or :quit
