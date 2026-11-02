;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The names a text setting may take, which the editor offers as a list to pick from: the
;; colours (the names `Colors.parse` knows with their colour, harvested into the bundled
;; `colours.txt` by `bb harvest-defaults`, one `name #rrggbb` a line) and the fonts
;; installed on this machine, sorted into math fonts and text fonts by what the font files
;; say (`baysol.tui.fonts`: a math font has an OpenType MATH table), cached in `fonts.edn`
;; in the BAYSOL folder. A machine with no fonts has no list and any name is accepted.

(ns baysol.tui.catalog
 (:require [baysol.tui.core.app :as app]
  [baysol.tui.fonts :as fonts]
  [clojure.java.io :as io]
  [clojure.string :as str]))

;; The colours, `[[name [r g b]] ...]` in the order of the file; read once, when first
;; asked for.
(def ^:private colours
 (delay (with-open [r (io/reader (io/resource "colours.txt"))]
   (vec (for [line (line-seq r)
      :let [[_ colour hex] (re-matches #"(\S+) #([0-9a-f]{6})" line)]
      :when colour]
     [colour
      (mapv #(Integer/parseInt (subs hex % (+ % 2)) 16) [0 2 4])])))))

(def ^:private swatches (delay (into {} @colours)))

(defn swatch
 "The colour `colour` as `[r g b]` (0 to 255 each), or nil for a name that is no colour of
 the list; a `#rrggbb` text gives its own colour."
 [colour]
 (if-let [[_ hex] (re-matches #"#([0-9a-f]{6})" (str colour))]
  (mapv #(Integer/parseInt (subs hex % (+ % 2)) 16) [0 2 4])
  (get @swatches colour)))

;; The installed fonts, read once, when first asked for: from the cache in the BAYSOL folder
;; when the font files are the ones it was made from, else by scanning them.
(def ^:private installed
 (delay (fonts/load-fonts (io/file @app/cache-dir "fonts.edn"))))

(def ^:dynamic *fonts*
 "The fonts `names` offers, `{:math [...] :text [...]}`, in place of the ones installed
 here: a test binds it."
 nil)

(defn names
 "The names the setting `setting` of `kind` (`:colour` or `:font`) may take, sorted. The
 font of a setting whose name has MATH in it is chosen from the math fonts (those with a
 MATH table), any other font setting from the text fonts, which leave the math fonts out.
 Empty for a font on a machine with no fonts."
 [setting kind]
 (case kind
  :colour (mapv first @colours)
  :font (let [fonts (or *fonts* @installed)]
   (if (str/includes? setting "MATH") (:math fonts) (:text fonts)))
  []))
