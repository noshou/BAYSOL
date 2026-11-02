;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The checks on the value of a setting (`baysol.tui.validate`): the cases that the Julia
;; side judges too (test/fixtures/settings/cases.edn, which test_settings.jl reads as well),
;; each type and limit with its edges, the rules that tie settings together, and seeded
;; fuzzing with values of every shape.

(ns baysol.tui.validate-test
 (:require [baysol.tui.settings :as settings]
  [baysol.tui.validate :as validate]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (java.util Random)))

(def ^:private defaults (settings/read-defaults))
(def ^:private relations (settings/read-relations))

(def ^:private entries
 "Every setting's entry, by name."
 (into {} (for [[_ es] defaults [setting entry] es] [setting entry])))

(def ^:private screen-of
 (into {} (for [[screen es] defaults setting (keys es)] [setting screen])))

(defn ^:private same?
 "Whether `a` and `b` are the same value, numbers compared as numbers (3 and 3.0 are)."
 [a b]
 (cond (and (number? a) (number? b)) (== a b)
  (and (map? a) (map? b)) (and (= (set (keys a)) (set (keys b)))
   (every? #(same? (get a %) (get b %)) (keys a)))
  (and (sequential? a) (sequential? b)) (and (= (count a) (count b))
   (every? true? (map same? a b)))
  :else (= a b)))

(def ^:private cases
 (edn/read-string
  (slurp (io/file "../test/fixtures/settings/cases.edn") :encoding "UTF-8")))

(defn ^:private judge
 "What `wipe-invalid` makes of a case of the fixture: `{:settings s :wiped w}`."
 [{:keys [setting value with]}]
 (let [saved (assoc (or with {}) setting value)
   stored (reduce-kv (fn [m s v]
     (assoc-in m [(screen-of s) s] {:value v}))
    {}
    saved)]
  (settings/wipe-invalid defaults relations stored)))

(deftest the-cases-both-sides-judge-alike
 (testing "the fixture covers every setting, with valid and refused values"
  (is (< 200 (count cases)))
  (is (= (set (keys entries)) (set (map :setting cases))))
  (is (< 60 (count (filter :valid cases))))
  (is (< 140 (count (remove :valid cases)))))
 (doseq [{:keys [setting value valid expect mention], :as c} cases
   :let [{:keys [settings wiped]} (judge c)
    kept (settings/value (get-in settings
      [(screen-of setting) setting]))]]
  (if valid
   (do (is (empty? wiped)
     (str setting " = " (pr-str value) " should be kept: " (pr-str wiped)))
    (when (contains? c :expect)
     (is (same? expect kept)
      (str setting " = " (pr-str value) " is kept as " (pr-str kept)))))
   (do (is (seq wiped) (str setting " = " (pr-str value) " should be wiped"))
    (is (some #(str/includes? (:reason %) mention) wiped)
     (str setting
      " = " (pr-str value)
      ": " (pr-str (map :reason wiped))
      " lacks " mention))
    (is (some #(or (= setting (:setting %)) (str/includes? (:reason %) setting))
      wiped)
     (str setting " is not named in " (pr-str wiped)))))))

(deftest every-wiped-setting-is-back-at-its-default
 (doseq [{:keys [valid], :as c} cases
   :when (not valid)
   :let [{:keys [settings wiped]} (judge c)]
   {s :setting, screen :screen} wiped]
  (is (not (contains? (get-in settings [screen s]) :value))
   (str s " keeps a saved value after it was wiped"))
  (is (same? (:default (get entries s))
    (settings/value (get-in settings [screen s]))))))

(deftest numbers
 (testing "a whole number setting"
  (let [e {:type :int, :limits {:at-least 1}}]
   (is (= {:value 5} (validate/check e 5)))
   (is (= {:value 1} (validate/check e 1)))
   (is (= "must be at least 1" (:error (validate/check e 0))))
   (is (= "must be a whole number" (:error (validate/check e 2.0))))
   (is (= "must be a whole number" (:error (validate/check e "5"))))
   (is (= "must be a whole number" (:error (validate/check e nil))))
   (is (= "must be a whole number" (:error (validate/check e true))))
   (is (= "must be a whole number" (:error (validate/check e 1/2))))
   (is (= "must be a whole number" (:error (validate/check e (bigint 5)))))
   (is (= "must be a whole number" (:error (validate/check e [5]))))))
 (testing "a setting with a lower and an upper limit"
  (let [e {:type :int, :limits {:above 0, :below 100}}]
   (is (= {:value 50} (validate/check e 50)))
   (is (= {:value 1} (validate/check e 1)))
   (is (= {:value 99} (validate/check e 99)))
   (is (= "must be above 0" (:error (validate/check e 0))))
   (is (= "must be below 100" (:error (validate/check e 100))))
   (is (= "must be below 100" (:error (validate/check e Long/MAX_VALUE))))
   (is (= "must be above 0" (:error (validate/check e Long/MIN_VALUE))))))
 (testing
  "a float setting takes a whole number as a float and refuses what is not finite"
  (let [e {:type :float, :limits {:above 0, :at-most 1}}]
   (is (= {:value 1.0} (validate/check e 1)))
   (is (= {:value 0.5} (validate/check e 0.5)))
   (is (= {:value 1.0E-300} (validate/check e 1.0E-300)))
   (is (instance? Double (:value (validate/check e 1))))
   (is (= "must be above 0" (:error (validate/check e 0))))
   (is (= "must be above 0" (:error (validate/check e -0.0))))
   (is (= "must be at most 1" (:error (validate/check e 1.0000001))))
   (doseq [bad [Double/NaN Double/POSITIVE_INFINITY Double/NEGATIVE_INFINITY]]
    (is (= "must be a finite number" (:error (validate/check e bad)))))
   (is (= "must be a finite number" (:error (validate/check e "0.5"))))
   (is (= "must be a finite number" (:error (validate/check e nil))))
   (is (= "must be a finite number" (:error (validate/check e false))))))
 (testing "no limits is no limit"
  (is (= {:value -7} (validate/check {:type :int, :limits {}} -7)))
  (is (= {:value Long/MIN_VALUE}
    (validate/check {:type :int, :limits {}} Long/MIN_VALUE)))))

(deftest yes-no
 (let [e {:type :bool}]
  (is (= {:value true} (validate/check e true)))
  (is (= {:value false} (validate/check e false)))
  (doseq [bad [nil 0 1 "true" :true [true] {}]]
   (is (= "must be true or false" (:error (validate/check e bad))) (pr-str bad)))))

(deftest colours
 (let [e {:type :colour}]
  (testing "a name of the list, as a keyword, and #rrggbb"
   (doseq [good [:crimson :antiquewhite4 :black :gray20 "#ff0000" "#A0b1C2"
      "#000000"]]
    (is (= {:value good} (validate/check e good)) (pr-str good))))
  (testing "anything else is not a colour"
   (doseq [bad [:notacolour "red" "crimson" 5 nil "#fff" "#ff00000" "#GGGGGG" ""
      :a/crimson [:red] {} "#ff00 0" "ff0000"]]
    (is (= "is not a colour" (:error (validate/check e bad))) (pr-str bad))))))

(deftest fonts
 (let [e {:type :font}]
  (is (= {:value "Latin Modern Roman"} (validate/check e "Latin Modern Roman")))
  (is (= {:value "κ Font δ"} (validate/check e "κ Font δ")))
  (is (= {:value (apply str (repeat 100 "x"))}
    (validate/check e (apply str (repeat 100 "x")))))
  (doseq [bad ["" "   " (apply str (repeat 101 "x")) "a\u0001b" "a\nb" "a\tb" 5 nil
     :font ["f"]]]
   (is (= "must be a font name" (:error (validate/check e bad))) (pr-str bad)))))

(deftest choices
 (let [e {:type :set, :choices [:pdf :png :svg]}]
  (testing "some of the choices, in the order of the choices"
   (is (= {:value [:pdf]} (validate/check e [:pdf])))
   (is (= {:value [:pdf :svg]} (validate/check e [:svg :pdf])))
   (is (= {:value [:pdf :png :svg]} (validate/check e [:svg :png :pdf])))
   (is (= {:value [:png]} (validate/check e '(:png)))))
  (testing "none, a stranger, a repeat, or a thing that is no list is refused"
   (doseq [bad [[] [:gif] [:pdf :pdf] "pdf" :pdf nil [:pdf "png"] {:pdf true}
      [:pdf :gif]]]
    (is (some? (:error (validate/check e bad))) (pr-str bad)))
   (is (str/includes? (:error (validate/check e [])) "at least one")))))

(deftest tuples
 (testing "numbers shaped like the default"
  (let [e {:type :tuple, :default [1.0 2.0 3.0]}]
   (is (= {:value [1.0 2.0 3.0]} (validate/check e [1.0 2.0 3.0])))
   (is (= {:value [1.0 2.0 3.0]} (validate/check e [1 2 3])))
   (is (= "must have 3 parts" (:error (validate/check e [1.0 2.0]))))
   (is (= "must have 3 parts" (:error (validate/check e [1 2 3 4]))))
   (is (= "must have 3 parts" (:error (validate/check e 5))))
   (is (= "must have 3 parts" (:error (validate/check e {:a 1}))))
   (is (= "a part must be a finite number" (:error (validate/check e ["a" 1 2]))))
   (is (= "a part must be a finite number" (:error (validate/check e [1 2 nil]))))
   (is (= "a part must be a finite number"
     (:error (validate/check e [1 2 Double/NaN]))))))
 (testing "a pair of a colour and an opacity"
  (let [e {:type :tuple, :default [:red 0.5]}]
   (is (= {:value [:blue 0.25]} (validate/check e [:blue 0.25])))
   (is (= {:value [:blue 1.0]} (validate/check e [:blue 1])))
   (is (= "a part must be a colour" (:error (validate/check e [:notacolour 0.5]))))
   (is (= "a part must be a colour" (:error (validate/check e [0.5 :red]))))
   (is (= "a part must be a finite number" (:error (validate/check e [:red "x"]))))
   (is (= "must have 2 parts" (:error (validate/check e [:red]))))))
 (testing "a map with the keys of the default"
  (let [e {:type :tuple, :default {:width 70, :height 18}}]
   (is (= {:value {:width 80, :height 24}}
     (validate/check e {:height 24, :width 80})))
   (is (= "a part must be a whole number"
     (:error (validate/check e {:width 7.5, :height 3}))))
   (is (str/includes? (:error (validate/check e {:width 70})) "exactly"))
   (is (str/includes? (:error (validate/check e {:width 70, :height 18, :depth 1}))
     "exactly"))
   (is (str/includes? (:error (validate/check e [70 18])) "exactly")))))

(deftest an-unknown-type-is-refused
 (is (str/includes? (:error (validate/check {:type :mystery} 1)) "no known type"))
 (is (str/includes? (:error (validate/check {} 1)) "no known type")))

(deftest rules
 (let [broken (fn [r values] (seq (validate/check-relations [r] values)))]
  (testing "inside"
   (let [r {:rule :inside, :setting "M", :of "B"}]
    (is (nil? (broken r {"M" 1.0, "B" [0.0 2.0]})))
    (is (broken r {"M" 0.0, "B" [0.0 2.0]}))
    (is (broken r {"M" 2.0, "B" [0.0 2.0]}))
    (is (broken r {"M" 9.0, "B" [0.0 2.0]}))
    (is (nil? (broken r {"M" 1.0}))
     "a rule whose other setting has no value is skipped")))
  (testing "within the width"
   (let [r {:rule :within_width, :setting "E", :of "B"}]
    (is (nil? (broken r {"E" 0.5, "B" [1.0 1.5]})))
    (is (broken r {"E" 0.6, "B" [1.0 1.5]}))
    (is (broken r {"E" 0.0, "B" [1.0 1.5]}))
    (is (broken r {"E" -1.0, "B" [1.0 1.5]}))))
  (testing "ordered, with and without a floor"
   (let [r {:rule :ordered, :setting "P"}
     above {:rule :ordered, :setting "P", :above 0}]
    (is (nil? (broken r {"P" [-5.0 3.0]})))
    (is (broken r {"P" [3.0 -5.0]}))
    (is (broken r {"P" [1.0 1.0]}))
    (is (nil? (broken above {"P" [0.5 1.0]})))
    (is (broken above {"P" [0.0 1.0]}))
    (is (broken above {"P" [-1.0 1.0]}))))
  (testing "all above"
   (let [r {:rule :all_above, :setting "R", :bound 0}]
    (is (nil? (broken r {"R" [1.0 2.0 3.0]})))
    (is (nil? (broken r {"R" {:width 70, :height 18}})))
    (is (broken r {"R" [1.0 0.0 3.0]}))
    (is (broken r {"R" {:width 0, :height 18}}))))
  (testing "at most another setting"
   (let [r {:rule :at_most_setting, :setting "A", :of "B"}]
    (is (nil? (broken r {"A" 5, "B" 5})))
    (is (nil? (broken r {"A" 4, "B" 5})))
    (is (broken r {"A" 6, "B" 5}))))
  (testing "an opacity"
   (let [r {:rule :opacity, :setting "C"}]
    (is (nil? (broken r {"C" [:red 0.0]})))
    (is (nil? (broken r {"C" [:red 1.0]})))
    (is (broken r {"C" [:red 1.0001]}))
    (is (broken r {"C" [:red -0.0001]}))))
  (testing "an unknown rule is a problem, not a pass"
   (is (broken {:rule :mystery, :setting "X"} {"X" 1})))
  (testing "the defaults keep every rule of the bundled file"
   (is (empty? (validate/check-relations
      relations
      (into {} (for [[s e] entries] [s (:default e)]))))))))

(deftest what-a-broken-rule-says-to-the-user
 (let [tuple-settings
   (set
    (for [[_ es] defaults [setting e] es :when (= :tuple (:type e))] setting))]
  (doseq [r relations
    setting (remove nil? [(:setting r) (:of r)])
    :let [reason (validate/short-reason r setting)]]
   (is (not (str/blank? reason)))
   (testing
    "a rule about a number fits a value cell, one about a tuple the form it is edited in"
    (is (<= (count reason) (if (contains? tuple-settings setting) 29 18))
     (str reason " is " (count reason) " characters for " setting)))
   (is (<= (count reason) 29))))
 (let [r {:rule :at_most_setting, :setting "SASA_N_OCC", :of "SHELL_SAMPLE"}]
  (is (= "above SHELL_SAMPLE" (validate/short-reason r "SASA_N_OCC")))
  (is (= "below SASA_N_OCC" (validate/short-reason r "SHELL_SAMPLE"))))
 (testing "the rules about tuples"
  (is (= "first must be below second"
    (validate/short-reason {:rule :ordered, :setting "B"} "B")))
  (is (= "first below second, above 0"
    (validate/short-reason {:rule :ordered, :setting "B", :above 0} "B")))
  (is (= "every part above 0"
    (validate/short-reason {:rule :all_above, :setting "R", :bound 0} "R")))
  (is (= "opacity from 0 to 1"
    (validate/short-reason {:rule :opacity, :setting "C"} "C")))
  (is (= "mode out of range"
    (validate/short-reason {:rule :inside, :setting "M", :of "B"} "B")))
  (is (= "outside the bounds"
    (validate/short-reason {:rule :inside, :setting "M", :of "B"} "M")))
  (is (= "bounds too narrow"
    (validate/short-reason {:rule :within_width, :setting "E", :of "B"}
     "B")))))

;; --- fuzzing

(def ^:private junk
 (edn/read-string
  (str
   "[nil true false 0 1 -1 2 2.5 -0.0 1e300 \"\" \"x\" \"#ff0000\" \"#zzzzzz\" :pdf :red "
   ":notacolour :a/b [] [1] [1 2] [1 2 3] [:red 0.5] [:pdf :png] {} "
   "{:width 1 :height 2} {:a 1} (1 2) [[1]] 99999 [0 0 0] [nil nil] \"a\\nb\" "
   "[:red 2] [-1 5] {:width 0 :height 0}]")))

(deftest fuzzing-the-value-of-every-setting
 (let [long-text (apply str (repeat 120 "y"))]
  (doseq [[setting entry] entries
    v (conj junk
     long-text
     Double/NaN
     Double/POSITIVE_INFINITY
     1/3
     (bigint 1)
     Long/MAX_VALUE)
    :let [r (validate/check entry v)]]
   (testing (str setting " = " (pr-str v))
    (is (= 1 (count (select-keys r [:value :error])))
     "one answer, a value or an error")
    (if (contains? r :value)
     (let [again (validate/check entry (:value r))]
      (is (= r again) "what is kept is kept again, unchanged")
      (case (:type entry)
       :int (is (instance? Long (:value r)))
       :float (is (and (instance? Double (:value r)) (Double/isFinite (:value r))))
       :bool (is (boolean? (:value r)))
       :font (is (string? (:value r)))
       :set (is (every? (set (:choices entry)) (:value r)))
       :tuple (is (= (count (:default entry)) (count (:value r))))
       nil)
      (when (#{:int :float} (:type entry))
       (doseq [[k ok?] {:above >, :below <, :at-least >=, :at-most <=}
         :let [bound (get (:limits entry) k)]
         :when bound]
        (is (ok? (:value r) bound)))))
     (is (string? (:error r)))))))
 (testing "a value kept by one setting of a family is judged by its own limits"
  (is (= "must be at most 1"
    (:error (validate/check (get entries "OPTIMUM_CHAIN_FRACTION") 2))))))

(deftest fuzzing-whole-files
 (let [rng (Random. 20261101)
   pick (fn [coll] (nth coll (.nextInt rng (count coll))))
   names (vec (keys entries))]
  (dotimes [_ 600]
   (let [k (inc (.nextInt rng 6))
     stored (reduce (fn [m _]
       (let [s (pick names)]
        (assoc-in m [(screen-of s) s] {:value (pick junk)})))
      {}
      (range k))
     {:keys [settings wiped]} (settings/wipe-invalid defaults relations stored)
     values (into {} (for [[_ es] settings [s e] es] [s (settings/value e)]))]
    (testing "whatever was written, what is kept keeps every rule and every type"
     (is (empty? (validate/check-relations relations values)) (pr-str stored))
     (doseq [[s v] values
       :let [e (get entries s)]]
      (is (= {:value v} (validate/check e v)) (str s " " (pr-str v)))))
    (testing
     "each wipe is a setting that was written, or one a broken rule involves"
     (doseq [{s :setting} wiped]
      (is (contains? entries s)))))))
 (testing "a file with a thing that is no map for a screen or an entry"
  (let [{:keys [settings wiped]}
    (settings/wipe-invalid
     defaults
     relations
     {:sampler {"N_ADAPT" 5, "N_DRAWS" nil, "RNG_SEED" {:value 3}}})]
   (is (= #{"N_ADAPT" "N_DRAWS"} (set (map :setting wiped))))
   (is (= 3 (settings/value (get-in settings [:sampler "RNG_SEED"])))))))
