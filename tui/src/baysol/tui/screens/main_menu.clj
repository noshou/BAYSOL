;; SPDX-License-Identifier: LGPL-3.0-or-later

(ns baysol.tui.screens.main-menu
 (:require [baysol.tui.screens.state :as state]
  [baysol.tui.screens.page-load :as pgld]
  [baysol.tui.version :as version])
 (:import (com.googlecode.lanterna TextColor$ANSI)
  (com.googlecode.lanterna.screen TerminalScreen)
  (com.googlecode.lanterna.terminal DefaultTerminalFactory)
  (com.googlecode.lanterna.input KeyStroke KeyType)))

(set! *warn-on-reflection* true)

(def screen-name "main-menu")

;; the solid colour the whole screen is filled with: DEFAULT is the terminal's own
;; background (try TextColor$ANSI/BLUE_BRIGHT to see what a fill does)
(def background TextColor$ANSI/DEFAULT)

;; Where the release name is written on every page: row 9, columns 6 to 28, the space
;; left of "move:", which starts at column 29. 22 characters fit (`bb fmt` checks the
;; name in Project.toml against that).
(def ^:private version-row 9)
(def ^:private version-from 6)
(def ^:private version-to 29)
(def ^:private release-name (version/version-name))

(defn ^:private page-asset
 "The lines of the page file `filename`, with the release name written on them."
 [filename]
 (pgld/stamp (pgld/load-ascii filename screen-name)
  version-row
  version-from
  version-to
  release-name))

;; page mappings for the main menu screen
(def ^:private pages
 {:page1 ; new project
  {:asset (page-asset "page1"),
   :actions {KeyType/ArrowRight :page2,
    KeyType/ArrowDown :page3,
    KeyType/Enter :page1 ; future -> :new-project
   }},
  :page2 ; load project
  {:asset (page-asset "page2"),
   :actions {KeyType/ArrowLeft :page1,
    KeyType/ArrowDown :page4,
    KeyType/Enter :page2 ; future -> :load-project
   }},
  :page3 ; goto projects
  {:asset (page-asset "page3"),
   :actions {KeyType/ArrowUp :page1,
    KeyType/ArrowDown :page5,
    KeyType/ArrowRight :page4,
    KeyType/Enter :page3 ; future -> :goto-project
   }},
  :page4 ; settings
  {:asset (page-asset "page4"),
   :actions {KeyType/ArrowUp :page2,
    KeyType/ArrowDown :page6,
    KeyType/ArrowLeft :page3,
    KeyType/Enter :page4 ; future -> :settings
   }},
  :page5 ; help
  {:asset (page-asset "page5"),
   :actions {KeyType/ArrowUp :page3,
    KeyType/ArrowRight :page6,
    KeyType/Enter :page5 ; future -> :settings
   }},
  :page6 ; quit
  {:asset (page-asset "page6"),
   :actions
   {KeyType/ArrowUp :page4, KeyType/ArrowLeft :page5, KeyType/Enter :quit}}})

;; How long a hotkey shows its page selected before it presses Enter there, in
;; milliseconds, so that the selection can be seen.
(def ^:private hotkey-delay-ms 50)

;; hotkeys: a letter (either case), or Esc, jumps to a page and then presses Enter on it
;; (Esc goes to the quit page, which is shown selected before the program ends)
(def ^:private hotkeys
 {\n :page1, ; new project
  \l :page2, ; load project
  \o :page3, ; goto projects dir
  \s :page4, ; settings
  \h :page5, ; help
  KeyType/Escape :page6 ; quit (Esc)
 })

(defn ^:private key->input
 "The input of `stroke`: the lower-case letter 
 for a character key, else its KeyType."
 [^KeyStroke stroke]
 (let [key-type (.getKeyType stroke)]
  (if (= key-type KeyType/Character)
   (Character/toLowerCase (char (.getCharacter stroke)))
   key-type)))

(defn ^:private page-after
 "The page that `input` leads to from `page`. A hotkey goes to its page and then does
 what Enter does there."
 [page input]
 (if-let [target (hotkeys input)]
  (state/handle pages target KeyType/Enter)
  (state/handle pages page input)))

(defn -main
 "Draws main menu with event handling"
 [& _]
 (let [factory (DefaultTerminalFactory.)
   ^TerminalScreen screen (.createScreen factory)]
  (.startScreen screen)
  (.setCursorPosition screen nil) ; hide the terminal's own text cursor
  (.setCursorPosition screen nil) ; hide cursor
  (try

   ; draw initial page
   (state/draw-page screen (pages :page1) background)

   ; loop through events
   (loop [page :page1]
    (let [^KeyStroke stroke (.readInput screen)
      input (key->input stroke)
      target (hotkeys input)

      ; a hotkey first shows its page selected, waits, and only then presses Enter
      _ (when (and target (not= target page))
       (state/draw-page screen (pages target) background)
       (Thread/sleep (long hotkey-delay-ms)))
      next-page (page-after page input)]
     (cond (= next-page :quit) nil ; quit means exit program
      (= next-page page) (recur page) ; got back same page, no-op

      ; a new page: draw it on the screen
      :else (do (state/draw-page screen (pages next-page) background)
       (recur next-page)))))
   (finally (.stopScreen screen)))))
