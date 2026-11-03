;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The custom solutes being edited, with what has not been saved: pure functions of a
;; state, so none of it needs a terminal. It mirrors `baysol.tui.solutes`: the state is
;; `{:rows [row ...]}` and a row
;; `{:saved entry-or-nil, :draft entry-or-nil, :removed? bool}`:
;;
;;   saved     what `custom-solutes.edn` has (nil for a row added since the last save)
;;   draft     what the row was edited to (nil when it stands at what was saved)
;;   removed?  the row is to go at the next save (shown with `-`); until then `undo` brings
;;             it back
;;
;; A row shows `*` while it is new or has a draft, `-` while it is to be removed. An entry
;; is a map of one of two kinds (see `baysol.tui.custom-store`): a non-biological solute
;; `{:kind :nonbiological :name :formula :z :pmv :sigma}` or a polymer, a generic additive
;; chain of 1 to 4 kinds of repeat unit,
;; `{:kind :polymer :name :units [{:label :formula :z :slope :sigma} ...] :z-ends :pmv-ends
;; :sigma-ends}`: PMV(n) = pmv-ends + sum(slope_i n_i), Z(n) = z-ends + sum(z_i n_i). The
;; end groups have no default: the user types them.

(ns baysol.tui.custom
 (:require [baysol.tui.draft :as draft]
  [baysol.tui.formula :as formula]
  [baysol.tui.text :as txt]
  [clojure.string :as str]))

(def polymer-unknown-rel-unc
 "The relative uncertainty of the PMV of a polymer unit whose ± is blank: 2 % of the PMV.
 This is `POLYMER_UNKNOWN_REL_UNC` of `Polymers.jl` (BulkElectronDensity), where the blank
 is resolved; nothing is computed here, the screen only says `(2%)`."
 0.02)

(def max-units
 "The most kinds of repeat unit a polymer has (`CUSTOM_POLYMER_MAX_UNITS` of Julia)."
 4)

(def default-labels
 "The labels offered for the units, in order."
 ["A" "B" "C" "D"])

(defn default-label
 "The label offered for unit `i` (0-based)."
 [i]
 (get default-labels i ""))

(def blank-nonbiological
 "A non-biological entry with nothing filled in."
 {:kind :nonbiological, :name "", :formula "", :z nil, :pmv nil, :sigma nil})

(def blank-unit
 "A repeat unit with nothing filled in."
 {:label "", :formula "", :z nil, :slope nil, :sigma nil})

(def blank-polymer
 "A polymer entry with nothing filled in: one blank unit, and no end groups (they have no
 default)."
 {:kind :polymer,
  :name "",
  :units [blank-unit],
  :z-ends nil,
  :pmv-ends nil,
  :sigma-ends nil})

(defn initial
 "The state of the saved entries `entries`, nothing edited."
 [entries]
 (draft/initial entries))

(defn value
 "The entry of `row` as it stands now: its draft, else what was saved."
 [row]
 (draft/value row))

(defn mark
 "The mark of `row`: `\\-` if it is to be removed, `\\*` if it is new or edited, else nil."
 [row]
 (draft/mark row))

(defn dirty?
 "Whether anything of `state` is not saved."
 [state]
 (draft/dirty? state))

(defn add-row
 "`state` with a new blank row of the kind `kind` (`:nonbiological` or `:polymer`) at the
 end."
 [state kind]
 (draft/add-draft state (if (= kind :polymer) blank-polymer blank-nonbiological)))

(defn get-field
 "The field `field` of the entry `e`: a keyword (`:name`, `:z-ends`, ...) or `[:unit i k]`
 for the field `k` (`:label`, `:formula`, `:z`, `:slope` or `:sigma`) of unit `i`."
 [e field]
 (if (vector? field)
  (get-in e [:units (second field) (nth field 2)])
  (get e field)))

(defn ^:private assoc-field
 [e field v]
 (if (vector? field)
  (assoc-in e [:units (second field) (nth field 2)] v)
  (assoc e field v)))

(defn set-field
 "`state` with the field `field` of row `i` set to `v`: a keyword (`:name`, `:formula`,
 `:z`, `:pmv`, `:sigma`, `:z-ends`, `:pmv-ends`, `:sigma-ends`) or `[:unit j k]`, the field
 `k` of unit `j` of a polymer. A row set back to what was saved has no draft."
 [state i field v]
 (draft/set-draft state i (assoc-field (value (get-in state [:rows i])) field v)))

(defn set-entry
 "`state` with the whole entry of row `i` set to `entry` (what a form page returns). A row
 set back to what was saved has no draft."
 [state i entry]
 (draft/set-draft state i entry))

(defn add-unit
 "`state` with a blank unit added at the end of the polymer in row `i`; unchanged when it
 has `max-units` already."
 [state i]
 (let [e (value (get-in state [:rows i]))]
  (if (< (count (:units e)) max-units)
   (set-entry state i (update e :units conj blank-unit))
   state)))

(defn remove-unit
 "`state` with unit `j` of the polymer in row `i` removed; unchanged when it is the only
 one."
 [state i j]
 (let [e (value (get-in state [:rows i]))
   units (:units e)]
  (if (> (count units) 1)
   (set-entry state
    i
    (assoc e :units (into (subvec units 0 j) (subvec units (inc j)))))
   state)))

(defn remove-row
 "`state` with row `i` marked to be removed at the next save; a row that was never saved
 has nothing to confirm and goes at once."
 [state i]
 (draft/remove-row state i))

(defn undo
 "`state` with the last change of row `i` undone: a removal first, then the draft; a row
 that was never saved goes."
 [state i]
 (draft/undo state i))

;; --- the checks, each told with the field it is about

(defn ^:private z-problem
 "`[:formula \"formula unknown\"]` or `[:z \"Z must be > 0\"]` for the entry or unit `e`,
 else nil: a Z above 0, or else a formula that is understood (and so would give one), is
 needed."
 [e]
 (let [z? (and (:z e) (pos? (:z e)))
   formula? (or (str/blank? (:formula e))
    (not (:error (formula/parse-formula (:formula e)))))]
  (cond (and (not z?) (not formula?)) [:formula "formula unknown"]
   (not z?) [:z "Z must be > 0"])))

(defn ^:private negative?
 [x]
 (and (number? x) (neg? x)))

(defn ^:private unit-problem
 "`[field message]` of the first problem of unit `j`, `field` as `[:unit j k]`, or nil."
 [j u]
 (let [at (fn [[k message]] [[:unit j k] message])]
  (cond (str/blank? (:label u)) [[:unit j :label] "label needed"]
   :else (or (some-> (z-problem u)
     at)
    (when-not (number? (:slope u)) [[:unit j :slope] "slope needed"])
    (when (negative? (:sigma u))
     [[:unit j :sigma] "± not below 0"])))))

(defn ^:private label-key
 [u]
 (txt/fold (:label u)))

(defn ^:private duplicate-label
 "The index of the first unit whose label an earlier unit has (case-insensitively), or
 nil."
 [units]
 (loop [i 0
   seen #{}]
  (when (< i (count units))
   (let [k (label-key (nth units i))]
    (if (contains? seen k) i (recur (inc i) (conj seen k)))))))

(defn ^:private polymer-problem
 [e]
 (let [units (:units e)]
  (or (when (empty? units) [:units "unit needed"])
   (some identity (map-indexed unit-problem units))
   (when-let [j (duplicate-label units)] [[:unit j :label] "unit label used"])
   (when-not (number? (:z-ends e)) [:z-ends "end groups needed"])
   (when-not (number? (:pmv-ends e)) [:pmv-ends "end groups needed"])
   (when (negative? (:sigma-ends e)) [:sigma-ends "ends ± not below 0"]))))

(defn field-problem
 "The first thing missing in the entry `e`, as `[field message]`, or nil: `field` is the
 keyword (`:name`, `:formula`, `:z`, `:pmv`, `:sigma`, `:z-ends`, `:pmv-ends`,
 `:sigma-ends`, `:units`) or `[:unit j k]` that the message (22 characters at most) is
 about. See `problem` for the rules."
 [e]
 (cond (str/blank? (:name e)) [:name "name needed"]
  (= (:kind e) :polymer) (polymer-problem e)
  :else (or (z-problem e)
   (when-not (number? (:pmv e)) [:pmv "PMV needed"])
   (when (negative? (:sigma e)) [:sigma "± not below 0"]))))

(defn problem
 "What is missing in the entry `e`, as a short message (22 characters at most), or nil.
 Both kinds need a name. A non-biological solute needs a formula that is understood or a Z
 above 0, a PMV (a number, negative is fine for an ion) and a ± of 0 or more when given. A
 polymer needs, of each unit, a label, a Z or formula as above, a slope and a ± of 0 or more
 when given; labels that differ (`unit label used`, case-insensitively); the end groups
 (`end groups needed`: `:z-ends` and `:pmv-ends`, no default) and `:sigma-ends` of 0 or more
 when given. Whether the name is taken is for `problems`, which sees the other entries."
 [e]
 (second (field-problem e)))

(defn entry-problem
 "`[field message]` of the first problem of the entry `e` when it stands among the entries
 named `other-names` (`field-problem`, then a name that is built-in (`builtin?`, a predicate
 on a name, or nil) or that one of `other-names` has, case-insensitively), or nil.
 For a form
 page, which sees one entry."
 [e builtin? other-names]
 (or (field-problem e)
  (when (and builtin? (builtin? (:name e))) [:name "name is built-in"])
  (when (contains? (set (map txt/fold other-names)) (txt/fold (:name e)))
   [:name "name in use"])))

(defn problems
 "The first problem of the rows that stay at the next save: `[i message]`, or nil. A name
 that an earlier row has (case-insensitively) is told as `name in use`. With `builtin?`,
 a predicate on a name (`baysol.tui.solute-index/builtin-name?`), a name that is a
 built-in solute, polymer grade or family is told as `name is built-in`; without it
 (the default) no name is checked against the built-in ones."
 ([state] (problems state nil))
 ([state builtin?]
  (loop [rows (map-indexed vector (:rows state))
    seen #{}]
   (when-let [[[i row] & more] (seq rows)]
    (if (:removed? row)
     (recur more seen)
     (let [e (value row)
       k (txt/fold (:name e))
       p (or (problem e)
        (when (and builtin? (builtin? (:name e))) "name is built-in")
        (when (contains? seen k) "name in use"))]
      (if p [i p] (recur more (conj seen k)))))))))

(defn snapshot
 "What a buffer row stores of the stored entry `entry`, the project never reading the
 global file. A non-biological entry gives `{:kind :custom-nonbio :custom name :z :pmv
 :sigma-pmv}`; a polymer, with `counts` (one number per unit, in the order of the units,
 made doubles) `{:kind :custom-polymer :custom name :units [...] :z-ends :pmv-ends
 :sigma-ends :counts [...]}`, the units copied with just their keys. The row's own `:name`,
 `:mM` and `:sigma-mM` are for the caller to add. Throws an exception for a polymer when
 `counts` is not one number per unit."
 ([entry] (snapshot entry nil))
 ([entry counts]
  (if (= (:kind entry) :polymer)
   (do (when-not (and (= (count counts) (count (:units entry)))
      (every? number? counts))
     (throw (ex-info "one count per unit needed" {:counts counts})))
    {:kind :custom-polymer,
     :custom (:name entry),
     :units (mapv #(select-keys % [:label :formula :z :slope :sigma])
      (:units entry)),
     :z-ends (:z-ends entry),
     :pmv-ends (:pmv-ends entry),
     :sigma-ends (:sigma-ends entry),
     :counts (mapv double counts)})
   {:kind :custom-nonbio,
    :custom (:name entry),
    :z (:z entry),
    :pmv (:pmv entry),
    :sigma-pmv (:sigma entry)})))

(defn to-save
 "The entries `custom-solutes.edn` gets at the next save, a vector: the rows not marked to
 go."
 [state]
 (draft/to-save state))

(defn commit
 "`state` after a save: the removed rows gone, every other row standing at what it is."
 [state]
 (draft/commit state))

;; --- the typed fields (shared by the table and the form pages)

(def max-label
 "The most characters a unit label has."
 8)

(defn format-number
 "`x` as plain decimal text with no exponent and no trailing zeros; \"\" for nil."
 [x]
 (txt/format-number x))

(defn parse-field
 "What the text `text` typed for `field` comes to: `{:value v}` or `{:error \"short
 message\"}`. `field` is a keyword (`:name`, `:label`, `:formula`, `:z`, `:z-ends`, `:pmv`,
 `:slope`, `:pmv-ends`, `:sigma`, `:sigma-ends`). The name must not be blank; a label is
 one word of at most 8 characters; the formula is taken as typed (a polymer's unit without
 a surrounding `( )n`); Z is a whole number above 0 (of the ends, 0 or more); a PMV or slope
 a number (negative is fine); a ± blank (nil) or 0 or more."
 [field text]
 (let [t (str/trim text)
   number (txt/number-text t)]
  (case field
   :name (if (str/blank? t) {:error "name needed"} {:value t})
   :label (cond (str/blank? t) {:error "label needed"}
    (re-find #"\s" t) {:error "one word, please"}
    (> (.codePointCount ^String t 0 (.length ^String t)) max-label)
    {:error "at most 8 characters"}
    :else {:value t})
   :formula {:value t}
   :z-ends (if (re-matches #"\d{1,9}" t)
    {:value (Long/parseLong t)}
    {:error "a whole number, please"})
   :z (cond (not (re-matches #"\d{1,9}" t)) {:error "a whole number, please"}
    (zero? (Long/parseLong t)) {:error "Z must be > 0"}
    :else {:value (Long/parseLong t)})
   (:sigma :sigma-ends) (cond (str/blank? t) {:value nil}
    (nil? number) {:error "a number, please"}
    (neg? number) {:error "not below 0"}
    :else {:value number})
   (if (nil? number)
    {:error "a number, please"}
    {:value number}))))

(defn parse-cell
 "`parse-field` for a cell of a form page, where a blank text is allowed and clears the
 cell (the name, label and formula to \"\", the numbers to nil): what is missing is told
 when the form is accepted (`field-problem`), not as the cell is left. `field` as for
 `parse-field`."
 [field text]
 (if (str/blank? text)
  {:value (if (#{:name :label :formula} field) "" nil)}
  (parse-field field text)))

(defn format-rounded
 "`x` rounded to 2 decimals as `format-number` shows it (\"\" for nil)."
 [x]
 (when x (format-number (/ (Math/round (* 100.0 (double x))) 100.0))))

(defn take-formula
 "The formula text `text` taken into `m`, an entry (a non-biological solute) or one unit of
 a polymer (`unit?` true: a surrounding `( )n` is dropped and no charge is allowed):
 `{:value m' :note reason-or-nil}`. The formula is set and, when it is not the one `m`
 had, Z is what it comes to, or nil when the formula is not understood (the reason is the
 note, unless the formula is blank); a formula that did not change keeps its Z, so a Z
 typed by hand stays. A polymer unit with no label gets `offered`, when that is given."
 ([m text unit?] (take-formula m text unit? nil))
 ([m text unit? offered]
  (let [parsed (if unit? (formula/parse-unit text) (formula/parse-formula text))
    shown (if unit? (formula/strip-unit text) (str/trim text))
    same? (= shown (:formula m))
    z (cond same? (:z m)
     (:error parsed) nil
     :else (:z parsed))
    m (assoc m :formula shown :z z)
    m (if (and unit? offered (not (str/blank? shown)) (str/blank? (:label m)))
     (assoc m :label offered)
     m)]
   {:value m,
    :note (when (and (not same?) (:error parsed) (not (str/blank? shown)))
     (:error parsed))})))

;; --- the units of a form page

(defn unit-blank?
 "Whether every cell of the unit `u` is blank (a form row nobody filled)."
 [u]
 (and (str/blank? (:label u))
  (str/blank? (:formula u))
  (nil? (:z u))
  (nil? (:slope u))
  (nil? (:sigma u))))

(defn used-rows
 "The indices of the rows of the unit table `units` that are used: row 0 always, then every
 row that has anything in it (an all-blank row is ignored)."
 [units]
 (vec (cons 0 (remove #(unit-blank? (nth units %)) (range 1 (count units))))))

(defn compact-units
 "The units a form page's table `units` makes: the used rows (`used-rows`) in order, a
 blank label being the one offered for its row (`default-label` of the row's place in the
 table)."
 [units]
 (mapv (fn [i]
   (let [u (nth units i)]
    (cond-> u (str/blank? (:label u)) (assoc :label (default-label i)))))
  (used-rows units)))

;; --- a chain of units (the preview of the polymer form)

(defn chain-values
 "What a chain of the units of `entry` (a polymer entry: each unit's `:z`, `:slope`,
 `:sigma`, and `:z-ends`, `:pmv-ends`, `:sigma-ends`) with `counts` (one number of repeat
 units per unit) comes to: `{:z Z :pmv ϕ° :sigma σ}`, all numbers in the entry given.
 This is
 the rule of `_ρₑ_i(::CustomPolymer)` in `src/BulkElectronDensity/CalcDensity.jl`:
 ϕ° = pmv-ends + Σ slope·n, Z = round(z-ends + Σ Z_unit·n) (halves to even, as Julia's
 `round`), σ = sqrt(Σ term² + σ_ends²) with term = σ_unit·n, or 2 % of |slope·n| for a unit
 with no σ; when no σ is stated at all (neither of the ends nor of a unit) σ is 2 % of
 |ϕ°|. Nothing is checked here (see `field-problem`).

 # Returns
 A map with `:z` (a long), `:pmv` and `:sigma` (doubles).

 # Exceptions
 None (a nil number in the entry throws a NullPointerException)."
 [entry counts]
 (let [units (:units entry)
   pmv (+ (double (:pmv-ends entry))
    (reduce + (map (fn [u n] (* (double (:slope u)) n)) units counts)))
   z (long (Math/rint
     (+ (double (:z-ends entry))
      (reduce + (map (fn [u n] (* (double (:z u)) n)) units counts)))))
   s-ends (:sigma-ends entry)
   unstated? (and (nil? s-ends) (every? (comp nil? :sigma) units))
   terms (map (fn [u n]
     (if-let [s (:sigma u)]
      (* (double s) n)
      (* polymer-unknown-rel-unc (abs (* (double (:slope u)) n)))))
    units
    counts)
   sigma (if unstated?
    (* polymer-unknown-rel-unc (abs pmv))
    (Math/sqrt (+ (reduce + (map #(* % %) terms))
      (let [e (double (or s-ends 0.0))] (* e e)))))]
  {:z z, :pmv pmv, :sigma sigma}))
