;; SPDX-License-Identifier: LGPL-3.0-or-later

(ns baysol.tui.screens.state
 (:require [baysol.tui.text :as txt]
  [baysol.tui.screens.theme :as theme])
 (:import (com.googlecode.lanterna TextColor TextColor$RGB)
  (com.googlecode.lanterna.input KeyStroke KeyType)
  (com.googlecode.lanterna.screen Screen$RefreshType TerminalScreen)
  (com.googlecode.lanterna.graphics TextGraphics)))

(set! *warn-on-reflection* true)

(defn handle
 "Maps an input to a page / action through the table `pages`; unknown input maps to the
 current page."
 [pages page input]
 (or (get-in pages [page :actions input]) page))

;; The size of every page, in cells: the page is drawn in the middle of a larger terminal.
(def page-columns 80)
(def page-rows 24)

;; What was drawn last, `{:screen :page :background}`, so that a resize can draw it again.
(def ^:private last-drawn (atom nil))

(defn page-offset
 "Where the top left cell of a page goes on a terminal of `columns` by `rows` cells,
 `[column row]`: the page is centred, and sits at the corner if the terminal is not larger
 than the page."
 [columns rows]
 [(max 0 (quot (- columns page-columns) 2)) (max 0 (quot (- rows page-rows) 2))])

(defn draw-page
 "Draws a page on the terminal, on a screen filled with the solid colour `background`
 (a Lanterna `TextColor`) with the theme's text colour. The page's `:marks`,
 `[[row column [r g b]] ...]`, are blank cells of those colours drawn over the text, as
 swatches, on the page's `:panel`, `[[row column width] ...]`, cells in white."
 [^TerminalScreen screen page ^TextColor background]
 (let [lines (:asset page)
   ^TextGraphics graphics (.newTextGraphics screen)
   size (.getTerminalSize screen)
   [dx dy] (page-offset (.getColumns size) (.getRows size))]
  (reset! last-drawn {:screen screen, :page page, :background background})
  (.clear screen)
  (.setForegroundColor graphics theme/foreground)
  (.setBackgroundColor graphics background)
  (.fill graphics \space)
  (doseq [[row line] (map-indexed vector lines)]
   (.putString graphics (int dx) (int (+ dy row)) ^String line))
  ; the white panel behind swatches: `[[row column width] ...]`, the text drawn again on it
  (.setBackgroundColor graphics theme/panel)
  (doseq [[row column width] (:panel page)
    :let [line (get lines row "")
     text (subs (str line (txt/spaces (+ column width)))
      column
      (+ column width))]]
   (.putString graphics (int (+ dx column)) (int (+ dy row)) ^String text))
  (doseq [[row column [r g b]] (:marks page)]
   (.setBackgroundColor graphics (TextColor$RGB. (int r) (int g) (int b)))
   (.putString graphics (int (+ dx column)) (int (+ dy row)) " "))

  ; repaint every cell, not only the ones that changed: a cell the terminal drew wider
  ; than one column (or a glyph that overflows its cell) cannot be left half-erased
  (.refresh screen Screen$RefreshType/COMPLETE)))

(defn key->input
 "The input of `stroke`, the thing a page table maps: the lower-case letter for a
 character key, `:ctrl-<letter>` (`:ctrl-w`, `:ctrl-u`, ...) for Ctrl and a letter, else the
 `KeyType` (arrows, Enter, Escape). A terminal sends Ctrl-M as Enter, so `:ctrl-m` never
 arrives."
 [^KeyStroke stroke]
 (let [key-type (.getKeyType stroke)]
  (if (= key-type KeyType/Character)
   (let [letter (Character/toLowerCase (char (.getCharacter stroke)))]
    (if (.isCtrlDown stroke) (keyword (str "ctrl-" letter)) letter))
   key-type)))

(def ^:private poll-ms
 "How long to sleep between looks for a key, in milliseconds."
 25)

(defn ^:private next-stroke
 "Waits for a key on `screen` and returns its `KeyStroke`. While it waits it looks for a
 change of the size of the terminal, and draws the page that was drawn last again, in the
 middle of the new size."
 ^KeyStroke [^TerminalScreen screen]
 (loop []
  (if-let [stroke (.pollInput screen)]
   stroke
   (do (when (.doResizeIfNecessary screen)
     (when-let [{:keys [page background]} @last-drawn]
      (draw-page screen page background)))
    (Thread/sleep (long poll-ms))
    (recur)))))

(defn discard-pending!
 "Throws away the keys already waiting on `screen`, after a short wait for ones still on
 their way, and returns how many there were. The program takes a second or so to start, and
 a key typed meanwhile (the Enter that ran it, a double press) must not act on the first
 page."
 [^TerminalScreen screen]
 (Thread/sleep (long poll-ms))
 (loop [n 0]
  (if (.pollInput screen) (recur (inc n)) n)))

(defn read-input
 "Waits for a key on `screen` and returns its input (see `key->input`)."
 [^TerminalScreen screen]
 (key->input (next-stroke screen)))

(defn key->raw
 "The input of `stroke` for typing text: a character key without Ctrl gives the character
 as typed (capitals kept), anything else what `key->input` gives."
 [^KeyStroke stroke]
 (if (and (= (.getKeyType stroke) KeyType/Character) (not (.isCtrlDown stroke)))
  (.getCharacter stroke)
  (key->input stroke)))

(defn back-key?
 "True for `input`, the input of Ctrl-X: BACK from anywhere. In any mode of a screen (a
 prompt, a dropdown, a cell being edited, a question, a form page) it drops what is open,
 as Escape does, and the screen returns `:back` to its parent. Terminals never deliver
 the Cmd key, so the key is Ctrl-X."
 [input]
 (= input :ctrl-x))

(defn read-raw
 "Waits for a key on `screen` and returns its raw input (see `key->raw`)."
 [^TerminalScreen screen]
 (key->raw (next-stroke screen)))

(defn page-drawer
 "A function of a page key that draws that page of the table `pages` on `screen`, on the
 solid colour `background`."
 [^TerminalScreen screen pages ^TextColor background]
 #(draw-page screen (pages %) background))

(def hotkey-delay-ms
 "How long a hotkey shows its page selected before it presses Enter there, in
 milliseconds, so that the selection can be seen."
 50)

(defn show-hotkey!
 "A hotkey (`target`, its page, nil for any other key) first shows its page selected, waits
 a moment, and only then presses Enter there: when `target` is not the page `page` already
 on the screen, `draw!` (a function of a page key) shows it and the call sleeps
 `hotkey-delay-ms`. Returns nil."
 [draw! target page]
 (when (and target (not= target page))
  (draw! target)
  (Thread/sleep (long hotkey-delay-ms))))

(defn leave-key
 "What `input` does to a screen that has nothing open: `:back` for Ctrl-X, `:quit` for
 Escape or the terminal going away, nil for any other key."
 [input]
 (cond (back-key? input) :back
  (or (= input KeyType/Escape) (= input KeyType/EOF)) :quit))

(defn menu-after
 "What `input` leads to from `page` of a grid menu with the page table `pages` and the
 `hotkeys` that jump to a page: `:back` for Ctrl-X, `:quit` for Escape or the terminal
 going away, a hotkey goes to its page and does what Enter does there, else the page the
 table maps `input` to (the same page for a key it does not map)."
 [pages hotkeys page input]
 (or (leave-key input)
  (if-let [target (hotkeys input)]
   (handle pages target KeyType/Enter)
   (handle pages page input))))

(defn draw-lines!
 "Draws the `lines` (no marks) as a page on `screen`, on the solid colour `background`."
 [^TerminalScreen screen ^TextColor background lines]
 (draw-page screen {:asset lines} background))

(defn confirm!
 "Waits on `screen` for the answer to a question asked on the page: true for Enter, false
 for Escape, `:quit` when the terminal goes away, `:back` for Ctrl-X; any other key is
 ignored."
 [^TerminalScreen screen]
 (loop []
  (let [input (read-raw screen)]
   (cond (= input KeyType/Enter) true
    (= input KeyType/Escape) false
    (= input KeyType/EOF) :quit
    (back-key? input) :back
    :else (recur)))))

(defn run-prompt!
 "Runs a prompt or dropdown on `screen` until it is answered. `st` is its state, `draw!` a
 function of the state that draws the page, `step` a function of the state and a raw input
 that gives `{:state new-state}`, `{:chosen value}`, `:cancel` or `:back` (as
 `picker/step` and `landing/prompt-step` do). Returns the chosen value, nil for `:cancel`,
 `:back` for `:back`; `:quit` when the terminal goes away, if `eof-quits?` (else `step`
 sees the end of the input, as it sees any key). The chosen value must not be nil or
 a keyword."
 [^TerminalScreen screen st draw! step eof-quits?]
 (loop [st st]
  (draw! st)
  (let [input (read-raw screen)
    r (if (and eof-quits? (= input KeyType/EOF)) :quit (step st input))]
   (cond (#{:quit :back} r) r
    (= r :cancel) nil
    (:chosen r) (:chosen r)
    :else (recur (:state r))))))
