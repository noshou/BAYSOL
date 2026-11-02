;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The checks on the value of a setting, which no value may escape: its type, the limits
;; and choices the harvest copied from the Params.jl files, a colour that exists, the shape
;; of a tuple, and the rules that tie settings together (`setting_relations.edn`). The
;; Julia side makes the same checks on the same data when it reads the settings
;; (`BAYSOL.load_settings`), so what the terminal interface keeps is what the code accepts.
;; A check gives `{:value v}`, the value in the type the setting has, or `{:error message}`.

(ns baysol.tui.validate
 (:require [baysol.tui.catalog :as catalog]
  [clojure.string :as str]))

(def ^:private max-font-name 100)

(defn ^:private whole?
 "Whether `x` is a whole number (a `Long`, which is what the EDN reader gives)."
 [x]
 (instance? Long x))

(defn ^:private finite-number?
 "Whether `x` is a finite number: a `Long` or a `Double` that is not infinite or NaN."
 [x]
 (or (whole? x) (and (instance? Double x) (Double/isFinite ^double x))))

(def ^:private colour-names (delay (set (catalog/names "" :colour))))

(defn colour?
 "Whether `x` is a colour a figure can use: a keyword with the name of a colour of the
 list, or a string `#rrggbb`."
 [x]
 (cond (keyword? x) (and (nil? (namespace x)) (contains? @colour-names (name x)))
  (string? x) (boolean (re-matches #"#[0-9a-fA-F]{6}" x))
  :else false))

(defn ^:private limit-error
 "What is wrong with the number `v` under the limits `limits` (`{:above 0, :at-most 1}`),
 or nil if it keeps them."
 [v limits]
 (first (for [[k words ok?] [[:above "above" >] [:below "below" <]
     [:at-least "at least" >=]
     [:at-most "at most" <=]]
    :let [bound (get limits k)]
    :when (and (some? bound) (not (ok? v bound)))]
   (str "must be " words " " bound))))

(defn ^:private part
 "The part `x` of a tuple shaped like the default part `d`, or `{:error message}`."
 [x d]
 (cond (whole? d)
  (if (whole? x) {:value x} {:error "a part must be a whole number"})
  (number? d) (if (finite-number? x)
   {:value (double x)}
   {:error "a part must be a finite number"})
  (keyword? d) (if (colour? x) {:value x} {:error "a part must be a colour"})
  :else {:error "a part of this kind cannot be checked"}))

(defn ^:private parts
 "The parts of `xs` checked against the parts of `ds` (maps or sequences of the same
 length), each shaped like its default: `{:value xs'}` or the first error."
 [xs ds]
 (let [checked (map #(part %1 %2) xs ds)]
  (or (first (filter :error checked)) {:value (mapv :value checked)})))

(defn ^:private tuple
 "The tuple value `v` shaped like the default `default`: a vector of the same length, or a
 map with the same keys."
 [v default]
 (cond (map? default)
  (if (and (map? v) (= (set (keys v)) (set (keys default))))
   (let [ks (keys default)
     r (parts (map #(get v %) ks) (map #(get default %) ks))]
    (if (:error r) r {:value (zipmap ks (:value r))}))
   {:error (str "must have exactly "
     (str/join ", " (map name (keys default))))})
  (and (sequential? v) (= (count v) (count default))) (parts v default)
  :else {:error (str "must have " (count default) " parts")}))

(defn shape-of
 "The shape of the tuple value `v`: the kind of each part (`:int`, `:float`, `:colour` or
 `:other`), in a vector, or in a map for a map. The harvest records the shape of each
 tuple default from the Julia constant, and a default read back must have it."
 [v]
 (let [kind (fn [x]
    (cond (whole? x) :int
     (number? x) :float
     (keyword? x) :colour
     :else :other))]
  (if (map? v) (into {} (for [[k x] v] [k (kind x)])) (mapv kind v))))

(defn check
 "Checks the value `v` of the setting described by `entry` (`{:type :limits :choices
 :default}`): `{:value v'}`, with `v'` in the type of the setting (a whole number in a
 number setting that is a float becomes a float, the choices come in their order), or
 `{:error message}`."
 [{:keys [limits choices default], kind :type} v]
 (let [limited (fn [x]
    (if-let [e (limit-error x limits)]
     {:error e}
     {:value x}))]
  (case kind
   :bool (if (boolean? v) {:value v} {:error "must be true or false"})
   :int (if (whole? v) (limited v) {:error "must be a whole number"})
   :float
   (if (finite-number? v) (limited (double v)) {:error "must be a finite number"})
   :colour (if (colour? v) {:value v} {:error "is not a colour"})
   :font (if (and (string? v)
     (not (str/blank? v))
     (<= (count v) max-font-name)
     (not-any? #(Character/isISOControl ^char %) v))
    {:value v}
    {:error "must be a font name"})
   :set (if (and (sequential? v)
     (seq v)
     (every? keyword? v)
     (every? (set choices) v)
     (apply distinct? v))
    {:value (filterv (set v) choices)}
    {:error (str "must be some of "
      (str/join ", " (map name choices))
      ", at least one")})
   :tuple (tuple v default)
   {:error (str "has no known type " (pr-str kind))})))

;; --- the rules that tie settings together

(defn ^:private pair-parts
 "The numbers of a tuple value: the values of a map, or the sequence."
 [v]
 (if (map? v) (vals v) v))

(defn ^:private relation-reason
 "Why the values `values` (setting name to value) break the rule `r`, or nil if they keep
 it, or if a setting the rule needs has no value."
 [{:keys [rule setting of above bound]} values]
 (let [v (get values setting)
   other (get values of)]
  (when (and (some? v) (or (nil? of) (some? other)))
   (case rule
    :inside (when-not (< (first other) v (second other))
     (str "must lie strictly inside " of))
    :within_width (when-not (and (pos? v) (<= v (- (second other) (first other))))
     (str "must be above 0 and at most the width of " of))
    :ordered (cond (not (< (first v) (second v)))
     "must have its first part below its second"
     (and (some? above) (not (> (first v) above)))
     (str "must have its first part above " above))
    :all_above (when-not (every? #(> % bound) (pair-parts v))
     (str "must have every part above " bound))
    :at_most_setting (when-not (<= v other) (str "must be at most " of))
    :opacity (when-not (<= 0 (second v) 1) "must have an opacity between 0 and 1")
    (str "has an unknown rule " rule)))))

(defn check-relations
 "The rules of `relations` that the values `values` (setting name to value) break:
 `[{:setting s :reason r :relation rule} ...]`. A rule whose settings have no value is
 skipped."
 [relations values]
 (vec (for [r relations
    :let [reason (relation-reason r values)]
    :when reason]
   {:setting (:setting r), :reason reason, :relation r})))

(defn short-reason
 "What a broken rule `relation` says to the user who has just given `setting` a value: at
 most 18 characters for a rule about a number, the width of a value cell, and at most 29 for
 one about a tuple, the width of the form it is edited in."
 [relation setting]
 (case (:rule relation)
  :at_most_setting (if (= setting (:setting relation))
   (str "above " (:of relation))
   (str "below " (:setting relation)))
  :inside
  (if (= setting (:setting relation)) "outside the bounds" "mode out of range")
  :within_width
  (if (= setting (:setting relation)) "wider than bounds" "bounds too narrow")
  :ordered (if-let [above (:above relation)]
   (str "first below second, above " above)
   "first must be below second")
  :all_above (str "every part above " (:bound relation))
  :opacity "opacity from 0 to 1"
  "breaks a rule"))
