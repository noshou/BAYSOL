;; SPDX-License-Identifier: LGPL-3.0-or-later

(ns baysol.tui.screens.state
 (:import (com.googlecode.lanterna TextColor)
  (com.googlecode.lanterna.screen Screen$RefreshType TerminalScreen)
  (com.googlecode.lanterna.graphics TextGraphics)))

(set! *warn-on-reflection* true)

(defn handle
 "Maps an input to a page / action through the table `pages`; unknown input maps to the
 current page."
 [pages page input]
 (or (get-in pages [page :actions input]) page))

(defn draw-page
 "Draws a page on the terminal, on a screen filled with the solid colour `background`
 (a Lanterna `TextColor`)."
 [^TerminalScreen screen page ^TextColor background]
 (let [lines (:asset page)
   ^TextGraphics graphics (.newTextGraphics screen)]
  (.clear screen)
  (.setBackgroundColor graphics background)
  (.fill graphics \space)
  (doseq [[row line] (map-indexed vector lines)]
   (.putString graphics 0 (int row) ^String line))
  ; repaint every cell, not only the ones that changed: a cell the terminal drew wider
  ; than one column (or a glyph that overflows its cell) cannot be left half-erased
  (.refresh screen Screen$RefreshType/COMPLETE)))
