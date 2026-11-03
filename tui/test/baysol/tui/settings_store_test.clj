;; SPDX-License-Identifier: LGPL-3.0-or-later

;; What the settings store does with a settings file that is wrong, and with defaults that
;; are wrong: a value that is not valid is wiped and the file rewritten, a file that cannot
;; be read is kept aside and replaced, a save that is not valid is refused, and corrupt
;; defaults make the harvest run again. All of it on synthetic files in temporary folders.

(ns baysol.tui.settings-store-test
 (:require [baysol.tui.screens.open-projects :as open-projects]
  [baysol.tui.settings :as settings]
  [baysol.tui.support :refer [temp-root]]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing use-fixtures]]))

(use-fixtures :each
 (fn [f] (settings/reset-notices!) (f) (settings/reset-notices!)))

(defn ^:private write-settings!
 "Makes the settings file of `root` hold the text `text`."
 [root text]
 (spit (settings/settings-file root) text :encoding "UTF-8"))

(defn ^:private read-file
 "The text of the file `name` in `root`, or nil if there is none."
 [root file-name]
 (let [f (io/file root file-name)] (when (.isFile f) (slurp f :encoding "UTF-8"))))

(defn ^:private saved-values
 "The saved values in the settings file of `root`, `{setting value}`, read as plain EDN."
 [root]
 (into {}
  (for [[_ es] (edn/read-string (read-file root "settings.edn"))
    [setting entry] es
    :when (contains? entry :value)]
   [setting (:value entry)])))

(defn ^:private value-of
 "The value of `setting` on `screen` of `settings`."
 [settings screen setting]
 (settings/value (get-in settings [screen setting])))

(defn ^:private file-with
 "A settings file text that saves each `[screen setting value]` of `rows`."
 [& rows]
 (pr-str (reduce (fn [m [screen setting v]]
    (assoc-in m [screen setting] {:value v}))
   {}
   rows)))

(deftest the-first-load-copies-the-defaults
 (let [root (temp-root)
   loaded (settings/load! root)]
  (is (= (slurp (io/resource "default_settings.edn") :encoding "UTF-8")
    (read-file root "settings.edn")))
  (is (= [] (:wiped (meta loaded))))
  (is (false? (:reset? (meta loaded))))
  (is (nil? (read-file root "settings.log"))
   "nothing was wrong, so nothing is logged")
  (is (every? #(= (:default %) (settings/value %)) (mapcat vals (vals loaded))))))

(deftest a-load-of-a-good-file-changes-nothing
 (let [root (temp-root)
   text (file-with [:sampler "N_ADAPT" 450]
    [:plots "PLOT_COLOUR_MAP" :darkorange]
    [:output "FIGURES_FORMATS" [:svg :pdf]])]
  (write-settings! root text)
  (let [loaded (settings/load! root)]
   (is (= text (read-file root "settings.edn"))
    "a file with nothing wrong is not rewritten")
   (is (= 450 (value-of loaded :sampler "N_ADAPT")))
   (is (= :darkorange (value-of loaded :plots "PLOT_COLOUR_MAP")))
   (is (= [:pdf :svg] (value-of loaded :output "FIGURES_FORMATS"))
    "in the order of the choices")
   (is (empty? (:wiped (meta loaded))))
   (is (nil? (read-file root "settings.log"))))))

(deftest a-value-that-is-not-valid-is-wiped
 (let [root (temp-root)]
  (write-settings! root
   (file-with [:sampler "N_ADAPT" 0]
    [:sampler "N_DRAWS" 900]
    [:plots "PLOT_COLOUR_MAP" :nope]))
  (let [loaded (settings/load! root)]
   (testing "the settings that were not valid are back at their defaults"
    (is (= 300 (value-of loaded :sampler "N_ADAPT")))
    (is (= :crimson (value-of loaded :plots "PLOT_COLOUR_MAP"))))
   (testing "the setting that was valid keeps its value"
    (is (= 900 (value-of loaded :sampler "N_DRAWS"))))
   (testing "the wipes are reported, with the reason"
    (is (= #{"N_ADAPT" "PLOT_COLOUR_MAP"}
      (set (map :setting (:wiped (meta loaded))))))
    (is (= 0
      (:value (first (filter #(= "N_ADAPT" (:setting %))
         (:wiped (meta loaded)))))))
    (is (str/includes? (:reason (first (filter #(= "N_ADAPT" (:setting %))
         (:wiped (meta loaded)))))
      "at least 1")))
   (testing "the file was rewritten without them"
    (is (= {"N_DRAWS" 900} (saved-values root))))
   (testing "the log says what happened"
    (let [log (read-file root "settings.log")]
     (is (str/includes? log "N_ADAPT: 0 is not valid"))
     (is (str/includes? log "reset to its default 300"))
     (is (str/includes? log "PLOT_COLOUR_MAP"))
     (is (= 2 (count (str/split-lines log))))))
   (testing "each wiped setting carries a notice"
    (is (= "reset to default" (get-in loaded [:sampler "N_ADAPT" :notice])))
    (is (nil? (get-in loaded [:sampler "N_DRAWS" :notice]))))
   (testing "a second load finds nothing wrong and does not log again"
    (let [again (settings/load! root)]
     (is (empty? (:wiped (meta again))))
     (is (= 2 (count (str/split-lines (read-file root "settings.log")))))
     (is (= "reset to default" (get-in again [:sampler "N_ADAPT" :notice]))
      "the notice stays until the setting is saved"))))))

(deftest every-kind-of-bad-entry-is-wiped
 (doseq [[what text]
   [["an entry that is no map" (pr-str {:sampler {"N_ADAPT" 5}})]
    ["an entry that is nil" (pr-str {:sampler {"N_ADAPT" nil}})]
    ["an entry that is a vector" (pr-str {:sampler {"N_ADAPT" [1 2]}})]
    ["a value of the wrong type" (file-with [:sampler "N_ADAPT" "300"])]
    ["a value out of range" (file-with [:sampler "N_ADAPT" -1])]
    ["a nil value" (file-with [:sampler "N_ADAPT" nil])]]]
  (let [root (temp-root)]
   (write-settings! root text)
   (let [loaded (settings/load! root)]
    (testing what
     (is (= 300 (value-of loaded :sampler "N_ADAPT")))
     (is (= ["N_ADAPT"] (map :setting (:wiped (meta loaded)))))
     (is (empty? (saved-values root))))))))

(deftest a-file-that-cannot-be-read-is-kept-aside-and-replaced
 (doseq [[what text]
   [["not EDN" "{ this is not (edn"] ["empty" ""] ["blank" "  \n  "]
    ["a vector" "[1 2 3]"] ["a number" "42"] ["a string" "\"hello\""]
    ["nil" "nil"] ["an unclosed map" "{:sampler {\"N_ADAPT\" {:value 5}}"]
    ["a stray closer" "}"] ["a duplicate key" "{:a 1 :a 2}"]
    ["binary-looking text" (String. (byte-array [1 2 3 0 -1]) "ISO-8859-1")]]]
  (let [root (temp-root)]
   (write-settings! root text)
   (let [loaded (settings/load! root)]
    (testing what
     (is (true? (:reset? (meta loaded))))
     (is (every? #(= (:default %) (settings/value %)) (mapcat vals (vals loaded)))
      "everything is at its default")
     (is (= text (read-file root "settings.edn.corrupt")) "the old file is kept")
     (is (= (set (keys (settings/read-defaults)))
       (set (keys (edn/read-string (read-file root "settings.edn"))))))
     (is (str/includes? (read-file root "settings.log") "could not be read"))
     (let [again (settings/load! root)]
      (is (false? (:reset? (meta again))) "the replacement reads")
      (is (empty? (:wiped (meta again))))))))))

(deftest values-that-break-a-rule-together-are-wiped-together
 (let [root (temp-root)]
  (write-settings! root
   (file-with [:model "SASA_N_OCC" 200]
    [:model "SHELL_SAMPLE" 100]))
  (let [loaded (settings/load! root)]
   (is (= 104 (value-of loaded :model "SASA_N_OCC")))
   (is (= 256 (value-of loaded :model "SHELL_SAMPLE")))
   (is (= #{"SASA_N_OCC" "SHELL_SAMPLE"}
     (set (map :setting (:wiped (meta loaded))))))
   (is (empty? (saved-values root))))
  (testing "a value that breaks a rule with a default is wiped alone"
   (write-settings! root
    (file-with [:model "BOUNDS_δρ₁₂" [-3.0 0.5]]
     [:model "κ_δρ₁₂" 20.0]))
   (let [loaded (settings/load! root)]
    (is (= [-10.0 2.0] (value-of loaded :model "BOUNDS_δρ₁₂")))
    (is (= 20.0 (value-of loaded :model "κ_δρ₁₂")))
    (is (= {"κ_δρ₁₂" 20.0} (saved-values root)))))))

(deftest a-file-of-many-bad-values-is-cleaned-in-one-load
 (let [root (temp-root)
   rows (for [[setting bad] [["N_ADAPT" 0] ["N_DRAWS" "x"] ["N_CHAINS" -3]
      ["TARGET_ACCEPT" 100]
      ["VAL_SIGMA" 0] ["FIGURES_TEX" 1]
      ["FIGURES_FORMATS" []]
      ["PLOT_COLOUR_MAP" "red"] ["PLOT_TEXT_FONT" ""]
      ["CHAIN_START_RADII" [1 2]]
      ["PLOT_PREVIEW_SIZE" {:width 0, :height 1}]
      ["PLOT_COLOUR_BAND" [:red 9]]]]
    [(some (fn [[screen es]] (when (contains? es setting) screen))
      (settings/read-defaults))
     setting bad])]
  (write-settings! root (apply file-with rows))
  (let [loaded (settings/load! root)]
   (is (= 12 (count (:wiped (meta loaded)))))
   (is (empty? (saved-values root)))
   (is (every? #(= (:default %) (settings/value %)) (mapcat vals (vals loaded))))
   (is (= 12 (count (str/split-lines (read-file root "settings.log"))))))))

(deftest unknown-names-are-dropped-quietly
 (let [root (temp-root)]
  (write-settings! root
   (pr-str {:sampler {"N_ADAPT" {:value 450},
      "NOT_A_SETTING" {:value 1}},
     :nowhere {"X" {:value 2}}}))
  (let [loaded (settings/load! root)]
   (is (= 450 (value-of loaded :sampler "N_ADAPT")))
   (is (nil? (get-in loaded [:sampler "NOT_A_SETTING"])))
   (is (nil? (get loaded :nowhere)))
   (is (empty? (:wiped (meta loaded)))))))

(deftest a-save-is-checked-before-it-is-written
 (let [root (temp-root)]
  (settings/load! root)
  (testing "a valid value is written, alone, and read back"
   (let [after (settings/save! root :sampler "N_ADAPT" 450)]
    (is (= 450 (value-of after :sampler "N_ADAPT")))
    (is (= {"N_ADAPT" 450} (saved-values root)))
    (is (= 450 (value-of (settings/load! root) :sampler "N_ADAPT")))
    (is (not (.exists (io/file root "settings.edn.tmp"))))))
  (testing "a whole number given to a float setting is kept as a float"
   (settings/save! root :sampler "BASIN_RESTART_NATS" 3)
   (is (= 3.0 (get (saved-values root) "BASIN_RESTART_NATS"))))
  (testing "a value that is not valid is refused and the file does not change"
   (let [before (read-file root "settings.edn")]
    (doseq [[screen setting v]
      [[:sampler "N_ADAPT" 0] [:sampler "N_ADAPT" "9"]
       [:sampler "N_ADAPT" 2.5]
       [:sampler "TARGET_ACCEPT" 100] [:plots "PLOT_COLOUR_MAP" :nope]
       [:plots "PLOT_TEXT_FONT" ""] [:output "FIGURES_FORMATS" []]
       [:output "FIGURES_FORMATS" [:gif]] [:plots "PLOT_COLOUR_BAND" [:red 2]]
       [:model "SASA_N_OCC" 9999] [:model "MODE_δρ₁₂" 50.0]]]
     (let [e (try (settings/save! root screen setting v) nil (catch Exception e e))]
      (is (some? e) (str setting " = " (pr-str v) " should be refused"))
      (when e
       (is (= ::settings/invalid (:type (ex-data e))))
       (is (= setting (:setting (ex-data e))))
       (is (string? (:reason (ex-data e)))))
      (is (= before (read-file root "settings.edn"))))))
   (testing "a setting that does not exist is refused"
    (is (thrown? clojure.lang.ExceptionInfo
      (settings/save! root :sampler "NOT_A_SETTING" 1)))
    (is (thrown? clojure.lang.ExceptionInfo
      (settings/save! root :nowhere "N_ADAPT" 1)))))))

(deftest a-save-keeps-the-rules-that-tie-settings-together
 (let [root (temp-root)]
  (settings/load! root)
  (settings/save! root :model "SHELL_SAMPLE" 300)
  (settings/save! root :model "SASA_N_OCC" 250)
  (testing "below the setting that must stay below it"
   (let [e (try (settings/save! root :model "SHELL_SAMPLE" 200)
      nil
      (catch Exception e e))]
    (is (str/includes? (:reason (ex-data e)) "SHELL_SAMPLE"))
    (is (= 300 (value-of (settings/load! root) :model "SHELL_SAMPLE")))))
  (testing "and the other way round"
   (is (thrown? clojure.lang.ExceptionInfo
     (settings/save! root :model "SASA_N_OCC" 301))))
  (testing "at the edge is fine"
   (settings/save! root :model "SASA_N_OCC" 300)
   (is (= 300 (value-of (settings/load! root) :model "SASA_N_OCC"))))))

(deftest a-save-takes-the-notice-away
 (let [root (temp-root)]
  (write-settings! root (file-with [:sampler "N_ADAPT" 0]))
  (is (= "reset to default"
    (get-in (settings/load! root) [:sampler "N_ADAPT" :notice])))
  (let [after (settings/save! root :sampler "N_ADAPT" 400)]
   (is (nil? (get-in after [:sampler "N_ADAPT" :notice])))
   (is (nil? (get-in (settings/load! root) [:sampler "N_ADAPT" :notice]))))))

;; --- the defaults themselves

(def ^:private good-defaults (settings/read-defaults))
(def ^:private good-relations (settings/read-relations))

(defn ^:private corrupt-defaults
 "The corruptions of the defaults, `[what defaults relations]`, each from the good ones."
 []
 (let [set-in (fn [path v] (assoc-in good-defaults path v))
   without (fn [path]
    (update-in good-defaults (butlast path) dissoc (last path)))]
  [["a default that is not valid" (set-in [:sampler "N_ADAPT" :default] 0)
    good-relations]
   ["a default of the wrong type" (set-in [:sampler "N_ADAPT" :default] "300")
    good-relations]
   ["a default that breaks its own limits"
    (set-in [:sampler "TARGET_ACCEPT" :default] 100)
    good-relations]
   ["a default that is no colour" (set-in [:plots "PLOT_COLOUR_MAP" :default] :nope)
    good-relations]
   ["a tuple default of the wrong size"
    (set-in [:sampler "CHAIN_START_RADII" :default] [1.0 2.0])
    good-relations]
   ["a tuple default of the wrong kind"
    (set-in [:sampler "CHAIN_START_RADII" :default] [1.0 :a 3.0])
    good-relations]
   ["a tuple default with no shape" (without [:sampler "CHAIN_START_RADII" :shape])
    good-relations]
   ["a tuple shape that is not the default's"
    (set-in [:sampler "CHAIN_START_RADII" :shape] [:int :int :int])
    good-relations]
   ["a map default of the wrong keys"
    (set-in [:plots "PLOT_PREVIEW_SIZE" :default] {:w 70, :h 18})
    good-relations]
   ["no default" (without [:sampler "N_ADAPT" :default]) good-relations]
   ["no type" (without [:sampler "N_ADAPT" :type]) good-relations]
   ["an unknown type" (set-in [:sampler "N_ADAPT" :type] :mystery) good-relations]
   ["no page" (without [:sampler "N_ADAPT" :page]) good-relations]
   ["a page that is zero" (set-in [:sampler "N_ADAPT" :page] 0) good-relations]
   ["a page twice" (set-in [:sampler "N_DRAWS" :page] 1) good-relations]
   ["limits that are no map" (set-in [:sampler "N_ADAPT" :limits] 5) good-relations]
   ["an unknown limit" (set-in [:sampler "N_ADAPT" :limits] {:above-all 1})
    good-relations]
   ["choices missing" (without [:output "FIGURES_FORMATS" :choices]) good-relations]
   ["an entry that is no map" (set-in [:sampler "N_ADAPT"] 5) good-relations]
   ["a screen that is no map" (set-in [:sampler] 5) good-relations]
   ["defaults that are no map" [1 2 3] good-relations]
   ["empty defaults" {} good-relations]
   ["nil defaults" nil good-relations]
   ["defaults that break a rule" (set-in [:model "MODE_δρ₁₂" :default] 7.0)
    good-relations]
   ["rules that are no list" good-defaults {:rule :inside}]
   ["a rule that is no map" good-defaults [5]]
   ["a rule that is unknown" good-defaults [{:rule :mystery, :setting "N_ADAPT"}]]
   ["a rule for a setting that does not exist" good-defaults
    [{:rule :all_above, :setting "NOPE", :bound 0}]]
   ["a rule with an `of` that does not exist" good-defaults
    [{:rule :inside, :setting "MODE_δρ₁₂", :of "NOPE"}]]]))

(deftest the-defaults-are-checked
 (is (empty? (settings/defaults-problems good-defaults good-relations)))
 (doseq [[what defaults relations] (corrupt-defaults)]
  (is (seq (settings/defaults-problems defaults relations))
   (str what " should be refused"))))

(deftest corrupt-defaults-make-the-harvest-run-again
 (testing "sound defaults: no harvest"
  (let [runs (atom 0)]
   (binding [settings/*regenerate* #(do (swap! runs inc) true)
     settings/*read* (fn [] [good-defaults good-relations])]
    (is (= [good-defaults good-relations] (settings/ensure-defaults!))))
   (is (zero? @runs))))
 (doseq [[what defaults relations] (corrupt-defaults)]
  (testing (str what ", mended by the harvest")
   (let [mended (atom false)
     runs (atom 0)]
    (binding [settings/*regenerate* #(do (swap! runs inc) (reset! mended true))
      settings/*read* (fn []
       (if @mended
        [good-defaults good-relations]
        [defaults relations]))]
     (is (= [good-defaults good-relations] (settings/ensure-defaults!)))
     (is (= 1 @runs)))))
  (testing (str what ", not mended")
   (let [runs (atom 0)]
    (binding [settings/*regenerate* #(do (swap! runs inc) false)
      settings/*read* (fn [] [defaults relations])]
     (let [e (try (settings/ensure-defaults!) nil (catch Exception e e))]
      (is (= ::settings/defaults-corrupt (:type (ex-data e))))
      (is (= 1 @runs)))))
   (testing "even when the harvest says it worked but changed nothing"
    (binding [settings/*regenerate* (constantly true)
      settings/*read* (fn [] [defaults relations])]
     (is (thrown? clojure.lang.ExceptionInfo (settings/ensure-defaults!))))))))
(testing "defaults that cannot even be read"
 (let [mended (atom false)]
  (binding [settings/*regenerate* #(reset! mended true)
    settings/*read* (fn []
     (if @mended
      [good-defaults good-relations]
      (throw (java.io.FileNotFoundException.
        "default_settings.edn"))))]
   (is (= [good-defaults good-relations] (settings/ensure-defaults!))))))

(deftest loading-with-corrupt-defaults
 (testing "mended defaults let the load go on"
  (let [root (temp-root)
    mended (atom false)]
   (binding [settings/*regenerate* #(reset! mended true)
     settings/*read* (fn []
      (if @mended
       [good-defaults good-relations]
       [(assoc-in good-defaults
         [:sampler "N_ADAPT" :default]
         0) good-relations]))]
    (is (= 300 (value-of (settings/load! root) :sampler "N_ADAPT"))))))
 (testing "defaults that stay corrupt stop the load and no file is made"
  (let [root (temp-root)]
   (binding [settings/*regenerate* (constantly false)
     settings/*read* (fn [] [(assoc-in good-defaults
        [:sampler "N_ADAPT" :default]
        0) good-relations])]
    (is (thrown? clojure.lang.ExceptionInfo (settings/load! root)))
    (is (thrown? clojure.lang.ExceptionInfo
      (settings/save! root :sampler "N_ADAPT" 5)))
    (is (nil? (read-file root "settings.edn")))))))

(deftest opening-a-project-checks-the-settings
 (let [warnings (fn [f]
    (let [err (java.io.StringWriter.)]
     (binding [*err* err] (let [r (f)] [r (str err)]))))]
  (testing "good settings: nothing is said"
   (let [root (temp-root)
     [ok? said] (warnings #(open-projects/check-settings! root))]
    (is (true? ok?))
    (is (str/blank? said))))
  (testing "a value that is not valid is wiped, and a warning names it"
   (let [root (temp-root)]
    (write-settings! root (file-with [:sampler "N_ADAPT" 0]))
    (let [[ok? said] (warnings #(open-projects/check-settings! root))]
     (is (true? ok?))
     (is (str/includes? said "N_ADAPT"))
     (is (str/includes? said "reset to its default"))
     (is (= 300 (value-of (settings/load! root) :sampler "N_ADAPT"))))))
  (testing "a file that cannot be read is replaced, and a warning says so"
   (let [root (temp-root)]
    (write-settings! root "{ nonsense")
    (let [[ok? said] (warnings #(open-projects/check-settings! root))]
     (is (true? ok?))
     (is (str/includes? said "settings.edn.corrupt")))))
  (testing "defaults that cannot be mended: false, with an error"
   (let [root (temp-root)]
    (binding [settings/*regenerate* (constantly false)
      settings/*read* (fn [] [{} []])]
     (let [[ok? said] (warnings #(open-projects/check-settings! root))]
      (is (false? ok?))
      (is (str/includes? said "cannot be used"))))))))
