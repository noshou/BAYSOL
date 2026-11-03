;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Editing on the settings sheets: what Enter, typing, ctrl-w, ctrl-u and ctrl-r do, how a
;; value is checked against its limits, and what a page shows of a draft or of an error.
;; The editing is a pure function of a state and a key, so no terminal is needed.

(ns baysol.tui.screens.sheet-edit-test
 (:require [baysol.tui.screens.sheets :as sheets]
  [baysol.tui.settings :as settings]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))

(defn ^:private sheet-of
 "[sheet entries] of the screen `screen` with every value at its default."
 [screen]
 [(sheets/load-sheet (str (name screen) "-settings"))
  (settings/screen-entries (settings/merge-defaults (settings/read-defaults) nil)
   screen)])

(defn ^:private press
 "The state after the keys `inputs`, starting from `state`; the last result of `step`
 when it is not a state (:back, :quit) and the saves of the last ctrl-w as `:saved`."
 [sheet state & inputs]
 (reduce (fn [st input]
   (let [r (sheets/step sheet (:state st st) input)]
    (if (keyword? r)
     (reduced r)
     (merge {:state (:state r)} (select-keys r [:save])))))
  {:state state}
  inputs))

(defn ^:private typed [& s] (vec (apply str s)))

(defn ^:private catalog
 "A small list of names for the tests, in place of the system's colours and fonts."
 [setting kind]
 (case kind
  :colour ["black" "crimson" "crimson2" "darkorange" "gray20" "gray40"]
  :font (if (str/includes? setting "MATH")
   ["Pagella Math" "Latin Modern Math"]
   ["Pagella" "Pagella Text" "Times"])
  []))

(defn ^:private state0
 [entries]
 (sheets/initial-state entries catalog (constantly nil) (settings/read-relations)))

(defn ^:private to-page
 "The state of the sheet `sheet` at the page of `setting`: up to the top of the bloc it is
 on, then down it, then on to the next bloc, and so on (drafts stay while the bloc does)."
 [sheet st setting]
 (let [here #(sheets/cursor-setting (nth (:pages sheet) (:i %)))
   top (fn [st]
    (loop [st st]
     (let [up (:state (press sheet st KeyType/ArrowUp))]
      (if (= (:i up) (:i st)) st (recur up)))))
   down-to (fn [st]
    (loop [st st]
     (if (= setting (here st))
      st
      (let [down (:state (press sheet st KeyType/ArrowDown))]
       (when (not= (:i down) (:i st)) (recur down))))))]
  (loop [st (top st)
    n 0]
   (or (down-to st)
    (let [right (:state (press sheet st KeyType/ArrowRight))]
     (when (or (= (:i right) (:i st)) (> n 50))
      (throw (ex-info "setting not found" {:setting setting})))
     (recur right (inc n)))))))

(deftest a-number-is-edited-and-becomes-a-draft
 (let [[sheet entries] (sheet-of :sampler)
   start (state0 entries)
   typing (press sheet start KeyType/Enter)]
  (testing "Enter on a number opens it for typing, with its value in the buffer"
   (is (= "300" (get-in typing [:state :edit :buffer]))))
  (testing "typing replaces what is in the buffer and Enter makes a draft"
   (let [done (apply press
      sheet
      (:state typing)
      (concat [KeyType/Backspace KeyType/Backspace KeyType/Backspace]
       (typed "450")
       [KeyType/Enter]))]
    (is (= {"N_ADAPT" 450} (get-in done [:state :drafts])))
    (is (nil? (get-in done [:state :edit])))
    (is (get-in (sheets/shown-values (:state done)) ["N_ADAPT" :draft?]))
    (is (= 450 (get-in (sheets/shown-values (:state done)) ["N_ADAPT" :value])))))
  (testing "typing the saved value again is no draft"
   (let [done (apply press sheet (:state typing) [KeyType/Enter])]
    (is (= {} (get-in done [:state :drafts])))))
  (testing "Escape while typing drops the typing and does not quit"
   (let [done (press sheet (:state typing) \9 KeyType/Escape)]
    (is (nil? (get-in done [:state :edit])))
    (is (= {} (get-in done [:state :drafts])))))))

(deftest a-value-is-checked-against-its-limits
 (testing "parse-value"
  (is (= {:value 12} (sheets/parse-value :int "12" {:at-least 1})))
  (is (= {:error "must be at least 1"}
    (sheets/parse-value :int "0" {:at-least 1})))
  (is (= {:error "must be above 0"}
    (sheets/parse-value :float "0" {:above 0})))
  (is (= {:error "must be below 100"}
    (sheets/parse-value :int "100" {:above 0, :below 100})))
  (is (= {:error "must be at most 1"}
    (sheets/parse-value :float "1.5" {:above 0, :at-most 1})))
  (is (= {:value 0.001} (sheets/parse-value :float "1e-3" {:above 0})))
  (is (= {:value 5.0} (sheets/parse-value :float "5" {})))
  (is (= {:value -3} (sheets/parse-value :int "-3" {})))
  (is (= {:error "not a whole number"} (sheets/parse-value :int "2.5" {})))
  (is (= {:error "not a number"} (sheets/parse-value :float "x" {})))
  (is (= {:error "not a number"} (sheets/parse-value :float "" {}))))
 (testing "a value that breaks a limit stays in the buffer with its error"
  (let [[sheet entries] (sheet-of :sampler)
    r (apply press
     sheet
     (state0 entries)
     (concat [KeyType/Enter KeyType/Backspace KeyType/Backspace
       KeyType/Backspace]
      (typed "0")
      [KeyType/Enter]))]
   (is (= "must be at least 1" (get-in r [:state :edit :error])))
   (is (= "0" (get-in r [:state :edit :buffer])))
   (is (= {} (get-in r [:state :drafts])))
   (testing "and typing again clears the error"
    (is (nil? (get-in (press sheet (:state r) \5) [:state :edit :error])))))))

(deftest a-yes-no-setting-turns-over
 (let [[sheet entries] (sheet-of :output)
   at-tex (:state (press sheet
     (state0 entries)
     KeyType/ArrowDown
     KeyType/ArrowDown))
   done (press sheet at-tex KeyType/Enter)]
  (is (= {"FIGURES_TEX" false} (get-in done [:state :drafts])))
  (is (= {} (get-in (press sheet (:state done) KeyType/Enter) [:state :drafts])))))

(deftest drafts-live-with-the-sheet-until-they-are-saved
 (let [[sheet entries] (sheet-of :sampler)
   with-draft (:state (apply press
     sheet
     (state0 entries)
     (concat [KeyType/Enter KeyType/Backspace
       KeyType/Backspace KeyType/Backspace]
      (typed "450")
      [KeyType/Enter])))]
  (testing "down and up keep the drafts"
   (is (= {"N_ADAPT" 450}
     (get-in (press sheet with-draft KeyType/ArrowDown KeyType/ArrowUp)
      [:state :drafts]))))
  (testing "to another bloc and back keeps them, and the page shows its `*` again"
   (let [away (:state (press sheet with-draft KeyType/ArrowRight))
     back (:state (press sheet away KeyType/ArrowLeft))]
    (is (= {"N_ADAPT" 450} (:drafts away)))
    (is (= {"N_ADAPT" 450} (:drafts back)))
    (is (= (sheets/page-lines sheet with-draft) (sheets/page-lines sheet back)))
    (is (re-find #"450 +\*" (str/join "\n" (sheets/page-lines sheet back))))))
  (testing "a draft of another bloc is saved by ctrl-w, with the ones of this bloc"
   (let [away (:state (press sheet with-draft KeyType/ArrowRight))
     saved (press sheet away :ctrl-w)]
    (is (= {"N_ADAPT" 450} (into {} (:save saved))))
    (is (= 450 (get-in saved [:state :entries "N_ADAPT" :saved])))
    (is (= {} (get-in saved [:state :drafts])))))
  (testing "ctrl-x and escape leave"
   (is (= :back (press sheet with-draft :ctrl-x)))
   (is (= :quit (press sheet with-draft KeyType/Escape))))
  (testing "ctrl-u takes the draft of the page's setting back"
   (is (= {} (get-in (press sheet with-draft :ctrl-u) [:state :drafts]))))
  (testing
   "ctrl-w saves every draft of the bloc and the state stands on the new values"
   (let [two (:state (apply press
       sheet
       with-draft
       (concat [KeyType/ArrowDown KeyType/Enter
         KeyType/Backspace KeyType/Backspace
         KeyType/Backspace]
        (typed "900")
        [KeyType/Enter])))
     saved (press sheet two :ctrl-w)]
    (is (= {"N_ADAPT" 450, "N_DRAWS" 900} (into {} (:save saved))))
    (is (= {} (get-in saved [:state :drafts])))
    (is (= 450 (get-in saved [:state :entries "N_ADAPT" :saved])))
    (is (= 900 (get-in saved [:state :entries "N_DRAWS" :saved]))))))
 (testing
  "ctrl-r makes a draft of the default of every setting of the bloc that differs"
  (let [[sheet entries] (sheet-of :sampler)
    saved-state (assoc-in (state0 entries)
     [:entries "N_DRAWS" :saved]
     900)
    reset (press sheet saved-state :ctrl-r)]
   (is (= {"N_DRAWS" 700} (get-in reset [:state :drafts])))
   (testing "and ctrl-u undoes the draft back to the saved value"
    (let [at-draws (:state (press sheet (:state reset) KeyType/ArrowDown))
      undone (press sheet at-draws :ctrl-u)]
     (is (= {} (get-in undone [:state :drafts]))))))))

(deftest a-page-shows-a-draft-and-an-error
 (let [[sheet entries] (sheet-of :sampler)
   typing (:state (apply press
     sheet
     (state0 entries)
     (concat [KeyType/Enter KeyType/Backspace
       KeyType/Backspace KeyType/Backspace]
      (typed "0")
      [KeyType/Enter])))
   lines (nth (:pages sheet) 0)
   page (sheets/with-values lines (sheets/shown-values typing))
   row (first (filter #(str/includes? % "N_ADAPT") page))]
  (testing "what is being typed shows with a cursor in the value cell"
   (is (str/includes? row "╬ 0_ ")))
  (testing "an error goes into the blank row under the setting"
   (let [shown (sheets/with-error page "N_ADAPT" "must be at least 1")]
    (is (= (count page) (count shown)))
    (is (every? #(= 79 (count %)) (butlast shown)))
    (is (some #(str/includes? % "║ must be at least 1║") shown))))
  (testing "a draft is marked with a star in the last column of the cell"
   (let [drafted (:state (apply press
       sheet
       (state0 entries)
       (concat [KeyType/Enter KeyType/Backspace
         KeyType/Backspace KeyType/Backspace]
        (typed "450")
        [KeyType/Enter])))
     row (first (filter #(str/includes? % "N_ADAPT")
       (sheets/with-values lines
        (sheets/shown-values drafted))))]
    (is (str/includes? row "╬ 450"))
    (is (str/includes? row "*╣"))))))

(deftest the-figure-formats-are-tabs
 (let [[sheet entries] (sheet-of :output)
   entries (assoc-in entries ["FIGURES_FORMATS" :saved] [:pdf])
   st (to-page sheet (state0 entries) "FIGURES_FORMATS")
   shown #(get-in (sheets/shown-values %) ["FIGURES_FORMATS" :text])]
  (is (= [:pdf :png :svg] (get-in entries ["FIGURES_FORMATS" :choices])))
  (testing "not being edited, only the formats that are on are shown"
   (is (= "pdf" (shown st)))
   (is (= "pdf png"
     (shown (assoc-in st [:entries "FIGURES_FORMATS" :saved] [:png :pdf])))))
  (testing
   "Enter opens them as tabs with the first in capitals; right moves; Enter toggles"
   (let [open (:state (press sheet st KeyType/Enter))
     moved (:state (press sheet open KeyType/ArrowRight))
     on (:state (press sheet moved KeyType/Enter))
     off (:state (press sheet on KeyType/Enter))]
    (is (= "[PDF] (png) (svg)" (shown open)))
    (is (= "[pdf] (PNG) (svg)" (shown moved)))
    (is (= "[pdf] [PNG] (svg)" (shown on)))
    (is (= "[pdf] (PNG) (svg)" (shown off)) "Enter again turns it off")
    (is (= 17 (count (shown open))))
    (testing "the row below says what the keys do"
     (is (some #(str/includes? % "⏎ toggle  esc done")
       (sheets/page-lines sheet on))))
    (testing
     "Escape is done: the formats on become a draft, in the order of the choices"
     (let [done (press sheet on KeyType/Escape)]
      (is (= {"FIGURES_FORMATS" [:pdf :png]} (get-in done [:state :drafts])))
      (is (nil? (get-in done [:state :edit])))))
    (testing "Tab goes round, and left does not go past the first"
     (is (= "[pdf] (png) (SVG)"
       (shown (:state (press sheet open KeyType/Tab KeyType/Tab)))))
     (is (= "[PDF] (png) (svg)"
       (shown (:state (press sheet open KeyType/ArrowLeft))))))))
  (testing "none on is refused: Escape keeps the tabs open and says so"
   (let [none (press sheet st KeyType/Enter KeyType/Enter KeyType/Escape)]
    (is (= "pick one or more" (get-in none [:state :edit :error])))
    (is (<= (count "pick one or more") 18))
    (is (some #(str/includes? % "pick one or more")
      (sheets/page-lines sheet (:state none))))
    (is (= {} (get-in none [:state :drafts])))
    (testing "turning one on again lets Escape finish"
     (let [again (press sheet (:state none) KeyType/Enter KeyType/Escape)]
      (is (nil? (get-in again [:state :edit])))
      (is (= {} (get-in again [:state :drafts]))
       "the same as saved is no draft")))))))

(deftest a-colour-is-picked-from-a-list
 (let [[sheet entries] (sheet-of :plots)
   st (to-page sheet (state0 entries) "PLOT_COLOUR_MAP")
   open (:state (press sheet st KeyType/Enter))
   edit #(get-in % [:state :edit])]
  (testing "the list opens on the colour in use, with nothing typed"
   (is (= "" (:buffer (:edit open))))
   (is (= 6 (count (:matches (:edit open)))))
   (is (= "crimson" (nth (:matches (:edit open)) (:index (:edit open))))))
  (testing "typing narrows the list to the names that start with it"
   (let [r (press sheet open \c \r)]
    (is (= ["crimson" "crimson2"] (:matches (edit r))))
    (is (= 0 (:index (edit r))))))
  (testing "down and up move in the list and go round"
   (let [r (press sheet open \d)]
    (is (= ["darkorange"] (:matches (edit r))))
    (is (= 0 (:index (edit (press sheet (:state r) KeyType/ArrowDown))))))
   (is (= 3 (:index (edit (press sheet open KeyType/ArrowDown KeyType/ArrowDown))))
    "the list opens on crimson, the second name; two down is the fourth")
   (is (= 5 (:index (edit (press sheet open KeyType/ArrowUp KeyType/ArrowUp))))
    "up from the second name goes to the first and then round to the last"))
  (testing "Tab takes the highlighted name into the text"
   (is (= "crimson2"
     (:buffer (edit (press sheet open \c KeyType/ArrowDown KeyType/Tab))))))
  (testing "Enter picks the highlighted name as a draft, a keyword like the default"
   (let [r (press sheet open \d KeyType/Enter)]
    (is (= {"PLOT_COLOUR_MAP" :darkorange} (get-in r [:state :drafts])))
    (is (nil? (edit r)))))
  (testing "a colour written #rrggbb is taken as it is"
   (let [r (apply press sheet open (concat (typed "#ff0000") [KeyType/Enter]))]
    (is (= {"PLOT_COLOUR_MAP" "#ff0000"} (get-in r [:state :drafts])))))
  (testing "a name that is not in the list is refused, and the error is short"
   (let [r (press sheet open \z KeyType/Enter)]
    (is (= "not a known colour" (:error (edit r))))
    (is (<= (count (:error (edit r))) 18))))
  (testing "Escape drops it"
   (is (nil? (edit (press sheet open \c KeyType/Escape)))))))

(deftest a-font-is-picked-from-a-list-too
 (let [[sheet entries] (sheet-of :plots)
   at-math (to-page sheet (state0 entries) "PLOT_MATH_FONT")
   at-text (to-page sheet (state0 entries) "PLOT_TEXT_FONT")
   edit #(get-in % [:state :edit])]
  (testing "a math font is chosen from the math fonts"
   (is (= ["Pagella Math" "Latin Modern Math"]
     (:matches (edit (press sheet at-math KeyType/Enter))))))
  (testing "a text font from all the fonts, kept as the system spells it"
   (let [r (press sheet
      at-text
      KeyType/Enter
      \p
      \a
      \g
      \e
      \l
      \l
      \a
      \space
      \t
      KeyType/Enter)]
    (is (= {"PLOT_TEXT_FONT" "Pagella Text"} (get-in r [:state :drafts])))))
  (testing "a machine without a list of fonts takes the text as it is"
   (let [blank (assoc (state0 entries) :catalog (fn [_ _] []))
     r (apply press
      sheet
      (to-page sheet blank "PLOT_TEXT_FONT")
      (concat [KeyType/Enter] (typed "x") [KeyType/Enter]))]
    (is (= {"PLOT_TEXT_FONT" "x"} (get-in r [:state :drafts])))))))

(deftest the-dropdown-takes-the-whole-description-column
 (let [[sheet entries] (sheet-of :plots)
   many (fn [_ _] (mapv #(str "name" %) (range 60)))
   st (assoc (to-page sheet (state0 entries) "PLOT_COLOUR_MAP") :catalog many)
   open (:state (press sheet st KeyType/Enter))
   lines (sheets/page-lines sheet open)
   original (nth (:pages sheet) (:i open))
   plain (sheets/with-values original (sheets/shown-values open))
   desc (fn [ls i] (subs (nth ls i) 29 58))]
  (testing "the page keeps its shape"
   (is (= (count original) (count lines)))
   (is (every? #(= 79 (count %)) (butlast lines))))
  (testing
   "the dropdown is written from the top of the column: 17 names, the status last"
   (doseq [k (range 17)]
    (is (str/includes? (desc lines (+ 2 k)) (str "name" k)) (str "row " (+ 2 k))))
   (is (str/starts-with? (desc lines 2) " > name0"))
   (is (str/starts-with? (desc lines 3) "   name1"))
   (is (str/includes? (desc lines 19) "1 of 60 matches")))
  (testing "nothing of the descriptions is left in the column"
   (doseq [i (range 2 20)]
    (is (not (re-find #"[a-z]{4} of|Colour|posterior" (desc lines i)))
     (str "row " i))))
  (testing "the name column and the value column are as they were, typing included"
   (doseq [i (range 2 20)]
    (is (= (subs (nth plain i) 0 29) (subs (nth lines i) 0 29))
     (str "names, row " i))
    (is (= (subs (nth plain i) 58) (subs (nth lines i) 58))
     (str "values, row " i))))
  (testing "the frame, the footer and the typing of the setting stay"
   (is (= (take 2 original) (take 2 lines)))
   (is (= (take-last 4 original) (take-last 4 lines)))
   (is (str/includes? (first (filter #(str/includes? % "PLOT_COLOUR_MAP") lines))
     "_")))
  (testing "scrolling keeps the highlighted name in view"
   (let [down (:state (apply press sheet open (repeat 30 KeyType/ArrowDown)))
     shown (sheets/page-lines sheet down)]
    (is (some #(str/includes? (desc shown %) "> name30") (range 2 20)))
    (is (str/includes? (desc shown 19) "31 of 60 matches"))))
  (testing "the error of a pick shows in the status row"
   (let [bad (:state (press sheet open \z KeyType/Enter))
     shown (sheets/page-lines sheet bad)]
    (is (str/includes? (desc shown 19) "not a known colour"))))
  (testing "a short list is at the top and the status stays on the last row"
   (let [few (assoc st :catalog (fn [_ _] ["a" "b"]))
     shown (sheets/page-lines sheet (:state (press sheet few KeyType/Enter)))]
    (is (str/starts-with? (desc shown 2) " > a"))
    (is (str/starts-with? (desc shown 3) "   b"))
    (is (str/blank? (desc shown 4)))
    (is (str/includes? (desc shown 19) "1 of 2 matches"))))
  (testing "a font list is the same, over the same column"
   (let [fonts
     (assoc (to-page sheet (state0 entries) "PLOT_TEXT_FONT") :catalog many)
     shown (sheets/page-lines sheet (:state (press sheet fonts KeyType/Enter)))]
    (is (str/starts-with? (desc shown 2) " > name0"))
    (is (str/includes? (desc shown 19) "1 of 60 matches"))))
  (testing "at the bottom of the page it is the same: the column does not move"
   (let [last-page
     (to-page sheet (assoc (state0 entries) :catalog many) "PLOT_COLOUR_AXIS")
     shown (sheets/page-lines sheet
      (:state (press sheet last-page KeyType/Enter)))]
    (is (str/starts-with? (desc shown 2) " > name0"))
    (is (every? #(= 79 (count %)) (butlast shown)))))))

(deftest a-colour-dropdown-has-its-swatches-in-one-column
 (let [[sheet entries] (sheet-of :plots)
   rgb {"black" [0 0 0], "crimson" [220 20 60], "crimson2" [238 18 52]}
   st (assoc (to-page sheet (state0 entries) "PLOT_COLOUR_MAP") :swatch rgb)
   open (:state (press sheet st KeyType/Enter))
   lines (sheets/page-lines sheet open)
   marks (sheets/page-marks sheet open)]
  (testing "one swatch for each name that has a colour, none for the others"
   (is (= 3 (count marks)))
   (is (= #{[0 0 0] [220 20 60] [238 18 52]} (set (map #(nth % 2) marks)))))
  (testing "they are all in the same column, inside the description column"
   (is (= 1 (count (set (map second marks)))))
   (is (= 55 (second (first marks))))
   (is (<= 29 (second (first marks)) 57)))
  (testing "each is on its name's row, right of the name, in a blank cell"
   (doseq [[row column [r g b]] marks
     :let [line (nth lines row)
      colour-name (some (fn [[n c]] (when (= c [r g b]) n)) rgb)]]
    (is (str/includes? (subs line 29 55) colour-name))
    (is (= \space (nth line column)))
    (is (< (+ 29 3 (count colour-name)) column))))
  (testing "the swatches line up whatever the length of the names"
   (is (= [2 3 4] (map first (sort-by first marks)))))
  (testing
   "a long list keeps them in the column, on the rows of the names, none on the status"
   (let [many (fn [_ _]
      (mapv #(str "c" (apply str (repeat (mod % 20) "x")) %) (range 40)))
     everything (fn [_] [1 2 3])
     st (-> (to-page sheet (state0 entries) "PLOT_COLOUR_MAP")
      (assoc :catalog many :swatch everything))
     open (:state (press sheet st KeyType/Enter))
     down (:state (apply press sheet open (repeat 20 KeyType/ArrowDown)))
     marks (sheets/page-marks sheet down)]
    (is (= 17 (count marks)))
    (is (= #{55} (set (map second marks))))
    (is (= (range 2 19) (sort (map first marks))))))
  (testing "no swatches for a font list, and none without a dropdown"
   (let [at-font
     (to-page sheet (assoc (state0 entries) :swatch rgb) "PLOT_TEXT_FONT")
     opened (:state (press sheet at-font KeyType/Enter))]
    (is (= [] (sheets/page-marks sheet opened)))
    (is (= [] (sheets/page-marks sheet at-font)))))))

(deftest the-swatches-are-on-a-white-panel-over-the-whole-description-column
 (let [[sheet entries] (sheet-of :plots)
   rgb {"black" [0 0 0]}
   at (fn [setting]
    (to-page sheet (assoc (state0 entries) :swatch rgb) setting))
   open (fn [setting] (:state (press sheet (at setting) KeyType/Enter)))
   panel-of (fn [st] (sheets/page-panel sheet st))]
  (testing "a colour dropdown: every row of the table, the description column"
   (let [panel (panel-of (open "PLOT_COLOUR_MAP"))]
    (is (= (range 2 20) (map first panel)))
    (is (= #{[29 29]} (set (map rest panel))))))
  (testing "a tuple with a colour part, also while the other part is in focus"
   (let [st (open "PLOT_COLOUR_BAND")]
    (is (seq (panel-of st)))
    (is (seq (panel-of (:state (press sheet st KeyType/ArrowDown)))))))
  (testing "no panel for a font list, a tuple of numbers, or without an edit"
   (is (nil? (panel-of (open "PLOT_TEXT_FONT"))))
   (is (nil? (panel-of (open "PLOT_WIDTH_HEIGHT_CM"))))
   (is (nil? (panel-of (at "PLOT_COLOUR_MAP")))))))

(deftest a-value-must-keep-the-rules-that-tie-settings-together
 (let [[sheet entries] (sheet-of :model)
   at (fn [st setting] (to-page sheet st setting))
   type-in (fn [st setting text]
    (apply press
     sheet
     (at st setting)
     (concat [KeyType/Enter]
      (repeat 16 KeyType/Backspace)
      (typed text)
      [KeyType/Enter])))
   edit #(get-in % [:state :edit])]
  (testing
   "a mode outside the bounds is refused, with a short message, and stays open"
   (let [r (type-in (state0 entries) "MODE_δρ₁₂" "50")]
    (is (= "outside the bounds" (:error (edit r))))
    (is (<= (count (:error (edit r))) 18))
    (is (= {} (get-in r [:state :drafts])))))
  (testing "a mode inside the bounds is a draft"
   (let [r (type-in (state0 entries) "MODE_δρ₁₂" "1.5")]
    (is (= {"MODE_δρ₁₂" 1.5} (get-in r [:state :drafts])))
    (is (nil? (edit r)))))
  (testing "the edges of the bounds are outside"
   (is (= "outside the bounds"
     (:error (edit (type-in (state0 entries) "MODE_δρ₁₂" "2")))))
   (is (= "outside the bounds"
     (:error (edit (type-in (state0 entries) "MODE_δρ₁₂" "-10")))))
   (is (nil? (edit (type-in (state0 entries) "MODE_δρ₁₂" "1.99")))))
  (testing "a sample count below the occlusion count, and the other way round"
   (let [low (type-in (state0 entries) "SHELL_SAMPLE" "50")
     high (type-in (state0 entries) "SASA_N_OCC" "300")]
    (is (= "below SASA_N_OCC" (:error (edit low))))
    (is (= "above SHELL_SAMPLE" (:error (edit high))))
    (is (every? #(<= (count %) 18) [(:error (edit low)) (:error (edit high))]))))
  (testing "a draft counts as the value of its setting for the rules"
   (let [raised (:state (type-in (state0 entries) "SHELL_SAMPLE" "400"))
     both (:state (type-in raised "SASA_N_OCC" "300"))
     lowered (type-in both "SHELL_SAMPLE" "250")]
    (is (= {"SHELL_SAMPLE" 400, "SASA_N_OCC" 300} (:drafts both)))
    (is (= "below SASA_N_OCC" (:error (edit lowered))))
    (is (= {"SHELL_SAMPLE" 400, "SASA_N_OCC" 300}
      (get-in lowered [:state :drafts])))))
  (testing "the same number is fine when it keeps the rule, at the edge too"
   (let [r (type-in (state0 entries) "SASA_N_OCC" "256")]
    (is (= {"SASA_N_OCC" 256} (get-in r [:state :drafts])))))
  (testing "the rules are the bundled ones, and none is left out of the sheets"
   (is (every? (fn [{:keys [setting]}] (contains? entries setting))
     (filter #(contains? #{"MODE_δρ₁₂" "SASA_N_OCC" "EXCL_VOL_CORR_EPS"}
       (:setting %))
      (settings/read-relations)))))
  (testing "a state with no rules accepts what the rules would refuse"
   (let [st (sheets/initial-state entries catalog)
     r (type-in st "MODE_δρ₁₂" "50")]
    (is (= {"MODE_δρ₁₂" 50.0} (get-in r [:state :drafts])))))))

(deftest a-wiped-setting-shows-its-notice-until-it-is-saved
 (let [[sheet entries] (sheet-of :sampler)
   with-notice (assoc-in entries ["N_ADAPT" :notice] "reset to default")
   st (state0 with-notice)]
  (testing "the page of the setting has the notice in the blank row under it"
   (let [lines (sheets/page-lines sheet st)]
    (is (some #(str/includes? % "║ reset to default") lines))
    (is (every? #(= 79 (count %)) (butlast lines)))))
  (testing "a page of another setting does not"
   (let [down (:state (press sheet st KeyType/ArrowDown))]
    (is (not-any? #(str/includes? % "reset to default")
      (sheets/page-lines sheet down)))))
  (testing "a new value takes the notice away"
   (let [done (apply press
      sheet
      st
      (concat [KeyType/Enter KeyType/Backspace KeyType/Backspace
        KeyType/Backspace]
       (typed "450")
       [KeyType/Enter]))]
    (is (nil? (get-in done [:state :entries "N_ADAPT" :notice])))
    (is (not-any? #(str/includes? % "reset to default")
      (sheets/page-lines sheet (:state done))))))
  (testing "saving takes it away too"
   (let [drafted (:state (press sheet st KeyType/Enter \9 KeyType/Enter))
     saved (press sheet drafted :ctrl-w)]
    (is (nil? (get-in saved [:state :entries "N_ADAPT" :notice])))))
  (testing "while a value is being typed the page shows the typing, not the notice"
   (let [typing (:state (press sheet st KeyType/Enter))]
    (is (not-any? #(str/includes? % "reset to default")
      (sheets/page-lines sheet typing)))))))

;; --- editing a tuple

(def ^:private tuple-settings
 "Every tuple setting: [screen setting parts]."
 [[:sampler "CHAIN_START_RADII" ["first" "second" "third"]]
  [:sampler "MAP_JITTER_RADII" ["first" "second" "third"]]
  [:model "BOUNDS_δρ₁₂" ["low" "high"]]
  [:model "EXCL_VOL_CORR_BOUNDS" ["low" "high"]]
  [:plots "PLOT_COLOUR_ERRORBAR" ["colour" "opacity"]]
  [:plots "PLOT_COLOUR_BAND" ["colour" "opacity"]]
  [:plots "PLOT_COLOUR_BAND_RESID" ["colour" "opacity"]]
  [:plots "PLOT_COLOUR_HIST" ["colour" "opacity"]]
  [:plots "PLOT_WIDTH_HEIGHT_CM" ["width" "height"]]
  [:plots "PLOT_PREVIEW_SIZE" ["width" "height"]]
  [:plots "PLOT_YLIM_LOG" ["lower" "upper"]]])

(defn ^:private tuple-state
 "The state of the sheet of `screen` with the cursor on `setting`, a state that knows the
 swatches of three colours, and the sheet."
 [screen setting]
 (let [[sheet entries] (sheet-of screen)
   rgb {"darkorange" [255 140 0], "gray20" [51 51 51], "gray40" [102 102 102]}]
  [sheet
   (assoc (to-page sheet (state0 entries) setting)
    :swatch
    (fn [n] (get rgb n [1 2 3])))]))

(defn ^:private edit-tuple
 "The result of Enter on `setting` of `screen` and then `inputs`."
 [screen setting & inputs]
 (let [[sheet st] (tuple-state screen setting)]
  [sheet (apply press sheet st KeyType/Enter inputs)]))

(def ^:private clear (vec (repeat 20 KeyType/Backspace)))

(defn ^:private in-part
 "Keys that go to part `k` (0-based) and replace its text with `text`."
 [k text]
 (concat (repeat k KeyType/ArrowDown) clear (typed text)))

(defn ^:private desc-cells
 "The description cells of the body of a page, rows 2 to 19."
 [lines]
 (mapv #(subs (nth lines %) 29 58) (range 2 20)))

(deftest every-tuple-opens-a-form-with-its-parts
 (doseq [[screen setting parts] tuple-settings
   :let [[sheet r] (edit-tuple screen setting)
    edit (get-in r [:state :edit])
    lines (sheets/page-lines sheet (:state r))
    cells (desc-cells lines)]]
  (testing setting
   (is (= :tuple (:kind edit)))
   (is (= parts (:labels edit)))
   (is (= (count parts) (count (:buffers edit))))
   (is (= 0 (:focus edit)))
   (testing
    "the form is in the description column, from its top, a row for each part"
    (doseq [[k part] (map-indexed vector parts)]
     (is (str/includes? (nth cells k) part) (str setting " part " part)))
    (is (str/starts-with? (nth cells 0) " > ") "the first part has the focus")
    (is (= " ↑↓ part   ⏎ ok   esc cancel"
      (str/trimr (nth cells (inc (count parts)))))
     "the whole hint fits"))
   (testing "the page keeps its shape"
    (is (every? #(= 79 (count %)) (butlast lines))))
   (testing "Escape closes it and nothing was drafted"
    (let [done (press sheet (:state r) KeyType/Escape)]
     (is (nil? (get-in done [:state :edit])))
     (is (= {} (get-in done [:state :drafts]))))))))

(deftest the-whole-description-column-is-the-form
 (let [[sheet r] (edit-tuple :sampler "CHAIN_START_RADII")
   original (nth (:pages sheet) (:i (:state r)))
   lines (sheets/page-lines sheet (:state r))
   cells (desc-cells lines)]
  (testing "a part's text shows after its name, the first with a cursor"
   (is (= " > first : 4.0_" (str/trimr (nth cells 0))))
   (is (= "   second: 10.0" (str/trimr (nth cells 1))))
   (is (= "   third : 20.0" (str/trimr (nth cells 2)))))
  (testing
   "nothing of the descriptions is left, and the other columns are as they were"
   (is (not-any? #(re-find #"Start|standard|chain|Not recommended" %) cells))
   (doseq [i (range 2 20)]
    (is (= (subs (nth original i) 0 29) (subs (nth lines i) 0 29)))
    (is (= (subs (nth original i) 58 59) (subs (nth lines i) 58 59)))))
  (testing "the frame and the footer are as they were"
   (is (= (take 2 original) (take 2 lines)))
   (is (= (take-last 4 original) (take-last 4 lines))))))

(deftest a-tuple-is-edited-part-by-part
 (testing "the second of three numbers"
  (let [[sheet r] (apply edit-tuple
     :sampler
     "CHAIN_START_RADII"
     (concat (in-part 1 "12") [KeyType/Enter]))]
   (is (= {"CHAIN_START_RADII" [4.0 12.0 20.0]} (get-in r [:state :drafts])))
   (is (nil? (get-in r [:state :edit])))
   (testing "the value cell shows it, with the mark of a draft"
    (let [row (first (filter #(str/includes? % "CHAIN_START_RADII")
        (sheets/page-lines sheet (:state r))))]
     (is (str/includes? row "(4.0, 12.0, 20.0)"))
     (is (str/includes? row "*╣"))))
   (testing "^w saves it"
    (let [saved (press sheet (:state r) :ctrl-w)]
     (is (= [["CHAIN_START_RADII" [4.0 12.0 20.0]]] (:save saved)))))))
 (testing
  "a whole number and an exponent are fine for a float part; a named tuple keeps its keys"
  (let [r (apply edit-tuple
     :sampler
     "CHAIN_START_RADII"
     (concat (in-part 0 "5") (in-part 1 "1e1") [KeyType/Enter]))]
   (is (= [5.0 10.0 20.0]
     (get-in (second r) [:state :drafts "CHAIN_START_RADII"]))))
  (let [r (apply edit-tuple
     :plots
     "PLOT_PREVIEW_SIZE"
     (concat (in-part 0 "80") (in-part 1 "24") [KeyType/Enter]))]
   (is (= {:width 80, :height 24}
     (get-in (second r) [:state :drafts "PLOT_PREVIEW_SIZE"])))))
 (testing "typing the tuple it already has is no draft"
  (is (= {}
    (get-in (second (edit-tuple :sampler "CHAIN_START_RADII" KeyType/Enter))
     [:state :drafts]))))
 (testing
  "up and down move between the parts and stop at the ends; Tab moves down too"
  (let [at #(get-in (second (apply edit-tuple :sampler "CHAIN_START_RADII" %&))
     [:state :edit :focus])]
   (is (= 1 (at KeyType/ArrowDown)))
   (is (= 2 (at KeyType/ArrowDown KeyType/ArrowDown)))
   (is
    (=
     2
     (at KeyType/ArrowDown KeyType/ArrowDown KeyType/ArrowDown KeyType/ArrowDown)))
   (is (= 0 (at KeyType/ArrowUp)))
   (is (= 0 (at KeyType/ArrowDown KeyType/ArrowUp)))
   (is (= 1 (at KeyType/Tab)))
   (is (= 1 (at KeyType/ArrowLeft KeyType/ArrowRight KeyType/ArrowDown))
    "left and right do nothing in a number")))
 (testing "backspace and a limit on the length of a number"
  (let [r (apply edit-tuple
     :sampler
     "CHAIN_START_RADII"
     (concat clear (typed "123") [KeyType/Backspace]))]
   (is (= "12" (get-in (second r) [:state :edit :buffers 0]))))
  (let [r (apply edit-tuple
     :sampler
     "CHAIN_START_RADII"
     (concat clear (typed (apply str (repeat 30 "1")))))]
   (is (= 16 (count (get-in (second r) [:state :edit :buffers 0])))))))

(deftest a-tuple-that-is-not-valid-stays-open-with-what-is-wrong
 (doseq [[screen setting inputs expected]
   [[:sampler "CHAIN_START_RADII" (in-part 1 "abc") "second: not a number"]
    [:sampler "CHAIN_START_RADII" (in-part 0 "") "first: not a number"]
    [:sampler "CHAIN_START_RADII" (in-part 2 "1.2.3") "third: not a number"]
    [:sampler "CHAIN_START_RADII" (in-part 0 "0") "every part above 0"]
    [:sampler "CHAIN_START_RADII" (in-part 1 "-3") "every part above 0"]
    [:sampler "MAP_JITTER_RADII" (in-part 2 "0") "every part above 0"]
    [:model "BOUNDS_δρ₁₂" (concat (in-part 0 "3") (in-part 1 "1"))
     "first must be below second"]
    [:model "BOUNDS_δρ₁₂" (concat (in-part 0 "1") (in-part 1 "1"))
     "first must be below second"]
    [:model "BOUNDS_δρ₁₂" (concat (in-part 0 "-3") (in-part 1 "0.5"))
     "mode out of range"]
    [:model "EXCL_VOL_CORR_BOUNDS" (concat (in-part 0 "0") (in-part 1 "1"))
     "first below second, above 0"]
    [:model "EXCL_VOL_CORR_BOUNDS" (concat (in-part 0 "1") (in-part 1 "1.01"))
     "bounds too narrow"]
    [:plots "PLOT_WIDTH_HEIGHT_CM" (in-part 0 "0") "every part above 0"]
    [:plots "PLOT_PREVIEW_SIZE" (in-part 0 "7.5") "width: not a whole number"]
    [:plots "PLOT_PREVIEW_SIZE" (in-part 1 "0") "every part above 0"]
    [:plots "PLOT_YLIM_LOG" (concat (in-part 0 "2") (in-part 1 "1"))
     "first below second, above 0"]
    [:plots "PLOT_YLIM_LOG" (in-part 0 "-1") "first below second, above 0"]
    [:plots "PLOT_COLOUR_BAND" (in-part 1 "1.5") "opacity from 0 to 1"]
    [:plots "PLOT_COLOUR_BAND" (in-part 1 "-0.1") "opacity from 0 to 1"]
    [:plots "PLOT_COLOUR_BAND" (concat (in-part 0 "zzzz"))
     "colour: not a known colour"]
    [:plots "PLOT_COLOUR_HIST" (in-part 1 "x") "opacity: not a number"]]]
  (let [[sheet r] (apply edit-tuple screen setting (concat inputs [KeyType/Enter]))
    edit (get-in r [:state :edit])]
   (testing (str setting " " expected)
    (is (some? edit) "the form stays open")
    (is (= expected (:error edit)))
    (is (<= (count (:error edit)) 29))
    (is (= {} (get-in r [:state :drafts])))
    (testing "the error shows in the form, and typing again clears it"
     (is (some #(str/includes? % expected)
       (desc-cells (sheets/page-lines sheet (:state r)))))
     (is (nil? (get-in (press sheet (:state r) \1) [:state :edit :error]))))))))

(deftest a-colour-part-picks-among-the-colours-that-match
 (let [setting "PLOT_COLOUR_BAND"
   drafted (fn [& inputs]
    (get-in
     (second
      (apply edit-tuple :plots setting (concat inputs [KeyType/Enter])))
     [:state :drafts setting]))]
  (testing "the list opens on the colour part, with all the colours"
   (let [[_ r] (edit-tuple :plots setting)]
    (is (= 6 (count (get-in r [:state :edit :matches]))))))
  (testing "typing narrows it; Tab takes the first into the text; Enter accepts"
   (is (nil? (drafted \d KeyType/Tab)) "darkorange is the colour it has: no draft")
   (is (= [:gray20 0.15] (drafted \g))
    "Enter picks the one highlighted when the text is not a colour yet")
   (is (= [:gray40 0.15] (drafted \g \r \a \y \4 \0)) "a whole name"))
  (testing "left and right pick another of the matches, and the pick is taken"
   (is (= [:gray20 0.15] (drafted \g \r)))
   (is (= [:gray40 0.15] (drafted \g \r KeyType/ArrowRight)))
   (is (= [:gray40 0.15] (drafted \g \r KeyType/ArrowLeft))
    "left from the first goes round")
   (is (= [:gray40 0.15] (drafted \g \r KeyType/ArrowRight KeyType/Tab)))
   (is (= [:gray20 0.15] (drafted \g \r KeyType/ArrowRight KeyType/ArrowRight))))
  (testing "a colour written #rrggbb, in either case"
   (is (= ["#ff0000" 0.15] (apply drafted (typed "#ff0000"))))
   (is (= ["#ff0000" 0.15] (apply drafted (typed "#FF0000")))))
  (testing "the colour and the opacity together"
   (is (= [:darkorange 0.5]
     (apply drafted (concat (typed "d") [KeyType/Tab] (in-part 1 "0.5"))))))
  (testing "a name that is not a colour is refused, with the part in focus"
   (let [[_ r] (apply edit-tuple
      :plots
      setting
      (concat (typed "nocolour") [KeyType/Enter]))]
    (is (= "colour: not a known colour" (get-in r [:state :edit :error])))
    (is (= 0 (get-in r [:state :edit :focus])))))
  (testing "moving to the opacity ends the list; moving back brings it again"
   (let [[_ down] (edit-tuple :plots setting \d KeyType/ArrowDown)
     [_ up] (edit-tuple :plots setting \d KeyType/ArrowDown KeyType/ArrowUp)]
    (is (= [] (get-in down [:state :edit :matches])))
    (is (= ["darkorange"] (get-in up [:state :edit :matches]))))))
 (testing "a part that is not a colour does not pick"
  (let [[_ r] (edit-tuple :plots "PLOT_WIDTH_HEIGHT_CM" KeyType/ArrowRight \a)]
   (is (= [] (get-in r [:state :edit :matches]))))))

(deftest the-swatches-of-a-colour-part-are-in-one-column
 (let [[sheet r] (edit-tuple :plots "PLOT_COLOUR_BAND" KeyType/Backspace)
   st (assoc (:state r)
    :swatch
    (fn [n] (when (#{"darkorange" "gray20" "gray40"} n) [1 2 3])))
   lines (sheets/page-lines sheet st)
   marks (sheets/page-marks sheet st)
   cells (desc-cells lines)]
  (testing "the form: the parts, the keys, the colours that match under a hint"
   (is (str/includes? (nth cells 0) "colour"))
   (is (str/includes? (nth cells 1) "opacity"))
   (is (= " ↑↓ part   ⏎ ok   esc cancel" (str/trimr (nth cells 3)))
    "the whole hint fits")
   (is (str/includes? (nth cells 5) "←→ pick  Tab take"))
   (is (some #(str/includes? % "> black") cells))
   (is (some #(str/includes? % "gray40") cells)))
  (testing "a swatch for each colour that has one, all in the same column"
   (is (= 3 (count marks)))
   (is (= #{55} (set (map second marks))))
   (is (every? (fn [[row]] (<= 2 row 19)) marks)))
  (testing "each swatch is on the row of its name"
   (doseq [[row] marks
     :let [cell (nth cells (- row 2))]]
    (is (re-find #"darkorange|gray20|gray40" cell))))
  (testing "a number part has no swatches"
   (is (= []
     (sheets/page-marks
      sheet
      (:state (second (edit-tuple :plots "PLOT_WIDTH_HEIGHT_CM")))))))))

(deftest tuples-from-the-settings-store-have-their-shape-and-parts
 (let [entries (settings/screen-entries
    (settings/merge-defaults (settings/read-defaults) nil)
    :plots)]
  (is (= [:colour :float] (get-in entries ["PLOT_COLOUR_BAND" :shape])))
  (is (= ["colour" "opacity"] (get-in entries ["PLOT_COLOUR_BAND" :parts])))
  (is (= {:width :int, :height :int} (get-in entries ["PLOT_PREVIEW_SIZE" :shape])))
  (is (every? (fn [[_ {kind :type, :keys [shape parts]}]]
     (or (not= kind :tuple) (= (count shape) (count parts))))
    entries))))
