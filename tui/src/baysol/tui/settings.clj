;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The settings of the user: the application-wide `settings.edn` in the BAYSOL folder and
;; the defaults it starts from. The defaults are the bundled `default_settings.edn`
;; (harvested from the Params.jl files by `bb harvest-defaults`): screen -> setting name ->
;; `{:page :default :type :limits}` (and `:choices` for a choice setting, `:shape` for a
;; tuple, the kinds of its parts as the Julia constant has them), with the rules
;; that tie settings together in `setting_relations.edn`. The file of the user has the same
;; shape, and an entry there that was saved carries a `:value`; an entry without one
;; stands at its `:default`.
;;
;; Nothing illegal is kept (`baysol.tui.validate` is the check):
;; - The defaults are checked first. If they are corrupt (unreadable, a default that breaks
;;   its own type, limits or rules) the harvest is run again and they are read and checked
;;   once more; if they are still corrupt there is no settings and an exception says so.
;; - Every load checks every saved value, and the rules over all of them. A value that is
;;   not valid is wiped: the setting goes back to its default, the file is rewritten
;;   without it, a line says so in `settings.log`, and the setting carries a `:notice` that
;;   the sheets show until it is saved again. A file that cannot be read at all is kept
;;   as `settings.edn.corrupt` and replaced by a copy of the defaults.
;; - A save is checked before it is written, and refused if the value is not valid.
;; The file is made by copying the defaults the first time it is needed, and a save
;; rewrites it through a temporary file that replaces it in one step, so a crash cannot
;; leave half a file.

(ns baysol.tui.settings
 (:require [baysol.tui.core.app :as app]
  [baysol.tui.validate :as validate]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.java.shell :as shell]
  [clojure.string :as str])
 (:import (java.nio.file Files StandardCopyOption)
  (java.time Instant)))

(def ^:private screens [:sampler :model :output :plots])

(def ^:private entry-keys
 [:page :default :type :limits :choices :shape :parts :value])

(def ^:private types #{:int :float :bool :colour :font :set :tuple})

(def ^:private limit-keys #{:above :below :at-least :at-most})

(def ^:private relation-rules
 #{:inside :within_width :ordered :all_above :at_most_setting :opacity})

(defn ^:private resource-text
 "The text of the bundled resource `resource`."
 [resource]
 (slurp (io/resource resource) :encoding "UTF-8"))

(defn read-defaults
 "The bundled defaults, as the map `default_settings.edn` holds."
 []
 (edn/read-string (resource-text "default_settings.edn")))

(defn read-relations
 "The bundled rules that tie settings together, a vector of maps (`setting_relations.edn`)."
 []
 (edn/read-string (resource-text "setting_relations.edn")))

(defn settings-file
 "The settings file (a File) in the BAYSOL folder `root`."
 [root]
 (io/file root "settings.edn"))

(defn ^:private log-file [root] (io/file root "settings.log"))

;; --- are the defaults sound

(defn ^:private entry-problems
 "What is wrong with the defaults entry `entry` of `setting`, as a vector of sentences."
 [setting entry]
 (let [problem #(str setting ": " %)]
  (if-not (map? entry)
   [(problem "its entry is not a map")]
   (let [{:keys [page limits choices default], kind :type} entry]
    (cond
     (not (and (integer? page) (pos? page))) [(problem "it has no page number")]
     (not (contains? types kind)) [(problem (str "it has no known type: "
        (pr-str kind)))]
     (not (and (map? limits) (every? limit-keys (keys limits))))
     [(problem "its limits are not a map of limits")]
     (and (= kind :set)
      (not (and (sequential? choices) (seq choices) (every? keyword? choices))))
     [(problem "its choices are missing")]
     (not (contains? entry :default)) [(problem "it has no default")]
     (and (= kind :tuple) (not= (:shape entry) (validate/shape-of default)))
     [(problem (str "its default " (pr-str default)
        " is not of the shape "
        (pr-str (:shape entry))))]
     (and (= kind :tuple)
      (not (and (sequential? (:parts entry))
        (every? string? (:parts entry))
        (= (count (:parts entry)) (count (:shape entry))))))
     [(problem "it has no name for each of its parts")]
     :else (let [{:keys [error]} (validate/check entry default)]
      (if error
       [(problem (str "its default " (pr-str default) " " error))]
       [])))))))

(defn defaults-problems
 "What is wrong with the defaults `defaults` and the rules `relations`, as a vector of
 sentences; empty when they are sound: every setting has a page, a type, limits and a
 default that keeps them, the pages of a screen differ, and the defaults keep the rules."
 [defaults relations]
 (cond
  (not (and (map? defaults) (seq defaults) (every? map? (vals defaults))))
  ["the defaults are not a map of screens"]

  (not (and (sequential? relations) (every? map? relations)))
  ["the rules are not a list of maps"]

  :else
  (let [entries
    (for [[screen es] defaults [setting entry] es] [screen setting entry])
    per-entry (vec (mapcat (fn [[_ setting entry]]
       (entry-problems setting entry))
      entries))
    names (set (map second entries))
    shared (for [[screen es] defaults
      :let [pages (keep (comp :page val) es)]
      :when (not= (count pages) (count (set pages)))]
     (str "two settings share a page on " (name screen)))
    rule-problems
    (vec (for [r relations
       :let [bad (cond (not (contains? relation-rules (:rule r)))
         (str "an unknown rule " (pr-str (:rule r)))
         (not (contains? names (:setting r)))
         (str "a rule names "
          (pr-str (:setting r))
          ", which is no setting")
         (and (:of r) (not (contains? names (:of r))))
         (str "a rule names "
          (pr-str (:of r))
          ", which is no setting"))]
       :when bad]
      bad))]
   (if (seq per-entry)
    per-entry
    (vec (concat shared
      rule-problems
      (when (empty? rule-problems)
       (let [values (into {}
          (for [[_ setting entry] entries]
           [setting (:default entry)]))]
        (for [{:keys [setting reason]}
          (validate/check-relations relations values)]
         (str "the defaults break a rule: " setting " " reason))))))))))

(defn regenerate-defaults!
 "Runs the harvest again (`dev/harvest_defaults.jl` of the BAYSOL package the TUI runs
 from), which rewrites `default_settings.edn` and its companions from the Params.jl files.
 True if it ran and succeeded; false when there is no package to run it from, no Julia, or
 it failed."
 []
 (try (boolean
   (when-let [root (app/repo-root)]
    (let [script (io/file root "dev" "harvest_defaults.jl")]
     (and (.isFile script)
      (zero? (:exit (shell/sh (or (System/getenv "JULIA") "julia")
         "--startup-file=no"
         (str "--project=" root)
         (str script))))))))
  (catch Exception _ false)))

;; What runs the harvest; a test replaces it.
(def ^:dynamic *regenerate* regenerate-defaults!)

(def ^:dynamic *read*
 "What reads the defaults and the rules, `[defaults relations]`: the bundled files. A test
 replaces it with something corrupt."
 (fn [] [(read-defaults) (read-relations)]))

(defn ^:private sound-defaults
 "`[defaults relations]` as the bundled files give them when they are sound, else nil."
 []
 (try (let [[defaults relations] (*read*)]
   (when (empty? (defaults-problems defaults relations)) [defaults relations]))
  (catch Exception _ nil)))

(defn ensure-defaults!
 "`[defaults relations]`, the bundled defaults and rules once they are known to be sound.
 When they are not, the harvest is run again (`*regenerate*`) and they are read and checked
 once more.

 Throws an exception (`:type ::defaults-corrupt`) if they are still not sound."
 []
 (or (sound-defaults)
  (do (*regenerate*) (sound-defaults))
  (throw (ex-info "the default settings are corrupt and could not be made again"
    {:type ::defaults-corrupt}))))

;; --- the settings, merged and checked

(defn merge-defaults
 "The settings `stored` (as read from a settings file, or nil) brought up to the
 `defaults`: the entries of the defaults, each with the `:value` it has in `stored`, if
 any. Entries only `stored` has are dropped. Nothing is checked here."
 [defaults stored]
 (into {}
  (for [[screen entries] defaults]
   [screen
    (into {}
     (for [[setting entry] entries
       :let [saved (get-in stored [screen setting :value])]]
      [setting (if (some? saved) (assoc entry :value saved) entry)]))])))

(defn value
 "The value of the settings entry `entry`: the saved one, else the default."
 [entry]
 (if (contains? entry :value) (:value entry) (:default entry)))

(defn ^:private effective-values
 "Every setting's value, `{setting value}`, across the screens of `settings`."
 [settings]
 (into
  {}
  (for [[_ entries] settings [setting entry] entries] [setting (value entry)])))

(defn ^:private checked-entry
 "The entry `entry` with the saved value that `raw` (what the file has for it) holds, if
 that is valid: `[entry' nil]`, or `[entry reason]` with the reason it was not kept."
 [entry raw]
 (cond (not (map? raw)) [entry "its entry is not a map"]
  (not (contains? raw :value)) [entry nil]
  :else (let [{kept :value, :keys [error]} (validate/check entry (:value raw))]
   (if error [entry error] [(assoc entry :value kept) nil]))))

(defn ^:private broken-saved
 "The saved values to wipe so that the rules hold: `[[screen setting reason] ...]` for each
 setting of a broken rule of `relations`, in the values of `settings`, that has a saved
 value."
 [relations settings]
 (let [broken (validate/check-relations relations (effective-values settings))
   involved (distinct (for [{:keys [relation reason]} broken
      s [(:setting relation) (:of relation)]
      :when s]
     [s reason]))]
  (for [[s reason] involved
    [screen entries] settings
    :when (contains? (get entries s) :value)]
   [screen s reason])))

(defn wipe-invalid
 "The checked settings made from the `stored` file contents: `{:settings s :wiped w}`.
 Every saved value is checked (`validate/check`) and kept, in its right type, or wiped;
 then the rules over all the values are checked, and the saved values of the settings of
 a broken rule are wiped too. `w` lists each wipe as `{:screen :setting :value :reason}`.

 A wiped setting goes back to its default, or, when `baseline` (`{screen {setting value}}`)
 is given, to its value there: the settings of a project go back to the global settings.
 (A rule still broken after that sends the setting to its default after all.)"
 ([defaults relations stored] (wipe-invalid defaults relations stored nil))
 ([defaults relations stored baseline]
  (let [wipes (atom [])
    wipe! (fn [screen setting v reason]
     (swap! wipes conj
      {:screen screen, :setting setting, :value v, :reason reason}))
    wiped-entry
    (fn [entry screen setting n]
     (let [back (get-in baseline [screen setting] ::none)]
      (if (and (not= back ::none) (< n 2) (not= back (:value entry)))
       (assoc entry :value back)
       (dissoc entry :value))))
    first-pass
    (into {}
     (for [[screen entries] defaults]
      [screen
       (into {}
        (for [[setting entry] entries
          :let [raw (get-in stored [screen setting] ::none)]]
         [setting
          (if (= raw ::none)
           entry
           (let [[kept reason] (checked-entry entry raw)]
            (if reason
             (do (wipe! screen setting (:value raw raw) reason)
              (wiped-entry entry screen setting 0))
             kept)))]))]))
    settled (loop [settings first-pass
      n 0]
     (let [saved (broken-saved relations settings)]
      (if (or (empty? saved) (> n 3))
       settings
       (recur (reduce
         (fn [st [screen s reason]]
          (wipe! screen s (get-in st [screen s :value]) reason)
          (update-in st [screen s] wiped-entry screen s n))
         settings
         saved)
        (inc n)))))]
   {:settings settled, :wiped @wipes})))

;; The notices of the session: `{[scope screen setting] message}` for each setting that was
;; wiped and not saved since; the sheets show them. A scope is the folder of a settings
;; file (the BAYSOL folder, or a project's), as text.
(defonce ^:private notices (atom {}))

(defn reset-notices!
 "Forgets the notices of the session, so a test starts clean."
 []
 (reset! notices {}))

(defn ^:private with-notices
 "`settings` with the `:notice` of each setting that has one in the scope `scope` (the
 folder the settings file is in, as text)."
 [settings scope]
 (reduce-kv (fn [s [sc screen setting] message]
   (if (and (= sc scope) (get-in s [screen setting]))
    (assoc-in s [screen setting :notice] message)
    s))
  settings
  @notices))

(defn ^:private without-notice
 "`settings` without the `:notice` of `setting` on `screen`."
 [settings screen setting]
 (update-in settings [screen setting] dissoc :notice))

(defn ^:private entry-text
 "The text of a settings entry in the file: one line, its keys in a fixed order."
 [entry]
 (str "{"
  (str/join ", "
   (for [k entry-keys
     :when (contains? entry k)]
    (str k " " (pr-str (get entry k)))))
  "}"))

(defn ^:private settings-text
 "The text of the settings file for the settings map `settings`: screens in the fixed
 order, the entries of each in page order."
 [settings]
 (str
  ";; The settings of the user. Each entry is a setting of the settings screens; a\n"
  ";; `:value` is what was saved, an entry without one stands at its `:default`.\n\n{\n"
  (str/join "\n"
   (for [screen screens
     :let [entries (sort-by (comp :page val) (get settings screen))]
     :when (seq entries)]
    (str " "
     screen
     "\n {\n"
     (str/join "\n"
      (for [[setting entry] entries]
       (str "  " (pr-str setting) " " (entry-text entry))))
     "\n }\n")))
  "}\n"))

(defn ^:private write!
 "Writes `settings` as the settings file of the BAYSOL folder `root`, through a temporary
 file that replaces it in one step."
 [root settings]
 (let [file (settings-file root)
   tmp (io/file (.getParentFile file) "settings.edn.tmp")]
  (io/make-parents file)
  (spit tmp (settings-text settings) :encoding "UTF-8")
  (Files/move (.toPath tmp)
   (.toPath file)
   (into-array StandardCopyOption
    [StandardCopyOption/REPLACE_EXISTING
     StandardCopyOption/ATOMIC_MOVE]))))

(defn ^:private log!
 "Adds the lines `lines` to `settings.log` in the BAYSOL folder `root`, each with the time."
 [root lines]
 (when (seq lines)
  (io/make-parents (log-file root))
  (spit (log-file root)
   (apply str (for [l lines] (str (Instant/now) " " l "\n")))
   :append true
   :encoding "UTF-8")))

(defn ^:private wipe-line
 "The line of the log for one wipe: what was wiped and what it went back to. `back-of` is a
 function of a screen and a setting that gives that value, and `target` says what it is
 (`default` or `global value`)."
 [back-of target {:keys [screen setting reason], wiped :value}]
 (str setting
  ": " (pr-str wiped)
  " is not valid (" reason
  "); reset to its " target
  " "
  (pr-str (back-of screen setting))))

(defn ^:private read-stored
 "The settings file of `root` read as EDN: its map, nil if there is no file, or
 `::unreadable` if it cannot be read or is not a map."
 [root]
 (let [file (settings-file root)]
  (when (.isFile file)
   (let [stored (try (edn/read-string (slurp file :encoding "UTF-8"))
      (catch Exception _ ::unreadable))]
    (if (map? stored) stored ::unreadable)))))

(defn load!
 "The settings of the user, merged with the defaults and checked, from the BAYSOL folder
 `root`: `{screen {setting entry}}`, an entry having its `:value` when one is saved and
 valid, and a `:notice` when its saved value was wiped. The file is made first, as a copy
 of the bundled defaults, if it is missing.

 The defaults are checked first (`ensure-defaults!`; throws if they are corrupt and cannot
 be made again). An invalid saved value is wiped and the file rewritten without it; a file
 that cannot be read is kept as `settings.edn.corrupt` and replaced by a copy of the
 defaults. Both are in `settings.log`. The metadata of the result has `:wiped` (the wipes
 of this load, see `wipe-invalid`) and `:reset?` (true if the file was unreadable)."
 [root]
 (let [[defaults relations] (ensure-defaults!)
   stored (read-stored root)
   scope (str root)]
  (cond
   (nil? stored)
   (do (io/make-parents (settings-file root))
    (spit (settings-file root)
     (resource-text "default_settings.edn")
     :encoding
     "UTF-8")
    (with-meta (with-notices (merge-defaults defaults nil) scope)
     {:wiped [], :reset? false}))

   (= stored ::unreadable)
   (do
    (Files/copy (.toPath (settings-file root))
     (.toPath (io/file root "settings.edn.corrupt"))
     (into-array StandardCopyOption
      [StandardCopyOption/REPLACE_EXISTING]))
    (write! root (merge-defaults defaults nil))
    (log!
     root
     ["settings.edn could not be read; kept as settings.edn.corrupt,"
      "replaced by the defaults"])
    (with-meta (with-notices (merge-defaults defaults nil) scope)
     {:wiped [], :reset? true}))

   :else
   (let [{:keys [settings wiped]} (wipe-invalid defaults relations stored)]
    (when (seq wiped)
     (write! root settings)
     (log! root
      (map
       #(wipe-line (fn [sc st] (get-in defaults [sc st :default])) "default" %)
       wiped))
     (swap! notices into
      (for [{:keys [screen setting]} wiped]
       [[scope screen setting] "reset to default"])))
    (with-meta (with-notices settings scope) {:wiped wiped, :reset? false})))))

(defn ^:private baseline-of
 "`{screen {setting value}}`: the value of every setting in `settings`, saved or default."
 [settings]
 (into {}
  (for [[screen entries] settings]
   [screen
    (into {} (for [[setting entry] entries] [setting (value entry)]))])))

(defn ^:private with-reset
 "`settings` with, on every entry, the `:reset` value `baseline` has for it: what ctrl-r
 sends the setting to."
 [settings baseline]
 (into {}
  (for [[screen entries] settings]
   [screen
    (into {}
     (for [[setting entry] entries]
      [setting
       (assoc entry :reset (get-in baseline [screen setting]))]))])))

(defn load-project!
 "The settings of the project whose folder is `project-root`, checked like the global
 ones (`load!`) but with the global settings of the BAYSOL folder `global-root` as the
 baseline: the project's file is made, as an exact copy of the global `settings.edn`, the
 first time; a saved value that is not valid is wiped back to its **global** value, not to
 the default; and every entry has a `:reset` value, its global value, which ctrl-r goes
 back to. A project's settings do not follow later changes of the global ones. The
 metadata has `:wiped` and `:reset?` as `load!` has.

 Throws what `load!` throws for the global settings (corrupt defaults that cannot be made
 again)."
 [project-root global-root]
 (let [global (load! global-root)
   [defaults relations] (ensure-defaults!)
   baseline (baseline-of global)
   scope (str project-root)
   copy-global! #(do (io/make-parents (settings-file project-root))
    (Files/copy (.toPath (settings-file global-root))
     (.toPath (settings-file project-root))
     (into-array
      StandardCopyOption
      [StandardCopyOption/REPLACE_EXISTING])))
   stored (read-stored project-root)
   reset? (= stored ::unreadable)]
  (when (nil? stored) (copy-global!))
  (when reset?
   (Files/copy (.toPath (settings-file project-root))
    (.toPath (io/file project-root "settings.edn.corrupt"))
    (into-array StandardCopyOption
     [StandardCopyOption/REPLACE_EXISTING]))
   (copy-global!)
   (log! project-root
    ["settings.edn could not be read; kept as settings.edn.corrupt,"
     "replaced by a copy of the global settings"]))
  (let [stored (read-stored project-root)
    {:keys [settings wiped]} (wipe-invalid defaults relations stored baseline)]
   (when (seq wiped)
    (write! project-root settings)
    (log! project-root
     (map #(wipe-line (fn [sc st] (get-in baseline [sc st])) "global value" %)
      wiped))
    (swap! notices into
     (for [{:keys [screen setting]} wiped]
      [[scope screen setting] "reset to global"])))
   (with-meta (-> settings
     (with-notices scope)
     (with-reset baseline))
    {:wiped wiped, :reset? reset?}))))

(defn ^:private save-in!
 "Saves `v` as the value of `setting` on `screen` into `loaded`, the settings just loaded
 from the folder `root`, and writes them there: the work of `save!` and `save-project!`."
 [root loaded screen setting v]
 (let [entry (get-in loaded [screen setting])
   fail (fn [reason]
    (throw (ex-info (str setting " " reason)
      {:type ::invalid,
       :screen screen,
       :setting setting,
       :reason reason})))]
  (when-not entry (fail "is not a setting"))
  (let [{kept :value, :keys [error]} (validate/check entry v)]
   (when error (fail error))
   (let [updated (assoc-in loaded [screen setting :value] kept)
     [_ relations] (ensure-defaults!)
     broken (filter #(contains? #{(:setting (:relation %)) (:of (:relation %))}
       setting)
      (validate/check-relations relations
       (effective-values updated)))]
    (when (seq broken) (fail (:reason (first broken))))
    (write! root updated)
    (swap! notices dissoc [(str root) screen setting])
    (without-notice updated screen setting)))))

(defn save!
 "Saves `v` as the value of `setting` on `screen` in the settings file of the BAYSOL
 folder `root`, and returns the settings as they are now. The value is checked first, with
 the rules over all the settings, and nothing is written if it is not valid. Only that
 entry changes, and its notice, if any, goes.

 Throws an exception (`:type ::invalid`, with `:setting` and `:reason`) for a value that is
 not valid or a setting that does not exist."
 [root screen setting v]
 (save-in! root (load! root) screen setting v))

(defn save-project!
 "Like `save!`, for the settings of the project whose folder is `project-root` (see
 `load-project!`; `global-root` is the BAYSOL folder)."
 [project-root global-root screen setting v]
 (save-in! project-root (load-project! project-root global-root) screen setting v))

(defn screen-values
 "The values on `screen` (`:sampler`, ...) of `settings` as `{name {:value v :type t}}`."
 [settings screen]
 (into {}
  (for [[setting entry] (get settings screen)]
   [setting {:value (value entry), :type (:type entry)}])))

(defn screen-entries
 "The settings on `screen` of `settings` as `{name {:saved v :default d :type t
 :limits l :choices c :shape s :parts p :notice n}}`: what the sheets edit. `:default` is
 what ctrl-r goes back to: the default, or for a project's settings the entry's `:reset`,
 its global value."
 [settings screen]
 (into {}
  (for [[setting entry] (get settings screen)]
   [setting
    {:saved (value entry),
     :default (get entry :reset (:default entry)),
     :type (:type entry),
     :limits (:limits entry),
     :choices (:choices entry),
     :shape (:shape entry),
     :parts (:parts entry),
     :notice (:notice entry)}])))

;; --- how a value reads in the value cell of a page

(def ^:private cell-width
 "The characters of a value that fit the value cell of a page (19 wide: a space, then
 the value, and a column kept for the mark of an unsaved value)."
 17)

(defn ^:private plain
 "The text of one value `v`: a keyword without its colon, anything else as it prints."
 [v]
 (if (keyword? v) (name v) (str v)))

(defn format-value
 "The text of `v` for the value cell of a page, at most 17 characters: a colour name
 without its colon, a tuple in parentheses with its parts separated by `, `, and a text
 that is too long cut short with `…`."
 [v]
 (let [s (cond (map? v) (str "(" (str/join ", " (map plain (vals v))) ")")
    (sequential? v) (str "(" (str/join ", " (map plain v)) ")")
    :else (plain v))]
  (if (> (count s) cell-width) (str (subs s 0 (dec cell-width)) "…") s)))
