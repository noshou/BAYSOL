;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The electrons of a chemical formula, for the custom solutes: pure functions of text, so
;; none of it needs a terminal.
;;
;;   NaCl            28
;;   Ca(OH)2         Nested ( ) and [ ] with multipliers: 20 + 2 * 9 = 38
;;   CuSO4·5H2O      Parts apart with `·`, `.`, `*` or `•` (a hydrate or an adduct), each
;;                   with an optional leading multiplier
;;   NH4+  SO4 2-    A charge: a trailing `+` or `-`, with the number in front of it after a
;;                   space or `^` (`SO4 2-`, `SO4^2-`), or attached when the formula is
;;                   one element (`Al3+`, `O2-`: up to 4) or ends in a bracket
;;                   (`[Fe(CN)6]3-`). Elsewhere a number attached to the sign is a count
;;                   (`NH4+` is NH4 with one positive charge), so write `SO4 2-`.
;;
;; Heavy hydrogen `D` counts as hydrogen (Z = 1). Spaces are ignored. A formula comes to
;; `{:z electrons :charge n}` (the electrons of the atoms less the charge) or `{:error
;; "short message"}`, the message short enough for the note on the border of a screen.

(ns baysol.tui.formula
 (:require [clojure.string :as str]))

(def ^:private symbols
 "The element symbols in the order of their atomic numbers 1..118."
 (str/split
  (str
   "H He Li Be B C N O F Ne Na Mg Al Si P S Cl Ar K Ca Sc Ti V Cr Mn Fe Co Ni"
   " Cu Zn Ga Ge As Se Br Kr Rb Sr Y Zr Nb Mo Tc Ru Rh Pd Ag Cd In Sn Sb Te I Xe"
   " Cs Ba La Ce Pr Nd Pm Sm Eu Gd Tb Dy Ho Er Tm Yb Lu Hf Ta W Re Os Ir Pt Au Hg"
   " Tl Pb Bi Po At Rn Fr Ra Ac Th Pa U Np Pu Am Cm Bk Cf Es Fm Md No Lr Rf Db Sg"
   " Bh Hs Mt Ds Rg Cn Nh Fl Mc Lv Ts Og")
  #" "))

(def atomic-number
 "`{symbol Z}` for the 118 elements, and `D` (heavy hydrogen) as 1."
 (assoc (zipmap symbols (range 1 (inc (count symbols)))) "D" 1))

(def ^:private part-separators "·.*•")

(def ^:private max-attached-charge
 "The most a number attached to the sign of a single element is read as a charge (`Al3+`),
 not a count."
 4)

;; --- the atoms of one part: a recursive descent over the characters

(defn ^:private fail
 [message]
 (throw (ex-info message {::error message})))

(defn ^:private read-int
 "`[n index]` of the digits of `s` from `i` (nil for n when there are none)."
 [^String s i]
 (let [end (loop [j i]
    (if (and (< j (count s)) (Character/isDigit (.charAt s j)))
     (recur (inc j))
     j))]
  [(when (> end i) (Long/parseLong (subs s i end))) end]))

(defn ^:private read-count
 "`[count index]`: the number at `i` (1 when there is none), which must not be 0."
 [s i]
 (let [[n end] (read-int s i)]
  (when (and n (zero? n)) (fail "count must be > 0"))
  [(or n 1) end]))

(defn ^:private read-element
 "`[symbol index]` of the element that starts at `i` (an upper-case letter and, if it
 makes a symbol, the lower-case one after it)."
 [^String s i]
 (let [c (.charAt s i)
   next-c (when (< (inc i) (count s)) (.charAt s (inc i)))
   two (when (and next-c (Character/isLowerCase next-c)) (subs s i (+ i 2)))]
  (cond (and two (atomic-number two)) [two (+ i 2)]
   (atomic-number (str c)) [(str c) (inc i)]
   :else (fail (str "unknown element " (or two c))))))

(defn ^:private scale-counts
 "The element counts `counts` (`{symbol n}`) each times `k`."
 [counts k]
 (update-vals counts #(* k %)))

(defn ^:private read-atoms
 "`[counts index]` of the atoms of `s` from `i` up to the end or a closing bracket that
 is not this call's (`close`, a character or nil); `counts` is `{symbol n}`."
 [^String s i close]
 (loop [i i
   total {}]
  (if (>= i (count s))
   (if close (fail "unbalanced bracket") [total i])
   (let [c (.charAt s i)]
    (cond
     (Character/isUpperCase c)
     (let [[sym j] (read-element s i)
       [n k] (read-count s j)]
      (recur k (update total sym (fnil + 0) n)))

     (or (= c \() (= c \[))
     (let [[inner j] (read-atoms s (inc i) (if (= c \() \) \]))
       [n k] (read-count s j)]
      (recur k (merge-with + total (scale-counts inner n))))

     (or (= c \)) (= c \]))
     (if (= c close) [total (inc i)] (fail "unbalanced bracket"))

     :else (fail (str "unexpected character " c)))))))

(defn ^:private part-counts
 "The element counts of one part (`5H2O`, `Ca(OH)2`): its leading multiplier times its
 atoms."
 [^String part]
 (when (str/blank? part) (fail "empty part"))
 (let [[mult i] (read-int part 0)]
  (when (and mult (zero? mult)) (fail "count must be > 0"))
  (let [[total _] (read-atoms part i nil)]
   (when (= i (count part)) (fail "no atoms"))
   (scale-counts total (or mult 1)))))

(defn ^:private electrons
 "The electrons of the atoms `counts` (`{symbol n}`) have."
 [counts]
 (reduce + (map (fn [[sym n]] (* n (atomic-number sym))) counts)))

;; --- the charge

(defn ^:private split-charge
 "`[body charge]` of the trimmed formula `s`: the formula without its charge, and the
 charge as a number (0 for none). See the namespace comment for where digits count as the
 charge."
 [^String s]
 (let [sign (when (seq s) (get {\+ 1, \- -1, \− -1} (last s)))]
  (if-not sign
   [s 0]
   (let [body (str/trimr (subs s 0 (dec (count s))))
     explicit (re-matches #"(?s)(.*?)\s*\^\s*(\d+)|(?s)(.*?\S)\s+(\d+)" body)
     [_ a b c d] explicit
     attached (re-matches #"(?s)(.*[)\]])(\d+)|([A-Z][a-z]?)(\d+)" body)
     [_ e f g h] attached
     single?
     (and g (atomic-number g) (<= (Long/parseLong h) max-attached-charge))]
    (cond explicit (let [digits (Long/parseLong (or b d))]
      [(or a c) (* sign digits)])
     e [e (* sign (Long/parseLong f))]
     single? [g (* sign (Long/parseLong h))]
     :else [body sign])))))

;; --- the formula

(defn ^:private analyse
 "`{:counts {symbol n} :charge n :z electrons}` of the formula text `text`, or `{:error
 \"short message\"}`."
 [text]
 (try
  (let [s (str/trim (str text))]
   (when (str/blank? s) (fail "formula needed"))
   (let [[body charge] (split-charge s)
     body (str/replace body #"\s+" "")
     parts (str/split body (re-pattern (str "[" part-separators "]")) -1)
     counts (apply merge-with + (map part-counts parts))]
    {:counts counts, :charge charge, :z (- (electrons counts) charge)}))
  (catch clojure.lang.ExceptionInfo e
   (if-let [m (::error (ex-data e))]
    {:error m}
    (throw e)))))

(defn parse-formula
 "The electrons of the formula text `text`: `{:z electrons :charge n}` or `{:error
 \"short message\"}`. The electrons are those of the atoms less the charge. `Z` is not
 checked to be above 0 here."
 [text]
 (let [r (analyse text)] (if (:error r) r (select-keys r [:z :charge]))))

(defn element-counts
 "The atoms of the formula text `text`, for showing how its electrons add up:
 `{:counts [[symbol n] ...] :charge n :z electrons}` or `{:error \"short message\"}`.
 The elements are in Hill order (C first, then H, then the others alphabetically; all
 alphabetical when there is no carbon), the counts summed over the parts and the groups
 of a hydrate or an adduct.

 # Returns
 A map as above.

 # Exceptions
 None."
 [text]
 (let [r (analyse text)]
  (if (:error r)
   r
   (let [counts (:counts r)
     hill? (contains? counts "C")
     rank (fn [[sym _]]
      (cond (and hill? (= sym "C")) [0 sym]
       (and hill? (= sym "H")) [1 sym]
       :else [2 sym]))]
    {:counts (vec (sort-by rank counts)), :charge (:charge r), :z (:z r)}))))

(defn breakdown
 "The electrons of the formula text `text` as a sum, `7 C + 13 H + 1 N + 3 O + 1 S = 102
 electrons, charge 0` (a positive charge carries its `+`), or nil when the formula is not
 understood."
 [text]
 (let [{:keys [counts charge z error]} (element-counts text)]
  (when-not error
   (str (str/join " + " (map (fn [[sym n]] (str n " " sym)) counts))
    " = "
    z
    " electrons, charge "
    (if (pos? charge) "+" "")
    charge))))

(defn strip-unit
 "The text `text` of a polymer's repeat unit without a surrounding `( )n` (`(C2H4O)n` gives
 `C2H4O`), trimmed; text without it is returned trimmed."
 [text]
 (let [s (str/trim (str text))]
  (if-let [[_ inner] (re-matches #"(?s)\((.*)\)\s*n" s)]
   (str/trim inner)
   s)))

(defn parse-unit
 "The repeat unit of a polymer from the text `text` (`C2H4O` or `(C2H4O)n`): `{:unit
 \"C2H4O\" :z electrons-per-unit}` or `{:error \"short message\"}`. A charge is not
 allowed."
 [text]
 (let [unit (strip-unit text)
   parsed (parse-formula unit)]
  (cond (:error parsed) parsed
   (not (zero? (:charge parsed))) {:error "no charge allowed"}
   :else {:unit unit, :z (:z parsed)})))
