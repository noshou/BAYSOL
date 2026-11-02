;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The look of every screen: purple text on a pink background, whatever the theme of
;; the terminal it runs in. Every cell is painted with these colours
;; (`state/draw-page` fills the whole screen, not only the 80 x 24 page). The terminal's
;; own default colours are never changed (the escape sequences that set them, OSC 10 and
;; 11, are not given back by every terminal, which left a shell started afterwards in the
;; theme's colours). A terminal that does not take 24-bit colour gets black on white.

(ns baysol.tui.screens.theme
 (:require [baysol.tui.core :as core])
 (:import (com.googlecode.lanterna TextColor$Indexed TextColor$RGB)))

(set! *warn-on-reflection* true)

(def background-rgb
 "The pink (#ffd9f1) of the background, [r g b]."
 [255 217 241])

(def foreground-rgb
 "The purple (#6c1899) of the text, [r g b]."
 [108 24 153])

;; White and black of the 256-colour palette (#ffffff and #000000), for terminals that do
;; not take 24-bit colour.
(def ^:private background-index 231)
(def ^:private foreground-index 16)

(defn true-colour?
 "True if the terminal of `system` is known to take 24-bit colour: Windows Terminal and
 the usual terminals say so with COLORTERM (truecolor or 24bit); macOS's own Terminal does
 not."
 [system]
 (let [v (some-> (get (:env system) "COLORTERM")
    str
    .toLowerCase)]
  (boolean (or (#{"truecolor" "24bit"} v) (core/windows? system)))))

(def ^:private panel-rgb
 "The white of the panel under the colour swatches, [r g b]."
 [255 255 255])

(defn colours
 "`{:background :foreground :panel}` as Lanterna colours for `system`: the pink, the purple
 and the white as RGB where the terminal takes 24-bit colour, else black on white."
 [system]
 (if (true-colour? system)
  (let [[br bg bb] background-rgb
    [fr fg fb] foreground-rgb
    [wr wg wb] panel-rgb]
   {:background (TextColor$RGB. br bg bb),
    :foreground (TextColor$RGB. fr fg fb),
    :panel (TextColor$RGB. wr wg wb)})
  {:background (TextColor$Indexed. background-index),
   :foreground (TextColor$Indexed. foreground-index),
   :panel (TextColor$Indexed. background-index)}))

(def background
 "The background `TextColor` of the screens, for the terminal this program runs in."
 (:background (colours (core/read-system))))

(def panel
 "The `TextColor` of the white panel the colour swatches are shown on, so that a swatch
 close to the background still shows."
 (:panel (colours (core/read-system))))

(def foreground
 "The foreground `TextColor` of the screens."
 (:foreground (colours (core/read-system))))
