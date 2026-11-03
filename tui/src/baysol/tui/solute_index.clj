;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The names of every solute BAYSOL knows, for the autocomplete of the buffer page
;; (`baysol.tui.add-flow`): the index file `resources/solute_index.edn` (written by
;; `bb harvest-solutes` from the Julia tables, see that tool for the format), the polymer
;; families of `resources/polymer_families.edn` and the custom solutes of the user.
;;
;; A result of `search` is `{:name :kind :target :tag :basis}`:
;;   :name    the text to show: the name as typed in the index (lower case) or a custom
;;            solute's own name
;;   :kind    `:nonbiological`, `:polymer`, `:polymer-family`, `:custom-nonbio`,
;;            `:custom-polymer`
;;   :target  what the buffer row takes: the lower-case IUPAC name (`:nonbiological`,
;;            the row's `:arg`), the grade (`:polymer`, the `:arg` too), the family id
;;            (`:polymer-family`, which also has `:family`), the custom name
;;   :tag     "solute", "polymer" (grades and families) or "custom"
;;   :basis   what a polymer's molarity is per, nil for per mole of chains and for
;;            everything that is no polymer; a custom solute has its `:entry`
;; Names are matched case-insensitively, as the Julia code lowercases them.

(ns baysol.tui.solute-index
 (:require [baysol.tui.text :as txt]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.string :as str]))

(def default-limit "How many results `search` gives at most." 200)

(defn ^:private joined
 "A name of the index file: a string, or the vector of pieces of a long one."
 [x]
 (if (string? x) x (apply str x)))

(defn ^:private read-resource
 [path]
 (with-open [r (java.io.PushbackReader.
    (io/reader (io/resource path) :encoding "UTF-8"))]
  (edn/read r)))

(defn ^:private entries-of
 "The entries (sorted by length, then alphabetically) of the index file's data."
 [data]
 (let [kinded (fn [kind tag section]
    (let [targets (mapv joined (:targets section))
      basis (:basis section)]
     (for [[n i] (:names section)
       :let [t (nth targets i)]]
      {:name (joined n),
       :kind kind,
       :target t,
       :tag tag,
       :basis (get basis t)})))
   families (for [[n id] (:families data)]
    {:name n,
     :kind :polymer-family,
     :target id,
     :family id,
     :tag "polymer",
     :basis nil})]
  (->> (concat (kinded :nonbiological "solute" (:nonbiological data))
    (kinded :polymer "polymer" (:polymers data))
    families)
   (sort-by (juxt (comp count :name) :name))
   vec)))

(def ^:private index
 "The built-in entries: {:entries [...] :by-name {lower-case-name entry}}."
 (delay (let [entries (entries-of (read-resource "solute_index.edn"))]
   {:entries entries,
    :by-name (into {} (map (juxt :name identity)) entries)})))

(def ^:private families
 (delay (read-resource "polymer_families.edn")))

(defn resolve-builtin
 "The built-in entry of the typed name `typed` (case-insensitive, a name or an alias), or
 nil: a map as `search` gives it."
 [typed]
 (get (:by-name @index) (txt/fold typed)))

(def ^:private basis-by-target
 (delay (into {}
   (keep (fn [e]
     (when (and (= (:kind e) :polymer) (:basis e))
      [(:target e) (:basis e)])))
   (:entries @index))))

(defn polymer-basis
 "What the molarity of the built-in polymer grade `target` (a buffer row's `:arg`,
 case-insensitive) is per, `\"per monomer unit\"` or `\"per 1000 Da\"`; nil for a grade
 that is per mole of chains, for a family string (`PEG n=22`) and for anything else."
 [target]
 (get @basis-by-target (txt/fold target)))

(defn builtin-name?
 "Whether `typed` is a name or alias of a built-in solute, polymer grade or family."
 [typed]
 (boolean (resolve-builtin typed)))

(defn ^:private custom-entry
 "The search result of the custom solute `e` (a map of `baysol.tui.custom-store`)."
 [e]
 (let [nonbio? (= (:kind e) :nonbiological)
   n (str (:name e))]
  {:name n,
   :kind (if nonbio? :custom-nonbio :custom-polymer),
   :target n,
   :tag "custom",
   :basis nil,
   :entry e}))

(defn ^:private rank
 "The group of the folded name `low` for the folded query `q`: 0 exact, 1 starts with, 2
 contains, nil no match."
 [low q]
 (cond (= low q) 0
  (str/starts-with? low q) 1
  (str/includes? low q) 2))

(defn search
 "The entries whose name matches `query` (case-insensitive), at most `limit` (default 200),
 only of the `kinds` (a set of the `:kind`s below) when that is given.

 `customs` are the custom solutes, maps `{:kind :nonbiological|:polymer :name ...}`; they
 match by name like the built-in ones. Order: the exact match, the names that start with
 the query, the names that contain it; each group by length, then alphabetically.

 # Returns
 A vector of `{:name :kind :target :tag :basis}` maps; a blank `query` gives none."
 ([query customs] (search query customs default-limit))
 ([query customs limit] (search query customs limit nil))
 ([query customs limit kinds]
  (let [q (txt/fold query)
    kept? (if kinds (comp boolean kinds :kind) any?)]
   (if (str/blank? q)
    []
    (let [builtin (group-by #(rank (:name %) q) (:entries @index))
      custom (group-by #(rank (txt/fold (:name %)) q)
       (map custom-entry customs))
      group (fn [g]
       (let [b (get builtin g)
         c (get custom g)]
        (if (seq c)
         (sort-by (juxt (comp count :name) (comp txt/fold :name))
          (concat b c))
         b)))]
     (into [] (comp (filter kept?) (take limit)) (mapcat group [0 1 2])))))))

(defn all-families
 "The polymer families of `polymer_families.edn`, a vector of `{:id :label :names :forms}`."
 []
 @families)

(defn family
 "The map of the polymer family `id` (a string, \"peg\") from `polymer_families.edn`:
 `{:id :label :names :forms}`, nil for another id."
 [id]
 (first (filter #(= (:id %) id) @families)))

(def ^:private kda-families
 "The families whose molar mass form takes kDa below 1000 (the Julia code's rule)."
 #{"dextran" "glucan"})

(defn ^:private number
 "The positive finite number typed as `x` (a number or text), nil when it is none."
 [x]
 (let [v (if (number? x)
    (double x)
    (try (Double/parseDouble (str/trim (str x))) (catch Exception _ nil)))]
  (when (and v (not (Double/isNaN v)) (not (Double/isInfinite v))) v)))

(defn ^:private plain
 "The number `v` as text: no exponent and no `.0` on a whole number."
 [v]
 (.toPlainString (.stripTrailingZeros (java.math.BigDecimal/valueOf (double v)))))

(defn family-arg
 "The `arg` of a buffer row for `fam` (as [[family]] gives it) and its form number
 `form-index`, from `values`, a map from an argument key (\"n\", \"nEO\") to the typed
 text or number: the form's template with every `{key}` replaced.

 # Returns
 `{:arg \"PEG n=22\"}`; for a molar mass of dextran or pullulan below 1000 also a `:note`
 (it counts as kDa). `{:error message}` when a value is no number, not above 0 or below
 the form's `:min`, or the form does not exist."
 [fam form-index values]
 (if-let [form (nth (:forms fam) form-index nil)]
  (loop [[a & more] (:args form)
    arg (:template form)
    note nil]
   (if-not a
    (cond-> {:arg arg} note (assoc :note note))
    (let [v (number (get values (:key a)))]
     (cond (nil? v) {:error (str (:key a) ": not a number")}
      (not (pos? v)) {:error (str (:key a) ": must be above 0")}
      (and (:min a) (< v (:min a)))
      {:error (str (:key a) ": at least " (:min a))}
      :else (recur more
       (str/replace arg (str "{" (:key a) "}") (plain v))
       (or note
        (when (and (contains? kda-families (:id fam))
          (= (:key a) "Mn")
          (< v 1000))
         "below 1000 counts as kDa")))))))
  {:error "no such form"}))
