;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The audit fixes of 2026-11-03, package B: text that is wider than it looks (CJK, emoji)
;; never pushes a border out, a cap on typing is told instead of silent, a pasted path is
;; trimmed, and end of input in the main menu's name prompt ends the program.

(ns baysol.tui.screens.width-caps-test
 (:require
  [baysol.tui.add-flow :as flow]
  [baysol.tui.buffer :as buffer]
  [baysol.tui.models :as models]
  [baysol.tui.screens.form :as form]
  [baysol.tui.screens.landing :as landing]
  [baysol.tui.screens.main-menu :as main-menu]
  [baysol.tui.screens.models-menu :as models-menu]
  [baysol.tui.screens.page-load :as pgld]
  [baysol.tui.screens.picker :as picker]
  [baysol.tui.screens.project-menu :as project-menu]
  [baysol.tui.screens.recipes-menu :as recipes-menu]
  [baysol.tui.screens.sheets :as sheets]
  [baysol.tui.screens.solutes-menu :as solutes-menu]
  [baysol.tui.screens.table :as table]
  [baysol.tui.settings :as settings]
  [baysol.tui.support :as support :refer [background enter esc eof in-project]]
  [baysol.tui.text :as txt]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))

(def ^:private wide-names ["日本語日本語日本語日本語" "😀😀😀😀😀😀😀😀" "a日b😀c日日日日日日日日"])

;; --- F4: width-aware cells

(deftest cells-have-exactly-their-width
 (doseq [s wide-names
   w (range 4 16)
   align [:left :right :center]]
  (is (= w (txt/display-width (table/fit-cell s w align)))
   (str s " " w " " align))))

(deftest a-table-row-with-wide-names-keeps-the-art-width
 (let [art (table/parse-art
    ["   ╭─ t [   /   ] ──┬──────────╮"
     "   │     name       │   [mM]   │"
     "   ├────────────────┼──────────┤"
     "   │                │          │"
     "   ╰────────────────┴──────────╯"
     "   ╭──────────╮"
     "   │ quit: esc│"
     "   │ menu: ^x │"
     "   │          │"
     "   ╰──────────╯"])
   rows (mapv (fn [n] {:cells [n "10"]}) wide-names)
   {:keys [lines]} (table/frame art rows 0 0)]
  (is (seq lines))
  (is (every? #(= (txt/display-width (:template art)) (txt/display-width %))
    (take 3 (drop (count (:head art)) lines)))
   "every body row is as wide as the template")
  (is (every? #(<= (txt/display-width %) 80) lines))))

(deftest text-is-wrapped-and-tailed-by-width
 (doseq [s wide-names
   w (range 3 12)]
  (is (every? #(<= (txt/display-width %) w) (table/wrap-text (str s " " s) w))
   (str s w))
  (is (<= (txt/display-width (table/tail-text s w)) w))))

(deftest page-text-writes-by-cells
 (let [line (apply str (repeat 30 \x))]
  (doseq [s wide-names]
   (is (= 30 (txt/display-width (pgld/put-text line 5 10 s))))
   (is (= 30 (txt/display-width (first (pgld/stamp [line] 0 5 15 s))))))
  (is (= 30
    (txt/display-width
     (pgld/put-text (pgld/put-text line 5 8 "日本語") 15 8 "😀"))))))

(deftest a-form-cell-with-wide-text-keeps-the-art-width
 (let [fart ["  ╭─ tiny ───────────╮"
    "  │ a  │ value       │"
    "  ├────┼─────────────┤"
    "  │ b  │ x           │"
    "  ├────┴─────────────┤"
    "  │ BAYSOL will use  │"
    "  │                  │"
    "  │                  │"
    "  ╰──────────────────╯"
    "  [ footer ]"]
   a (form/parse-art fart)
   lines (form/frame a
    {:cells {[3 0] "日本語日本語日本語日本語日本語",
      [3 1] "😀😀😀😀😀😀😀😀😀😀😀😀😀😀"},
     :note "日本語日本語日本語日本語日本語日本語日本語日本語",
     :preview ["日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語"]})]
  (is (every? #(= (txt/display-width (first fart)) (txt/display-width %))
    (take 9 lines)))))

(deftest a-dropdown-with-wide-names-keeps-its-width
 (let [st (picker/initial wide-names nil)
   {:keys [texts]} (picker/layout st 6 30)]
  (is (every? #(<= (txt/display-width %) 30) texts))
  (is (every? #(= 30 (txt/display-width (pgld/put-text "" 0 30 %))) texts))
  (is (<= (txt/display-width (picker/typed-text {:buffer (apply str wide-names)}
      20))
    20)))
 (doseq [s wide-names]
  (is (= 40 (txt/display-width (flow/item-text {:name s, :tag "solute"} 40)))
   "the add-flow dropdown line, tag at the right")))

(deftest the-prompts-with-wide-text
 (is (<= (txt/display-width (models-menu/typed-path (apply str wide-names))) 42))
 (is (<= (txt/display-width (main-menu/typed-name (apply str wide-names))) 40))
 (let [box (landing/prompt-box "t" 40 {:text (apply str wide-names), :error nil})]
  (is (every? #(= 40 (txt/display-width %)) box))))

;; --- F5: caps are told

(deftest a-name-over-the-cap-is-told-not-cut
 (let [full (apply str (repeat 40 "a"))
   r (landing/prompt-step {:text full, :error nil} \b (constantly nil) 40)]
  (is (= full (get-in r [:state :text])) "nothing is added")
  (is (= "name too long (40 at most)" (get-in r [:state :error])))
  (testing "a key that takes a letter back clears it"
   (let [r2 (landing/prompt-step (:state r) KeyType/Backspace (constantly nil) 40)]
    (is (nil? (get-in r2 [:state :error])))
    (is (= 39 (count (get-in r2 [:state :text]))))))))

(deftest the-recipes-prompt-tells-the-cap
 (support/with-data-folder
  [_root (support/temp-root)]
  (let [[_ text] (apply support/run-keys!
     #(recipes-menu/show! % background)
     (concat [:ctrl-n] (repeat 41 \a) [eof]))]
   (is (str/includes? text "name too long (40 at most)")))))

(deftest a-cell-name-over-the-cap-is-told
 (let [full (apply str (repeat form/max-typed "x"))
   st {:edit {:text full}}
   r (form/type-edit st \y)]
  (is (= full (get-in r [:edit :text])))
  (is (= (txt/too-long "text" form/max-typed) (:note r)))
  (is (= "abc" (get-in (form/type-edit {:edit {:text "ab"}} \c) [:edit :text]))
   "below the cap it types")))

(deftest the-solute-name-dropdown-tells-the-cap
 (let [full (apply str (repeat 60 "q"))
   p (assoc (flow/name-pick-initial :nonbio []) :buffer full)
   r (flow/name-pick-step p \z)]
  (is (= full (get-in r [:state :buffer])))
  (is (= "name too long (60 at most)" (get-in r [:state :error])))))

(defn ^:private sampler-sheet
 []
 [(sheets/load-sheet "sampler-settings")
  (settings/screen-entries (settings/merge-defaults (settings/read-defaults) nil)
   :sampler)])

(defn ^:private press-sheet
 [[sheet entries] & inputs]
 (reduce (fn [st input]
   (let [r (sheets/step sheet st input)]
    (if (keyword? r) (reduced r) (:state r))))
  (sheets/initial-state entries
   (fn [_ _] [])
   (constantly nil)
   (settings/read-relations))
  inputs))

(deftest a-number-past-the-cap-is-refused-visibly
 (let [sh (sampler-sheet)
   typed (concat [KeyType/Enter] (repeat 3 KeyType/Backspace) (repeat 20 \9))
   st (apply press-sheet sh typed)]
  (is (= 16 (count (get-in st [:edit :buffer]))) "16 kept, no more")
  (is (= "16 digits at most" (get-in st [:edit :error])) "and the cell says so")
  (testing "Enter on 16 digits is refused, not saved as a different number"
   (let [st2 (apply press-sheet sh (concat typed [enter]))]
    (is (= "15 digits at most" (get-in st2 [:edit :error])))
    (is (empty? (:drafts st2))))))
 (testing "15 digits are fine, 21 digits that overflow a long are refused"
  (is (= {:value 123456789012345}
    (sheets/parse-value :int "123456789012345" {:at-least 1})))
  (is (= {:error "15 digits at most"}
    (sheets/parse-value :int "9223372036854775808" {:at-least 1})))
  (is (= {:value 7} (sheets/parse-value :int "0000000000000000007" {:at-least 1}))
   "leading zeros are no digits")))

;; --- F14: pasted paths are trimmed

(deftest a-path-with-blanks-around-it-is-used
 (in-project
  (fn [_root dir]
   (let [pdb (io/file (support/temp-root) "pasted.pdb")]
    (spit pdb "ATOM")
    (doseq [pad [" " "  " "\t"]]
     (let [vs (support/virtual-screen)]
      (support/feed! vs (str (.getAbsolutePath pdb) pad) enter esc)
      (is (= :done
        (models-menu/show! (:screen vs)
         background
         (get project-menu/pages :page1)
         dir)))
      (is (= ["pasted.pdb"] (models/list-models dir)) (pr-str pad))
      (io/delete-file (io/file dir "models" "pasted.pdb"))))))))

(deftest a-sequence-path-with-blanks-around-it-is-used
 (in-project
  (fn [_root dir]
   (let [fa (io/file (support/temp-root) "p.fa")]
    (spit fa ">p1\nMKTAYIAKQR\n")
    (let [[_ _] (support/run-keys! #(solutes-menu/show! % background dir)
       :ctrl-f
       (str (.getAbsolutePath fa) "  ")
       enter
       "0.02"
       enter
       "0.002"
       enter
       :ctrl-w
       :ctrl-x
       eof)]
     (is (= ["p1"] (mapv :name (buffer/read-solutes dir)))))))))

;; --- F16: end of input in the name prompt

(deftest end-of-input-in-the-name-prompt-quits
 (support/with-data-folder
  [_root (support/temp-root)]
  (let [ask-name! @#'main-menu/ask-name!
    vs (support/virtual-screen)]
   (support/feed! vs "ab" eof)
   (is (= :quit (ask-name! (:screen vs))))
   (let [vs (support/virtual-screen)]
    (support/feed! vs "ab" esc)
    (is (nil? (ask-name! (:screen vs))) "Escape still only cancels")))))

(deftest end-of-input-in-the-project-list-quits
 (support/with-data-folder
  [_root (support/temp-root)]
  (let [pick-project! @#'main-menu/pick-project!
    vs (support/virtual-screen)]
   (support/feed! vs eof)
   (is (= :quit (pick-project! (:screen vs) ["a" "b"]))))))
