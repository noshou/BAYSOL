;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The settings of a project: a copy of the global ones to start from, then their own, with
;; the global settings, not the defaults, as the baseline they are reset to; checked in the
;; same way as the global ones. On synthetic settings files.

(ns baysol.tui.settings-project-test
 (:require [baysol.tui.settings :as settings]
  [baysol.tui.support :as support]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing use-fixtures]]))

(use-fixtures :each
 (fn [f] (settings/reset-notices!) (f) (settings/reset-notices!)))

(defn ^:private project-in
 "A new project folder (a File) in the BAYSOL folder `root`."
 [root id]
 (doto (io/file root "projects" id) (.mkdirs)))

(defn ^:private text-of
 [root file-name]
 (let [f (io/file root file-name)] (when (.isFile f) (slurp f))))

(defn ^:private value-of
 [loaded screen setting]
 (settings/value (get-in loaded [screen setting])))

(defn ^:private saved-values
 "`{setting value}` of the saved values in the settings file of the folder `dir`."
 [dir]
 (into {}
  (for [[_ es] (edn/read-string (slurp (settings/settings-file dir)))
    [setting entry] es
    :when (contains? entry :value)]
   [setting (:value entry)])))

(defn ^:private file-with
 [& rows]
 (pr-str (reduce (fn [m [screen setting v]]
    (assoc-in m [screen setting] {:value v}))
   {}
   rows)))

(deftest the-first-load-makes-an-exact-copy-of-the-global-settings
 (let [g (support/temp-root)
   p (project-in g "p")]
  (settings/load! g)
  (settings/save! g :sampler "N_ADAPT" 450)
  (let [loaded (settings/load-project! p g)]
   (is (= (text-of g "settings.edn") (text-of p "settings.edn")))
   (is (= 450 (value-of loaded :sampler "N_ADAPT")))
   (is (= [] (:wiped (meta loaded))))
   (is (false? (:reset? (meta loaded)))))
  (testing "the global settings are made first when there are none"
   (let [g2 (support/temp-root)
     p2 (project-in g2 "q")]
    (settings/load-project! p2 g2)
    (is (some? (text-of g2 "settings.edn")))
    (is (= (text-of g2 "settings.edn") (text-of p2 "settings.edn")))))))

(deftest a-project-does-not-follow-later-changes-of-the-global-settings
 (let [g (support/temp-root)
   p (project-in g "p")]
  (settings/load-project! p g)
  (settings/save! g :sampler "N_ADAPT" 900)
  (let [loaded (settings/load-project! p g)]
   (testing "its own value is still what it was"
    (is (= 300 (value-of loaded :sampler "N_ADAPT"))))
   (testing "but what reset goes back to is the global value now"
    (is (= 900
      (get-in (settings/screen-entries loaded :sampler)
       ["N_ADAPT" :default])))))))

(deftest reset-goes-to-the-global-settings-not-the-defaults
 (let [g (support/temp-root)
   p (project-in g "p")]
  (settings/load! g)
  (settings/save! g :sampler "N_ADAPT" 450)
  (settings/save! g :plots "PLOT_COLOUR_MAP" :darkorange)
  (let [loaded (settings/load-project! p g)
    sampler (settings/screen-entries loaded :sampler)
    plots (settings/screen-entries loaded :plots)]
   (is (= 450 (get-in sampler ["N_ADAPT" :default]))
    "a setting the global ones changed")
   (is (= 700 (get-in sampler ["N_DRAWS" :default]))
    "a setting they did not is its default")
   (is (= :darkorange (get-in plots ["PLOT_COLOUR_MAP" :default])))
   (testing "while the global settings reset to the defaults"
    (is (= 300
      (get-in (settings/screen-entries (settings/load! g) :sampler)
       ["N_ADAPT" :default])))))))

(deftest an-invalid-value-goes-back-to-the-global-value
 (let [g (support/temp-root)
   p (project-in g "p")]
  (settings/load! g)
  (settings/save! g :sampler "N_ADAPT" 450)
  (settings/save! g :plots "PLOT_COLOUR_MAP" :darkorange)
  (spit (settings/settings-file p)
   (file-with [:sampler "N_ADAPT" 0]
    [:sampler "N_DRAWS" 900]
    [:plots "PLOT_COLOUR_MAP" :nope]
    [:sampler "RNG_SEED" 7]))
  (let [loaded (settings/load-project! p g)]
   (is (= 450 (value-of loaded :sampler "N_ADAPT"))
    "the global value, not the default 300")
   (is (= :darkorange (value-of loaded :plots "PLOT_COLOUR_MAP")))
   (is (= 900 (value-of loaded :sampler "N_DRAWS")) "a valid value stays")
   (is (= 7 (value-of loaded :sampler "RNG_SEED")))
   (is (= #{"N_ADAPT" "PLOT_COLOUR_MAP"}
     (set (map :setting (:wiped (meta loaded))))))
   (testing "the file was rewritten with the global values"
    (is (=
      {"N_ADAPT" 450, "N_DRAWS" 900, "PLOT_COLOUR_MAP" :darkorange, "RNG_SEED" 7}
      (saved-values p))))
   (testing "the log of the project says where it went"
    (let [log (text-of p "settings.log")]
     (is (str/includes? log "N_ADAPT: 0 is not valid"))
     (is (str/includes? log "reset to its global value 450"))
     (is (nil? (text-of g "settings.log")) "the global folder has nothing to log")))
   (testing "each wiped setting has a notice that says so"
    (is (= "reset to global" (get-in loaded [:sampler "N_ADAPT" :notice])))
    (is (nil? (get-in loaded [:sampler "N_DRAWS" :notice])))))))

(deftest a-wiped-value-at-the-global-default-goes-to-that-default
 (let [g (support/temp-root)
   p (project-in g "p")]
  (settings/load! g)
  (spit (settings/settings-file p) (file-with [:sampler "N_ADAPT" "x"]))
  (let [loaded (settings/load-project! p g)]
   (is (= 300 (value-of loaded :sampler "N_ADAPT")))
   (is (= [] (filter #(not= "N_ADAPT" (:setting %)) (:wiped (meta loaded))))))))

(deftest values-that-break-a-rule-together-go-back-to-the-global-ones
 (let [g (support/temp-root)
   p (project-in g "p")]
  (settings/load! g)
  (settings/save! g :model "SHELL_SAMPLE" 300)
  (spit (settings/settings-file p)
   (file-with [:model "SASA_N_OCC" 250] [:model "SHELL_SAMPLE" 100]))
  (let [loaded (settings/load-project! p g)]
   (is (= 300 (value-of loaded :model "SHELL_SAMPLE")))
   (is (= 104 (value-of loaded :model "SASA_N_OCC")))
   (is (= #{"SASA_N_OCC" "SHELL_SAMPLE"}
     (set (map :setting (:wiped (meta loaded)))))))))

(deftest a-project-file-that-cannot-be-read-is-replaced-by-the-global-settings
 (let [g (support/temp-root)
   p (project-in g "p")]
  (settings/load! g)
  (settings/save! g :sampler "N_ADAPT" 450)
  (doseq [bad ["{ not edn" "" "[1 2]" "nil" "42"]]
   (spit (settings/settings-file p) bad)
   (let [loaded (settings/load-project! p g)]
    (is (true? (:reset? (meta loaded))) (pr-str bad))
    (is (= bad (text-of p "settings.edn.corrupt")))
    (is (= 450 (value-of loaded :sampler "N_ADAPT")))
    (is (= (text-of g "settings.edn") (text-of p "settings.edn")))
    (is (str/includes? (text-of p "settings.log") "copy of the global settings"))
    (is (false? (:reset? (meta (settings/load-project! p g))))
     "and it reads again"))
   (.delete (settings/settings-file p)))))

(deftest a-save-in-a-project-is-checked-and-stays-in-the-project
 (let [g (support/temp-root)
   p (project-in g "p")
   global-before (do (settings/load! g) (text-of g "settings.edn"))]
  (settings/load-project! p g)
  (let [after (settings/save-project! p g :sampler "N_ADAPT" 500)]
   (is (= 500 (value-of after :sampler "N_ADAPT")))
   (is (= {"N_ADAPT" 500} (saved-values p))))
  (is (= global-before (text-of g "settings.edn")) "the global file did not change")
  (is (= 500 (value-of (settings/load-project! p g) :sampler "N_ADAPT")))
  (testing
   "a value that is not valid, or breaks a rule, is refused and nothing changes"
   (let [before (text-of p "settings.edn")]
    (doseq [[screen setting v]
      [[:sampler "N_ADAPT" 0] [:plots "PLOT_COLOUR_MAP" :nope]
       [:model "SASA_N_OCC" 9999] [:model "MODE_δρ₁₂" 50.0]]]
     (let [e (try (settings/save-project! p g screen setting v)
        nil
        (catch Exception e e))]
      (is (= ::settings/invalid (:type (ex-data e))) (str setting))
      (is (= before (text-of p "settings.edn")))))))))

(deftest a-project-save-takes-its-notice-away
 (let [g (support/temp-root)
   p (project-in g "p")]
  (settings/load! g)
  (spit (settings/settings-file p) (file-with [:sampler "N_ADAPT" 0]))
  (is (= "reset to global"
    (get-in (settings/load-project! p g) [:sampler "N_ADAPT" :notice])))
  (is (= "reset to global"
    (get-in (settings/load-project! p g) [:sampler "N_ADAPT" :notice]))
   "it stays until saved")
  (settings/save-project! p g :sampler "N_ADAPT" 400)
  (is (nil? (get-in (settings/load-project! p g) [:sampler "N_ADAPT" :notice])))))

(deftest notices-belong-to-their-own-settings-file
 (let [g (support/temp-root)
   p (project-in g "p")
   q (project-in g "q")]
  (settings/load! g)
  (spit (settings/settings-file p) (file-with [:sampler "N_ADAPT" 0]))
  (settings/load-project! p g)
  (testing "another project and the global settings do not show it"
   (is (nil? (get-in (settings/load-project! q g) [:sampler "N_ADAPT" :notice])))
   (is (nil? (get-in (settings/load! g) [:sampler "N_ADAPT" :notice]))))
  (testing "a global wipe is not shown in a project"
   (spit (settings/settings-file g) (file-with [:sampler "N_DRAWS" 0]))
   (settings/load! g)
   (is (= "reset to default"
     (get-in (settings/load! g) [:sampler "N_DRAWS" :notice])))
   (is (nil? (get-in (settings/load-project! q g) [:sampler "N_DRAWS" :notice]))))))

(deftest projects-are-independent
 (let [g (support/temp-root)
   a (project-in g "a")
   b (project-in g "b")]
  (settings/load-project! a g)
  (settings/load-project! b g)
  (settings/save-project! a g :sampler "N_ADAPT" 111)
  (settings/save-project! b g :sampler "N_ADAPT" 222)
  (is (= 111 (value-of (settings/load-project! a g) :sampler "N_ADAPT")))
  (is (= 222 (value-of (settings/load-project! b g) :sampler "N_ADAPT")))
  (is (= 300 (value-of (settings/load! g) :sampler "N_ADAPT")))))

(deftest a-bad-global-file-is-mended-by-a-project-load-too
 (let [g (support/temp-root)
   p (project-in g "p")]
  (spit (settings/settings-file g) (file-with [:sampler "N_ADAPT" -4]))
  (let [loaded (settings/load-project! p g)]
   (is (= 300 (value-of loaded :sampler "N_ADAPT")))
   (is (empty? (saved-values g)))
   (is (= (text-of g "settings.edn") (text-of p "settings.edn"))))))

(deftest a-project-file-of-many-bad-values-is-cleaned-in-one-load
 (let [g (support/temp-root)
   p (project-in g "p")
   rows [[:sampler "N_ADAPT" 0] [:sampler "N_DRAWS" "x"]
    [:sampler "N_CHAINS" -3]
    [:sampler "TARGET_ACCEPT" 100] [:output "VAL_SIGMA" 0]
    [:output "FIGURES_TEX" 1]
    [:output "FIGURES_FORMATS" []] [:plots "PLOT_COLOUR_MAP" "red"]
    [:plots "PLOT_TEXT_FONT" ""] [:sampler "CHAIN_START_RADII" [1 2]]
    [:plots "PLOT_PREVIEW_SIZE" {:width 0, :height 1}]
    [:plots "PLOT_COLOUR_BAND" [:red 9]]]]
  (settings/load! g)
  (spit (settings/settings-file p) (apply file-with rows))
  (let [loaded (settings/load-project! p g)]
   (is (= 12 (count (:wiped (meta loaded)))))
   (is (every? #(= (:default %) (settings/value %)) (mapcat vals (vals loaded))))
   (is (= 12 (count (str/split-lines (text-of p "settings.log"))))))))

(deftest a-project-load-stops-when-the-defaults-are-corrupt
 (let [g (support/temp-root)
   p (project-in g "p")]
  (binding [settings/*regenerate* (constantly false)
    settings/*read* (fn [] [{} []])]
   (is (thrown? clojure.lang.ExceptionInfo (settings/load-project! p g)))
   (is (thrown? clojure.lang.ExceptionInfo
     (settings/save-project! p g :sampler "N_ADAPT" 5)))
   (is (nil? (text-of p "settings.edn"))))))
