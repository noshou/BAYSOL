;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The settings sheets: one folder of pre-rendered pages (resources/<name>-settings/pages)
;; for each kind of setting. A sheet is split into blocs, each a table of settings; a page
;; shows one bloc with the cursor `>` on one of its settings, so a bloc of n settings is n
;; pages.
;; The footer of every page says which bloc it belongs to (`sampler [2 / 4]`), and that is
;; where the blocs are read from, so a sheet needs no table of its own: the page files are
;; the single source of what maps where.
;;
;; The keys (the footer of the pages lists them):
;;   down, up    the next and the previous setting of the bloc (no wrapping)
;;   right, left the first page (first setting) of the next and of the previous bloc, where
;;               there is one; the footer shows `next bloc: →` and `prev bloc: ←` only then
;;   ctrl-b      back to the settings menu (the footer's `menu: ^b`)
;;   escape      quit the program (the footer's `quit: esc`)
;;   enter       edit the value of the setting under the cursor:
;;                 a number: type it, Enter checks it against its limits, Escape cancels;
;;                 a yes/no setting: turn it over;
;;                 a colour or a font: type to narrow a list of the names there are (a
;;                   dropdown below the setting), up and down move in it, Tab takes the
;;                   highlighted name into the text, Enter picks it, Escape cancels;
;;                 some of a few choices (the figure formats), shown as the ones that
;;                   are on (`pdf png`); Enter opens them as tabs `[pdf] (png) (svg)`
;;                   (`[ ]` on, `( )` off): left, right and Tab move between them, Enter
;;                   turns the one in capitals on or off, Escape is done (one at least
;;                   must be on); the row below says `⏎ toggle  esc done`.
;;               The new value is a draft, marked `*`, until it is saved. Tuples cannot be
;;               edited yet
;;   ctrl-s      save every draft of the sheet, in any bloc, into settings.edn
;;   ctrl-u      undo: the draft of the setting under the cursor goes back to what
;;               was saved
;;   ctrl-r      reset: every setting of the bloc becomes a draft of its default
;;   Drafts survive every move inside the sheet, down, up, left and right, and show their
;;   `*` when their page comes back; only ctrl-s keeps them: leaving the sheet (ctrl-b,
;;   escape) drops the ones not saved.

(ns baysol.tui.screens.sheets
 (:require [baysol.tui.screens.page-load :as pgld]
  [baysol.tui.screens.picker :as picker]
  [baysol.tui.screens.state :as state]
  [baysol.tui.settings :as settings]
  [baysol.tui.validate :as validate]
  [clojure.java.io :as io]
  [clojure.string :as str])
 (:import (com.googlecode.lanterna TextColor)
  (com.googlecode.lanterna.input KeyType)
  (com.googlecode.lanterna.screen TerminalScreen)))

(set! *warn-on-reflection* true)

(defn page-count
 "How many pages the sheet in the resource folder `dir` (for example \"sampler-settings\")
 has: the files page1.txt, page2.txt, ... up to the first one that is missing."
 [dir]
 (count (take-while #(io/resource (str dir "/pages/page" % ".txt"))
   (iterate inc 1))))

(defn bloc-of
 "The number of the bloc that the page `lines` belongs to, read from the counter
 `name [b / B]` in the first footer line (the third from the last); nil if there is none."
 [lines]
 (some->> (nth lines (- (count lines) 3) nil)
  (re-find #"\[(\d+)\s*/\s*(\d+)\s*\]")
  second
  parse-long))

(defn load-sheet
 "The sheet of the resource folder `dir`: `{:dir dir, :pages [lines ...], :blocs [b ...]}`,
 the page lines in order and the bloc number of each page (1 for a page without a counter)."
 [dir]
 (let [pages (mapv #(pgld/load-ascii (str "page" %) dir)
    (range 1 (inc (page-count dir))))]
  {:dir dir, :pages pages, :blocs (mapv #(or (bloc-of %) 1) pages)}))

(defn ^:private first-page-of
 "The index of the first page of bloc `bloc` in the vector of bloc numbers `blocs`, or nil
 if there is no such bloc."
 [blocs bloc]
 (first (keep-indexed #(when (= %2 bloc) %1) blocs)))

(defn move
 "Where `input` leads from page `i` (0-based) of `sheet`: the index of another page, `i`
 itself when nothing happens, or an action: `:back` (to the settings menu) or `:quit` (the
 program). A bloc always starts at its first page: right and left go to the first page
 of bloc b + 1 and b - 1 where those exist."
 [sheet i input]
 (let [blocs (:blocs sheet)
   bloc (nth blocs i)
   same-bloc? #(= bloc (get blocs %))]
  (condp = input
   KeyType/ArrowDown (if (same-bloc? (inc i)) (inc i) i)
   KeyType/ArrowUp (if (same-bloc? (dec i)) (dec i) i)
   KeyType/ArrowRight (or (first-page-of blocs (inc bloc)) i)
   KeyType/ArrowLeft (or (first-page-of blocs (dec bloc)) i)
   :ctrl-b :back
   KeyType/Escape :quit
   KeyType/EOF :quit ; the terminal went away: leave rather than spin
   i)))

;; Where the value cell of a row begins (the columns before it are the indent or the
;; cursor, the name field and the description field with their borders) and how wide it
;; is; its first column is left blank and its last one holds the `*` of a draft.
(def ^:private value-column 59)
(def ^:private value-width 19)

;; Where the description cell of a row begins and how wide it is: the column the dropdowns,
;; the form of a tuple and the notices are written in.
(def ^:private description-column 29)
(def ^:private description-width 29)

(def ^:private max-buffer
 "The longest text typed into a number's value cell: the cell's 17 characters less one for
 the cursor shown while typing."
 16)

(def ^:private max-text
 "The longest name typed to pick a colour or a font."
 40)

(defn ^:private put-cell
 "The line `line` with `text`, padded or cut to `width`, written at column `from`."
 [^String line from width text]
 (let [cell (subs (str text (apply str (repeat width \space))) 0 width)]
  (str (subs line 0 from) cell (subs line (+ from width)))))

(defn with-values
 "The lines of a page with the value of each setting on it written in the value cell of
 the setting's first row. `shown` maps a setting name to `{:value v}`, to which `:draft?`
 adds the mark `*` and `:text` replaces the text of the value (what is being typed). A
 name it lacks leaves its cell blank. The lines keep their width."
 [lines shown]
 (mapv (fn [^String line]
   (if-let [[_ setting] (re-find #"^(?: > |   )╠([^╬]*)╬" line)]
    (if-let [{:keys [value text draft?]} (get shown (str/trim setting))]
     (let [text (or text (settings/format-value value))
       cell (subs (str " " text (apply str (repeat value-width \space)))
        0
        value-width)
       cell (if draft? (str (subs cell 0 (dec value-width)) "*") cell)]
      (put-cell line value-column value-width cell))
     line)
    line))
  lines))

(defn ^:private setting-rows
 "The indexes of the first rows of the settings on a page, with each name:
 `[[index name] ...]`."
 [lines]
 (keep-indexed #(when-let [[_ n] (re-find #"^(?: > |   )╠([^╬]*)╬" %2)]
   [%1 (str/trim n)])
  lines))

(defn page-settings
 "The names of the settings on the page `lines`, top to bottom."
 [lines]
 (mapv second (setting-rows lines)))

(defn cursor-setting
 "The name of the setting under the cursor `>` on the page `lines`."
 [lines]
 (some (fn [[i n]] (when (str/starts-with? (nth lines i) " > ") n))
  (setting-rows lines)))

(defn ^:private body-end
 "The index of the bottom rule of the table on the page `lines`."
 [lines]
 (count (take-while #(not (str/starts-with? % "   ╚")) lines)))

(defn with-error
 "The lines of a page with `message` written in the value cell of the last row of the
 setting `setting`: the blank row under it when there is one, else its last line. The
 cell holds 18 characters."
 [lines setting message]
 (let [rows (setting-rows lines)
   [i] (first (filter #(= setting (second %)) rows))
   after (or (first (keep (fn [[j]] (when (> j i) j)) rows)) (body-end lines))
   row (dec after)]
  (assoc lines
   row
   (put-cell (nth lines row) value-column value-width (str " " message)))))

;; --- what is offered to pick from

(defn tabs-text
 "A choice setting as the value cell shows it. Not being edited (`focus` is nil): only the
 choices that are on, `pdf png`. Being edited: every choice as a tab, `[pdf] (png) (svg)`,
 the ones that are on in square brackets, the others in round ones, and the one at `focus`
 in capitals."
 [options selected focus]
 (if (nil? focus)
  (str/join " " (map name (filter selected options)))
  (str/join " "
   (map-indexed
    (fn [i o]
     (let [label (if (= i focus)
        (str/upper-case (name o))
        (name o))]
      (if (contains? selected o) (str "[" label "]") (str "(" label ")"))))
    options))))

;; The dropdowns and the form of a tuple take the whole description column of the table:
;; it is made blank and written over, from its top row down. The names are written from
;; its left edge, and the swatch of each colour is in one column of its own.
(def ^:private swatch-offset
 "Where the swatch of a colour is in the description column: a fixed column, so the swatches
 make one column."
 26)

(def ^:private name-room
 "The characters of a name in the description column, after the marker."
 23)

(defn ^:private column-rows
 "The first and the last row of the body of the table on the page `lines`: `[first last]`."
 [lines]
 [2 (dec (body-end lines))])

(defn ^:private cut
 "`s` cut to `n` characters."
 [^String s n]
 (subs s 0 (min (count s) n)))

(defn ^:private blank-description
 "The lines of a page with the description cell of every row of the body made blank."
 [lines]
 (let [[top bottom] (column-rows lines)]
  (reduce (fn [ls i] (update ls i put-cell description-column description-width ""))
   lines
   (range top (inc bottom)))))

(defn ^:private dropdown-layout
 "What the dropdown of the edit `edit` writes in the description column of the page
 `lines`: `{:top first row :from first name shown :items how many :texts [cell ...]
 :status-row :status}`: the names from the top row, the highlighted one marked `>` and
 scrolled into view, and the status (or the error) on the last row."
 [lines {:keys [matches index error]}]
 (let [[top bottom] (column-rows lines)
   n (count matches)
   items (min (- bottom top) n)
   from (max 0 (min (- index (quot items 2)) (- n items)))
   status (or error (picker/count-status index n description-width))]
  {:top top,
   :from from,
   :items items,
   :status-row bottom,
   :status (picker/status-line status description-width),
   :texts
   (vec (for [k (range items)
      :let [at (+ from k)]]
     (str " " (if (= at index) "> " "  ") (cut (nth matches at) name-room))))}))

(defn with-dropdown
 "The lines of a page with the dropdown of the edit `edit` written in the description
 column, which is made blank for it: the names from the top, the highlighted one marked `>`
 and scrolled into view, and a status row, or the error of the edit, on the last row. It
 keeps within the rows of the table."
 [lines edit]
 (let [{:keys [top texts status-row status]} (dropdown-layout lines edit)
   blank (blank-description lines)]
  (-> (reduce (fn [ls [k text]]
     (update ls
      (+ top k)
      put-cell
      description-column
      description-width
      text))
    blank
    (map-indexed vector texts))
   (update status-row put-cell description-column description-width status))))

(defn dropdown-marks
 "The swatches of a colour dropdown: `[[row column [r g b]] ...]`, one blank cell in the
 colour of each name shown, all in the same column. `swatch` gives the colour of a name, or
 nil for none."
 [lines {:keys [matches], :as edit} swatch]
 (let [{:keys [top from items]} (dropdown-layout lines edit)]
  (vec (for [k (range items)
     :let [rgb (swatch (nth matches (+ from k)))]
     :when rgb]
    [(+ top k) (+ description-column swatch-offset) rgb]))))

;; --- editing a value

(defn parse-value
 "What the text `text` means as a value of `kind` (`:int` or `:float`) under the limits
 `limits` (`{:above 0, :at-most 1, ...}`): `{:value v}`, or `{:error message}` (at most 18
 characters, the width of the value cell) when it is not a number of that kind or breaks a
 limit."
 [kind text limits]
 (let [t (str/trim text)
   parsed (case kind
    :int (when (re-matches #"[+-]?\d+" t) (parse-long t))
    :float (when (re-matches #"[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?" t)
     (parse-double t)))
   broken (when (some? parsed)
    (first (for [[k bad? words] [[:above #(<= %1 %2) "above"]
        [:below #(>= %1 %2) "below"]
        [:at-least < "at least"]
        [:at-most > "at most"]]
       :let [bound (get limits k)]
       :when (and (some? bound) (bad? parsed bound))]
      (let [full (str "must be " words " " bound)]
       (if (<= (count full) 18) full (str words " " bound))))))]
  (cond (nil? parsed) {:error
    (if (= kind :int) "not a whole number" "not a number")}
   (and (= kind :float) (not (Double/isFinite (double parsed))))
   {:error "not a number"}
   broken {:error broken}
   :else {:value parsed})))

(defn initial-state
 "The state of a sheet that is just opened: page 0, no drafts, nothing being edited.
 `entries` maps a setting name to `{:saved v :default d :type t :limits l :choices c
 :notice n}`, `catalog` is a function of a setting name and a kind (`:colour`, `:font`)
 that gives the names to pick from, `swatch` (optional) a function of a colour name that
 gives its `[r g b]`, for the swatch beside the name, and `relations` (optional) the rules
 that tie settings together, which a value must keep."
 ([entries catalog] (initial-state entries catalog (constantly nil) []))
 ([entries catalog swatch] (initial-state entries catalog swatch []))
 ([entries catalog swatch relations]
  {:i 0,
   :entries entries,
   :catalog catalog,
   :swatch swatch,
   :relations relations,
   :drafts {},
   :edit nil}))

(defn ^:private effective
 "The value of `setting` in `state`: its draft, else its saved value."
 [{:keys [entries drafts]} setting]
 (get drafts setting (get-in entries [setting :saved])))

(defn ^:private typed-cell
 "What a value cell shows of the text `buffer` being typed: its end, with a cursor."
 [buffer]
 (str (if (> (count buffer) max-buffer)
   (str "…" (subs buffer (- (count buffer) (dec max-buffer))))
   buffer)
  "_"))

(defn shown-values
 "What `with-values` takes for `state`: every setting's value, a `:draft?` on those with a
 draft, the tabs of a choice setting, and the text being typed (with a cursor) on the one
 being edited."
 [{:keys [entries drafts edit], :as state}]
 (into {}
  (for [[setting {:keys [choices], kind :type}] entries
    :let [editing? (= setting (:setting edit))
     value (effective state setting)]]
   [setting
    (cond-> {:value value, :draft? (contains? drafts setting)}
     (= kind :set) (assoc :text
      (if editing?
       (tabs-text choices (:selected edit) (:focus edit))
       (tabs-text choices (set value) nil)))
     (and editing? (#{:int :float :colour :font} kind))
     (assoc :text (typed-cell (:buffer edit))))])))

(defn ^:private set-draft
 "`state` with `v` the draft of `setting`, or no draft if `v` is the saved value."
 [state setting v]
 (if (= v (get-in state [:entries setting :saved]))
  (update state :drafts dissoc setting)
  (assoc-in state [:drafts setting] v)))

(defn ^:private printable?
 "Whether `input` is a key that types a character."
 [input]
 (and (char? input) (>= (int input) 32) (not= (int input) 127)))

(defn ^:private effective-values
 "Every setting's value on the sheet, `{setting value}`, with the draft of each."
 [{:keys [entries], :as state}]
 (into {} (for [setting (keys entries)] [setting (effective state setting)])))

(defn ^:private finish
 "`state` with `v` the draft of `setting` and nothing being edited, and the notice of the
 setting gone. If `v` breaks a rule that ties `setting` to another, the edit stays open
 with the rule's short message as its error."
 [state setting v]
 (let [candidate (assoc (effective-values state) setting v)
   broken (filter #(contains? #{(:setting (:relation %)) (:of (:relation %))}
     setting)
    (validate/check-relations (:relations state) candidate))]
  (if (seq broken)
   {:state (assoc-in state
     [:edit :error]
     (validate/short-reason (:relation (first broken)) setting))}
   {:state (-> state
     (set-draft setting v)
     (update-in [:entries setting] dissoc :notice)
     (assoc :edit nil))})))

(defn ^:private cancel-key?
 "Whether `input` abandons an edit: Escape, or the terminal going away."
 [input]
 (or (= input KeyType/Escape) (= input KeyType/EOF)))

(defn ^:private number-step
 "One key `input` while the number `setting` is being typed."
 [state setting input]
 (let [{:keys [buffer]} (:edit state)
   {limits :limits, kind :type} (get-in state [:entries setting])]
  (cond
   (= input KeyType/Enter)
   (let [{:keys [value error]} (parse-value kind buffer limits)]
    (if error
     {:state (assoc-in state [:edit :error] error)}
     (finish state setting value)))

   (cancel-key? input) {:state (assoc state :edit nil)}

   (= input KeyType/Backspace)
   {:state (update state
     :edit
     #(assoc %
      :buffer (subs buffer 0 (max 0 (dec (count buffer))))
      :error nil))}

   (and (printable? input) (< (count buffer) max-buffer) (not= input \space))
   {:state (update state :edit #(assoc % :buffer (str buffer input) :error nil))}

   :else {:state state})))

(defn ^:private refilter
 "The edit `edit` with the text `buffer`, the names it narrows the list to, and the first
 of them highlighted."
 [edit buffer]
 (assoc edit
  :buffer buffer
  :matches (picker/narrow (:names edit) buffer)
  :index 0
  :error nil))

(defn ^:private pick
 "What Enter takes in the text edit `edit` of kind `kind`: `{:value v}` or `{:error
 message}`. The highlighted name, else a colour typed as `#rrggbb`, else, on a machine
 with no list of fonts, the text as it is."
 [kind {:keys [buffer matches names index]}]
 (cond (and (= kind :colour) (re-matches #"#[0-9a-f]{6}" buffer)) {:value buffer}
  (seq matches) (let [chosen (nth matches index)]
   {:value (if (= kind :colour) (keyword chosen) chosen)})
  (and (= kind :font) (empty? names) (not (str/blank? buffer))) {:value buffer}
  :else {:error
   (if (= kind :colour) "not a known colour" "not a known font")}))

(defn ^:private text-step
 "One key `input` while a colour or a font `setting` is being picked."
 [state setting kind input]
 (let [{:keys [buffer matches index], :as edit} (:edit state)
   edit! (fn [e] {:state (assoc state :edit e)})]
  (cond
   (= input KeyType/Enter)
   (let [{:keys [value error]} (pick kind edit)]
    (if error (edit! (assoc edit :error error)) (finish state setting value)))

   (cancel-key? input) {:state (assoc state :edit nil)}

   (and (#{KeyType/ArrowDown KeyType/ArrowUp} input) (seq matches))
   (edit! (assoc edit
     :error nil
     :index (mod ((if (= input KeyType/ArrowDown) inc dec) index)
      (count matches))))

   (and (= input KeyType/Tab) (seq matches))
   (edit! (refilter edit (nth matches index)))

   (= input KeyType/Backspace)
   (edit! (refilter edit (subs buffer 0 (max 0 (dec (count buffer))))))

   (and (printable? input) (< (count buffer) max-text))
   (edit! (refilter edit (str buffer input)))

   :else {:state state})))

(defn ^:private set-step
 "One key `input` while the tabs of the choice `setting` are being set: Enter turns the
 tab in focus on or off, Tab and the arrows move, Escape is done (the choices on become a
 draft), which needs one choice on."
 [state setting input]
 (let [{:keys [options selected focus], :as edit} (:edit state)
   n (count options)
   edit! (fn [e] {:state (assoc state :edit (assoc e :error nil))})]
  (cond
   (= input KeyType/Enter)
   (let [option (nth options focus)]
    (edit! (assoc edit
      :selected
      (if (contains? selected option)
       (disj selected option)
       (conj selected option)))))

   (cancel-key? input)
   (if (empty? selected)
    {:state (assoc-in state [:edit :error] "pick one or more")}
    (finish state setting (filterv selected options)))

   (= input KeyType/ArrowRight) (edit!
    (assoc edit :focus (min (dec n) (inc focus))))
   (= input KeyType/ArrowLeft) (edit! (assoc edit :focus (max 0 (dec focus))))
   (= input KeyType/Tab) (edit! (assoc edit :focus (mod (inc focus) n)))

   :else {:state state})))

(defn ^:private raw-text
 "The text of the value `v` as typed into a cell."
 [v]
 (if (keyword? v) (name v) (str v)))

;; --- editing a tuple

(defn ^:private part-kinds
 "The kind of each part of a tuple whose shape is `shape` (a vector, or a map), in order."
 [shape]
 (if (map? shape) (vec (vals shape)) (vec shape)))

(defn ^:private with-matches
 "The tuple edit `edit` with the colours its colour part narrows to, when that part has the
 focus (none otherwise). A colour part that has not been typed into yet lists every colour
 with the one it has highlighted, as the dropdown of a colour setting does; once typed into,
 it lists the colours that match what was typed, the first highlighted."
 [{:keys [kinds focus names buffers fresh], :as edit}]
 (let [colour? (= :colour (nth kinds focus))
   untouched? (contains? fresh focus)]
  (assoc edit
   :matches (cond (not colour?) []
    untouched? (vec names)
    :else (picker/narrow names (nth buffers focus)))
   :index (if (and colour? untouched?)
    (picker/index-of-name names (nth buffers focus))
    0))))

(defn ^:private tuple-edit
 "The edit that opens the tuple setting `setting` for editing: one text for each part,
 beginning with the parts it has now, the first part in focus."
 [{:keys [entries catalog], :as state} setting]
 (let [{:keys [shape parts]} (get entries setting)
   current (effective state setting)
   ks (when (map? shape) (vec (keys shape)))
   values (if ks (mapv #(get current %) ks) (vec current))
   kinds (part-kinds shape)]
  (with-matches {:setting setting,
    :kind :tuple,
    :kinds kinds,
    :keys ks,
    :labels parts,
    :buffers (mapv raw-text values),
    :focus 0,
    :names (when (some #{:colour} kinds) (catalog setting :colour)),
    :fresh (set (keep-indexed #(when (= :colour %2) %1) kinds)),
    :error nil})))

(defn ^:private part-value
 "What the text `text` of a part of kind `kind` means: `{:value v}` or `{:error message}`.
 A colour is a name of the list or `#rrggbb`; when the colour part is the one in focus,
 what is highlighted in its list (`highlight`, a name or nil) stands for a text that is no
 colour yet."
 [kind text names highlight]
 (case kind
  (:int :float) (parse-value kind text {})
  :colour (let [t (str/trim text)
    exact (first (filter #(= (str/lower-case %) (str/lower-case t))
      names))]
   (cond (re-matches #"#[0-9a-fA-F]{6}" t) {:value (str/lower-case t)}
    exact {:value (keyword exact)}
    highlight {:value (keyword highlight)}
    :else {:error "not a known colour"}))
  {:error "a part of this kind cannot be edited"}))

(defn ^:private tuple-commit
 "Enter in a tuple edit: every part is read, the tuple checked (`validate/check`, then the
 rules that tie it to other settings), and made a draft, or the edit stays open with what is
 wrong with it and the first part at fault in focus."
 [state setting]
 (let [{:keys [kinds labels buffers names matches index focus], ks :keys} (:edit
    state)
   entry (get-in state [:entries setting])
   parsed (vec (map-indexed (fn [k kind]
      (part-value kind
       (nth buffers k)
       names
       (when (= k focus)
        (get matches index))))
     kinds))
   bad (first (keep-indexed (fn [k r] (when (:error r) [k (:error r)])) parsed))
   fail (fn [k message]
    {:state (update state
      :edit
      #(with-matches
       (assoc %
        :focus k
        :error (str (nth labels k) ": " message))))})]
  (if bad
   (fail (first bad) (second bad))
   (let [values (mapv :value parsed)
     candidate (if ks (zipmap ks values) values)
     {:keys [error value]} (validate/check entry candidate)]
    (if error
     {:state (assoc-in state [:edit :error] error)}
     (finish state setting value))))))

(defn ^:private tuple-step
 "One key `input` while the tuple `setting` is being edited: up and down move between the
 parts, text is typed into the part in focus, Enter accepts the tuple, Escape gives up; and
 in a colour part left and right pick among the colours that match and Tab takes the one
 picked into the text. The first key typed into a colour part replaces the name it had."
 [state setting input]
 (let [{:keys [kinds focus buffers matches index fresh], :as edit} (:edit state)
   n (count kinds)
   colour? (= :colour (nth kinds focus))
   untouched? (contains? fresh focus)
   buffer (if untouched? "" (nth buffers focus))
   change (fn [e]
    {:state (assoc state :edit (with-matches (assoc e :error nil)))})
   set-buffer #(change (-> edit
     (assoc-in [:buffers focus] %)
     (update :fresh disj focus)))
   focus-on (fn [to] (change (assoc edit :focus (max 0 (min (dec n) to)))))]
  (cond
   (cancel-key? input) {:state (assoc state :edit nil)}
   (= input KeyType/Enter) (tuple-commit state setting)
   (= input KeyType/ArrowDown) (focus-on (inc focus))
   (= input KeyType/ArrowUp) (focus-on (dec focus))
   (= input KeyType/Tab)
   (if (and colour? (seq matches))
    (set-buffer (nth matches index))
    (focus-on (inc focus)))
   (and (#{KeyType/ArrowLeft KeyType/ArrowRight} input) colour? (seq matches))
   {:state (assoc state
     :edit
     (assoc edit
      :error nil
      :index (mod ((if (= input KeyType/ArrowRight) inc dec)
        index)
       (count matches))))}
   (= input KeyType/Backspace) (set-buffer
    (subs buffer 0 (max 0 (dec (count buffer)))))
   (and (printable? input)
    (not= input \space)
    (< (count buffer) (if colour? max-text max-buffer)))
   (set-buffer (str buffer input))
   :else {:state state})))

(defn ^:private tuple-layout
 "What the form of the tuple edit `edit` writes in the description column of the page
 `lines`: `{:top first row :texts [row text ...] :names [[row-offset name] ...]}`. A row for
 each part (the one in focus marked `>`, with a cursor), the keys, the error if there is
 one, and, when the colour part is in focus, the colours that match with the one picked
 marked."
 [lines {:keys [labels buffers focus kinds matches index error]}]
 (let [[top bottom] (column-rows lines)
   width (apply max (map count labels))
   room (- 29 3 width 2)
   part-text (fn [k label]
    (str " "
     (if (= k focus) "> " "  ")
     (format (str "%-" width "s") label)
     ": "
     (if (= k focus)
      (picker/typed-text {:buffer (nth buffers k)} room)
      (cut (nth buffers k) room))))
   head (vec (concat (map-indexed part-text labels)
     [""
      " ↑↓ part   ⏎ ok   esc cancel"
      (if error (str " " error) "")]))
   colour? (= :colour (nth kinds focus))
   hint (when colour? " ←→ pick  Tab take")
   used (+ (count head) (if hint 1 0))
   room-rows (max 0 (- (inc (- bottom top)) used))
   items (min room-rows (count matches))
   from (max 0 (min (- index (quot items 2)) (- (count matches) items)))]
  {:top top,
   :texts (vec (concat head
     (when hint [hint])
     (for [k (range items)
       :let [at (+ from k)]]
      (str " "
       (if (= at index) "> " "  ")
       (cut (nth matches at) name-room))))),
   :names (vec (for [k (range items)]
     [(+ (count head) (if hint 1 0) k) (nth matches (+ from k))]))}))

(defn with-tuple-form
 "The lines of a page with the form of the tuple edit `edit` written in the description
 column, which is made blank for it."
 [lines edit]
 (let [{:keys [top texts]} (tuple-layout lines edit)]
  (reduce (fn [ls [k text]]
    (update ls (+ top k) put-cell description-column description-width text))
   (blank-description lines)
   (map-indexed vector texts))))

(defn tuple-marks
 "The swatches of the colours the colour part of the tuple edit `edit` narrows to:
 `[[row column [r g b]] ...]`, all in the same column. `swatch` gives the colour of a name."
 [lines edit swatch]
 (let [{:keys [top names]} (tuple-layout lines edit)]
  (vec (for [[offset n] names
     :let [rgb (swatch n)]
     :when rgb]
    [(+ top offset) (+ description-column swatch-offset) rgb]))))

(defn ^:private start-edit
 "`state` with the setting `setting` opened for editing, if its kind can be edited."
 [{:keys [entries catalog], :as state} setting]
 (let [{kind :type, :keys [choices]} (get entries setting)
   current (effective state setting)]
  (case kind
   :bool {:state (set-draft state setting (not current))}
   (:int :float) (let [t (raw-text current)]
    {:state (assoc state
      :edit
      {:setting setting,
       :buffer (subs t 0 (min (count t) max-buffer))})})
   (:colour :font)
   (let [names (catalog setting kind)]
    {:state (assoc state
      :edit
      {:setting setting,
       :buffer "",
       :names names,
       :matches names,
       :index (picker/index-of-name names (raw-text current))})})
   :tuple (if (:parts (get entries setting))
    {:state (assoc state :edit (tuple-edit state setting))}
    {:state state})
   :set {:state (assoc state
     :edit
     {:setting setting,
      :options choices,
      :selected (set current),
      :focus 0})}
   {:state state})))

(defn ^:private normal-step
 "One key `input` on the page `i` of `sheet` when nothing is being edited."
 [sheet {:keys [i entries drafts], :as state} input]
 (let [lines (nth (:pages sheet) i)
   setting (cursor-setting lines)
   target (move sheet i input)]
  (cond
   (keyword? target) target

   (not= target i)
   {:state (assoc state :i target)}

   (= input KeyType/Enter) (start-edit state setting)

   (= input :ctrl-s)
   {:state (-> state
     (assoc :drafts {})
     (update :entries
      (fn [es]
       (reduce-kv #(update %1 %2 assoc :saved %3 :notice nil)
        es
        drafts)))),
    :save (vec drafts)}

   (= input :ctrl-u) {:state (update state :drafts dissoc setting)}

   (= input :ctrl-r)
   {:state (reduce (fn [st s]
      (set-draft (update st :drafts dissoc s)
       s
       (get-in entries [s :default])))
     state
     (page-settings lines))}

   :else {:state state})))

(defn step
 "What `input` does in `state` on `sheet`: `:back` or `:quit`, or `{:state new-state}`,
 with `:save [[setting value] ...]` when drafts were saved (the caller writes them)."
 [sheet state input]
 (if-let [{:keys [setting]} (:edit state)]
  (let [kind (get-in state [:entries setting :type])]
   (case kind
    (:int :float) (number-step state setting input)
    (:colour :font) (text-step state setting kind input)
    :set (set-step state setting input)
    :tuple (tuple-step state setting input)))
  (normal-step sheet state input)))

(defn page-lines
 "The lines of page `i` of `sheet` as `state` shows them: the values, and over them the
 dropdown of a colour or font being picked, the form of a tuple being edited, or the error
 of a number or a choice."
 [sheet {:keys [i edit entries], :as state}]
 (let [lines (with-values (nth (:pages sheet) i) (shown-values state))
   kind (get-in entries [(:setting edit) :type])]
  (cond (nil? edit) (if-let [notice (get-in entries
      [(cursor-setting lines) :notice])]
    (with-error lines (cursor-setting lines) notice)
    lines)
   (#{:colour :font} kind) (with-dropdown lines edit)
   (= kind :tuple) (with-tuple-form lines edit)
   (= kind :set) (with-error lines
    (:setting edit)
    (or (:error edit) "⏎ toggle  esc done"))
   (:error edit) (with-error lines (:setting edit) (:error edit))
   :else lines)))

(defn page-marks
 "The swatches on the page of `state`: those of the colour dropdown, or of the colours the
 colour part of a tuple being edited narrows to, when there are any."
 [sheet {:keys [i edit entries swatch]}]
 (let [kind (get-in entries [(:setting edit) :type])
   lines (nth (:pages sheet) i)]
  (cond (= :colour kind) (dropdown-marks lines edit swatch)
   (= :tuple kind) (tuple-marks lines edit swatch)
   :else [])))

(defn page-panel
 "The white area behind the swatches on the page of `state`: `[[row column width] ...]`,
 the description column over the rows of the table, while a colour or a tuple with a
 colour part is being edited; else nil."
 [sheet {:keys [i edit entries]}]
 (let [kind (get-in entries [(:setting edit) :type])]
  (when (or (= :colour kind) (and (= :tuple kind) (some #{:colour} (:kinds edit))))
   (let [[top bottom] (column-rows (nth (:pages sheet) i))]
    (vec (for [row (range top (inc bottom))]
      [row description-column description-width]))))))

(defn show!
 "Shows `sheet` on `screen` from its first page, with the solid colour `background`, and
 handles the keys until one leaves it; returns :back or :quit. The map `opts` has
 `:entries` (a setting name to `{:saved v :default d :type t :limits l :choices c :notice
 n}`), `:catalog` (the names to pick from for a setting and a kind), `:swatch` (the colour
 of a colour name), `:relations` (the rules that tie settings together) and `:save!`, a
 function of a setting name and a value, called for each draft a ctrl-s saves."
 [^TerminalScreen screen sheet ^TextColor background
  {:keys [entries catalog swatch relations save!]}]
 (loop [st (initial-state entries catalog swatch relations)]
  (state/draw-page screen
   {:asset (page-lines sheet st),
    :marks (page-marks sheet st),
    :panel (page-panel sheet st)}
   background)
  (let [result (step sheet st (state/read-input screen))]
   (if (keyword? result)
    result
    (do (run! (fn [[setting v]] (save! setting v)) (:save result))
     (recur (:state result)))))))
