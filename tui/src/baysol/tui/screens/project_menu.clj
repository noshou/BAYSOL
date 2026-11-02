;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The project menu: six pre-rendered pages (resources/project-menu/pages), one for each
;; part of a project, laid out as a grid of three rows and two columns with the cursor `>`
;; on one of them, and run the way the main menu is: a table of pages with the key that
;; leads from each page to which other page, and hotkeys that jump to a page and press
;; Enter there.
;;
;;               buffer (page1)  settings (page2)
;;               run (page3)     logs (page4)
;;               models (page5)  data (page6)
;;
;;   arrows     move the cursor to the neighbour in that direction, where there is one
;;   enter      open the part under the cursor; only `settings` does anything yet, the
;;              others stay on their page
;;   b s r l m d  jump to buffer, settings, run, logs, models or data and open it (the
;;              letter in the brackets next to each name); the page shows the choice for a
;;              moment first
;;   ctrl-b     back to the main menu (`main menu: ctrl+b`)
;;   escape     quit the program (`quit: esc`)

(ns baysol.tui.screens.project-menu
 (:require [baysol.tui.screens.page-load :as pgld]
  [baysol.tui.screens.settings-menu :as settings-menu]
  [baysol.tui.screens.state :as state])
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
;; action. Enter on a part that does nothing yet leads to its own page.
(def pages
 {:page1 ; buffer
  {:asset (page-asset "page1"),
   :actions
   {KeyType/ArrowRight :page2, KeyType/ArrowDown :page3, KeyType/Enter :page1}},
  :page2 ; settings
  {:asset (page-asset "page2"),
   :actions
   {KeyType/ArrowLeft :page1, KeyType/ArrowDown :page4, KeyType/Enter :settings}},
  :page3 ; run
  {:asset (page-asset "page3"),
   :actions {KeyType/ArrowUp :page1,
    KeyType/ArrowRight :page4,
    KeyType/ArrowDown :page5,
    KeyType/Enter :page3}},
  :page4 ; logs
  {:asset (page-asset "page4"),
   :actions {KeyType/ArrowUp :page2,
    KeyType/ArrowLeft :page3,
    KeyType/ArrowDown :page6,
    KeyType/Enter :page4}},
  :page5 ; models
  {:asset (page-asset "page5"),
   :actions
   {KeyType/ArrowUp :page3, KeyType/ArrowRight :page6, KeyType/Enter :page5}},
  :page6 ; data
  {:asset (page-asset "page6"),
   :actions
   {KeyType/ArrowUp :page4, KeyType/ArrowLeft :page5, KeyType/Enter :page6}}})

;; hotkeys: a letter jumps to a page and then presses Enter on it
(def hotkeys {\b :page1, \s :page2, \r :page3, \l :page4, \m :page5, \d :page6})

;; How long a hotkey shows its page selected before it is opened, in milliseconds.
(def ^:private hotkey-delay-ms 50)

(defn page-after
 "What `input` leads to from `page`: another page, the same page when nothing happens,
 `:settings` (the settings of the project open), `:back` (to the main menu) or `:quit` (the
 program). A hotkey goes to its page and then does what Enter does there."
 [page input]
 (cond (= input :ctrl-b) :back
  (or (= input KeyType/Escape) (= input KeyType/EOF)) :quit
  (hotkeys input) (state/handle pages (hotkeys input) KeyType/Enter)
  :else (state/handle pages page input)))

(defn show!
 "Shows the menu of the project whose folder is `project-dir` on `screen`, with the solid
 colour `background`, and handles the keys until one leaves it; returns :back or :quit.
 The settings of the project open from here and come back here on `settings`."
 [^TerminalScreen screen ^TextColor background project-dir]
 (let [draw! #(state/draw-page screen (pages %) background)]
  (draw! :page1)
  (loop [page :page1]
   (let [input (state/read-input screen)
     target (hotkeys input)

     ; a hotkey first shows its page selected, waits, and only then presses Enter
     _ (when (and target (not= target page))
      (draw! target)
      (Thread/sleep (long hotkey-delay-ms)))
     next-page (page-after page input)]
    (cond (= next-page :settings)
     (if (= :quit
       (settings-menu/show! screen
        background
        (settings-menu/project-opts project-dir)))
      :quit
      (do (draw! :page2) (recur :page2)))

     (contains? pages next-page)
     (if (= next-page page)
      (recur page)
      (do (draw! next-page) (recur next-page)))

     :else next-page))))) ; :back or :quit
