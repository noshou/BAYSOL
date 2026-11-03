;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The solutes screen run for real on a virtual terminal: the add flow of every kind of
;; solute (what is drawn and what is saved), cancelling at each stage, editing, removing,
;; saving, and what leaving does. A frame in the middle of a flow is read by ending the keys
;; with the terminal going away (`EOF`), which makes the screen return with the frame it
;; drew last, so no test waits for a key that was not fed.

(ns baysol.tui.screens.solutes-menu-test
 (:require [baysol.tui.buffer :as buffer]
  [baysol.tui.custom-store :as custom-store]
  [baysol.tui.file-picker :as file-picker]
  [baysol.tui.projects :as projects]
  [baysol.tui.screens.solutes-menu :as solutes-menu]
  [baysol.tui.support :as support :refer
   [background enter esc down up eof in-project]]
  [clojure.edn :as edn]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]])
 (:import (com.googlecode.lanterna.input KeyType)))


(def ^:private tab KeyType/Tab)

(defn ^:private bs [n] (vec (repeat n KeyType/Backspace)))

(def ^:private fixture
 (:solutes (edn/read-string (slurp (io/file
     "../test/fixtures/buffer/buffer.edn")))))

(defn ^:private fixture-row
 [row-name]
 (first (filter #(= row-name (:name %)) fixture)))

(defn ^:private run!-keys
 "Runs the screen for `dir` with `inputs` fed, in order (a string is each of its
 characters, a vector its keys); returns what it returned and the text it ended on. A
 screen still waiting for a key after 20 seconds is given escapes and the result is
 `:timeout`."
 [dir & inputs]
 (apply support/run-keys! #(solutes-menu/show! % background dir) inputs))

(defn ^:private snap-staged
 "Like `snap`, but the keys `after` are fed only `pause-ms` after `before` (the desktop's
 file picker throws away the keys that are waiting when it closes, as it must)."
 [dir before pause-ms after]
 (let [vs (support/virtual-screen)
   f (future (solutes-menu/show! (:screen vs) background dir))]
  (apply support/feed! vs before)
  (Thread/sleep (long pause-ms))
  (apply support/feed! vs (concat after [eof]))
  (when (= :timeout (deref f 20000 :timeout))
   (support/feed! vs esc esc esc esc eof)
   (deref f 3000 nil))
  (str/split-lines (support/screen-text vs))))

(defn ^:private lines-of [text] (str/split-lines text))

(defn ^:private snap
 "The lines of the frame the screen shows after `inputs`, a flow possibly still open."
 [dir & inputs]
 (lines-of (second (apply run!-keys dir (concat inputs [eof])))))

(defn ^:private frame-ok?
 "Whether the table's frame is whole: the left and right border of every table row and
 every line 80 characters wide."
 [lines]
 (and (= 24 (count lines))
  (every? #(= 80 (count %)) lines)
  (every? #(and (= \║ (.charAt ^String (nth lines %) 3))
    (= \║ (.charAt ^String (nth lines %) 78)))
   (range 2 18))))

(defn ^:private has? [lines s] (some #(str/includes? % s) lines))

(defn ^:private line-of
 [lines s]
 (first (keep-indexed #(when (str/includes? %2 s) %1) lines)))

(defn ^:private write-file
 [folder fname text]
 (let [f (io/file folder fname)]
  (spit f text)
  (str f)))

(deftest numbers
 (is (= "200" (solutes-menu/format-number 200.0)))
 (is (= "0.00001" (solutes-menu/format-number 1.0E-5)))
 (is (= "684.6" (solutes-menu/format-number 684.6)))
 (is (= "" (solutes-menu/format-number nil)))
 (is (= {:value 0.5} (solutes-menu/parse-field :sigma-mM " 0.5 ")))
 (is (= {:value 1.0E-5} (solutes-menu/parse-field :mM "1e-5")))
 (is (:error (solutes-menu/parse-field :mM "0")))
 (is (:error (solutes-menu/parse-field :mM "abc")))
 (is (:error (solutes-menu/parse-field :mM "NaN")))
 (is (:error (solutes-menu/parse-field :sigma-mM "-1")))
 (is (= {:value 0.0} (solutes-menu/parse-field :sigma-mM "0")))
 (is (:error (solutes-menu/parse-field :name "  "))))

(def ^:private tris-arg "2-amino-2-(hydroxymethyl)propane-1,3-diol")

(deftest the-screen-runs
 (in-project
  (fn [_root dir]
   (testing "an empty buffer says so, leaves with ctrl-x and escape"
    (let [[r text] (run!-keys dir :ctrl-x)]
     (is (= :back r))
     (is (str/includes? text "no solutes: ^n ^p ^f ^e"))
     (is (str/includes? text "[  0/0  ]")))
    (is (= :quit (first (run!-keys dir esc)))))
   (testing "^n adds a solute from the dropdown; it is a draft until ^w"
    (let [[r text] (run!-keys dir
       :ctrl-n
       "tris" enter
       "10" enter
       "0.5" enter
       :ctrl-x
       enter)]
     (is (= :back r))
     (is (str/includes? text "*tris"))
     (is (str/includes? text "n/a"))
     (is (str/includes? text "[  1/1  ]")))
    (is (= [] (buffer/read-solutes dir)) "nothing was written"))
   (testing "^w writes it, and the mark is gone"
    (let [[_ text] (run!-keys dir
       :ctrl-n
       "tris" enter
       "10" enter
       "0.5" enter
       :ctrl-w
       :ctrl-x)]
     (is (str/includes? text " tris"))
     (is (not (str/includes? text "*tris"))))
    (is
     (=
      [{:kind :nonbiological, :name "tris", :arg tris-arg, :mM 10.0, :sigma-mM 0.5}]
      (buffer/read-solutes dir))))
   (testing "Escape in the flow drops the new row; ^w saves only what was there"
    (let [[r text]
      (run!-keys dir :ctrl-n "nacl" enter "5" enter esc :ctrl-w :ctrl-x)]
     (is (= :back r))
     (is (str/includes? text "[  1/1  ]")))
    (is (= 1 (count (buffer/read-solutes dir)))))
   (testing "a wrong number keeps the cell open and says so"
    (let [lines (snap dir :ctrl-n "nacl" enter "abc" enter)]
     (is (has? lines "a number, please"))
     (is (has? lines "abc_") "the cell is still open")))
   (testing "^r marks a saved solute with -, ^u takes it back, ^w then removes it"
    (let [[_ text] (run!-keys dir :ctrl-r :ctrl-x)]
     (is (str/includes? text "-tris")))
    (let [[_ text] (run!-keys dir :ctrl-r :ctrl-u :ctrl-x)]
     (is (not (str/includes? text "-tris"))))
    (is (= 1 (count (buffer/read-solutes dir)))
     "still saved: nothing was confirmed")
    (let [[_ text] (run!-keys dir :ctrl-r :ctrl-w :ctrl-x)]
     (is (str/includes? text "no solutes: ^n ^p ^f ^e")))
    (is (= [] (buffer/read-solutes dir))))
   (testing "the arrows come with the second solute and go with the cursor"
    (let [add (fn [n] [:ctrl-n n enter "1" enter "0.1" enter])
      [_ one] (apply run!-keys dir (concat (add "tris") [:ctrl-x]))
      [_ two-down] (apply run!-keys
       dir
       (concat (add "tris") (add "nacl") [up :ctrl-x]))
      [_ two-up]
      (apply run!-keys dir (concat (add "tris") (add "nacl") [:ctrl-x]))]
     (is (not (re-find #"move: +[↓↑]" one)))
     (is (re-find #"move: +↓ " two-down))
     (is (re-find #"move: +↑" two-up)))))))

(deftest a-buffer-that-cannot-be-used
 (testing
  "a buffer file that cannot be used is told, left alone, and nothing is added"
  (in-project
   (fn [_root dir]
    (spit (buffer/buffer-file dir) "{:solutes")
    (let [[r text] (run!-keys dir :ctrl-n "x" enter :ctrl-w :ctrl-x)]
     (is (= :back r))
     (is (str/includes? text "buffer.edn unusable!")))
    (is (= "{:solutes" (slurp (buffer/buffer-file dir)))))))
 (testing "a row the Julia loader would refuse makes the file unusable too"
  (in-project
   (fn [_root dir]
    (let [text (pr-str {:solutes
        [{:kind :nonbiological, :name "x", :arg "x", :mM 1.0}]})]
     (spit (buffer/buffer-file dir) text)
     (let [[r screen] (run!-keys dir :ctrl-n "tris" enter :ctrl-w :ctrl-x)]
      (is (= :back r))
      (is (str/includes? screen "buffer.edn unusable!")))
     (is (= text (slurp (buffer/buffer-file dir)))))))))

(deftest at-most-999-solutes
 (in-project
  (fn [root dir]
   (let [row (fn [i]
      {:kind :nonbiological,
       :name (str "s" i),
       :arg (str "s" i),
       :mM 1.0,
       :sigma-mM 0.1})]
    (testing "999 solutes open, and ^p adds nothing"
     (buffer/write-solutes! dir (mapv row (range 999)))
     (let [[r text] (run!-keys dir :ctrl-n "x" :ctrl-x)]
      (is (= :back r))
      (is (str/includes? text "[  1/999]"))
      (is (not (str/includes? text "add:"))))
     (is (= 999 (count (buffer/read-solutes dir)))))
    (testing
     "more than 999 is as unusable as a file that is not EDN, and is left alone"
     (let [dir (projects/create! root "over")
       _ (buffer/write-solutes! dir (mapv row (range 1000)))
       before (slurp (buffer/buffer-file dir))
       [r text] (run!-keys dir :ctrl-n "x" enter :ctrl-w :ctrl-x)]
      (is (= :back r))
      (is (str/includes? text "buffer.edn unusable!"))
      (is (= before (slurp (buffer/buffer-file dir))))))))))

;; --- the dropdown

(deftest the-dropdown-of-names
 (in-project
  (fn [root dir]
   (custom-store/write-solutes!
    root
    [{:kind :nonbiological,
      :name "N-acetylcysteine ethyl ester",
      :formula "C7H13NO3S",
      :z 102,
      :pmv 118.4,
      :sigma 4.0}])
   (testing "a blank query lists nothing, ^n and ^p each say what to type"
    (let [lines (snap dir :ctrl-n)]
     (is (frame-ok? lines))
     (is (has? lines "type a solute name"))
     (is (has? lines "exit: esc"))
     (is (not (has? lines "◆"))))
    (is (has? (snap dir :ctrl-p) "type a polymer name")))
   (testing "results show their kind as a tag, the typed text is in the name cell"
    (let [lines (snap dir :ctrl-p "peg")]
     (is (frame-ok? lines))
     (is (has? lines "*peg_"))
     (is (has? lines "> peg"))
     (is (has? lines "family")))
    (is (has? (snap dir :ctrl-n "tris") "> tris"))
    (is (has? (snap dir :ctrl-n "n-acetylcysteine ethyl") "custom")))
   (testing "each key lists only its kind: no polymer under ^n, no solute under ^p"
    (is (has? (snap dir :ctrl-n "ficoll 70") "no match"))
    (is (has? (snap dir :ctrl-p "nacl") "no match"))
    (is (has? (snap dir :ctrl-p "n-acetylcysteine ethyl") "no match")))
   (testing "the basis of the highlighted polymer is in the border note"
    (is (has? (snap dir :ctrl-p "ficoll 70") "mM per 1000 Da"))
    (is (not (has? (snap dir :ctrl-p "peg") "mM per"))))
   (testing "no match says where the custom solutes are, and Enter takes nothing"
    (let [lines (snap dir :ctrl-n "qqqqzzzz")]
     (is (has? lines "no match (custom: main menu>settings>^e)"))
     (is (not (has? lines "ctrl+e in settings"))))
    (let [lines (snap dir :ctrl-n "qqqqzzzz" enter)]
     (is (has? lines "*qqqqzzzz_") "still searching")
     (is (not (has? lines "path: ")))))
   (testing "Tab completes to the highlighted name, Backspace takes a letter back"
    (is (has? (snap dir :ctrl-n "n-acetylcysteine eth" tab) "ethyl ester_"))
    (is (has? (snap dir :ctrl-n "tri" (bs 1)) "*tr_")))
   (testing "Up and Down move the highlight and wrap over the entries found"
    (is (has? (snap dir :ctrl-n "tris" up) "> "))
    (is (has? (snap dir :ctrl-n "tris" down) "> ")))
   (testing "Escape drops the row"
    (let [[r text] (run!-keys dir :ctrl-p "peg" esc :ctrl-x)]
     (is (= :back r))
     (is (str/includes? text "no solutes: ^n ^p ^f ^e")))))))

(defn ^:private add-rows
 "Saves `n` solutes (`s0` ...) in the buffer of `dir`."
 [dir n]
 (buffer/write-solutes!
  dir
  (mapv (fn [i]
    {:kind :nonbiological,
     :name (str "s" i),
     :arg (str "s" i),
     :mM 1.0,
     :sigma-mM 0.1})
   (range n))))

(deftest placement-of-the-dropdown
 ;; the body of the table is 16 rows from line 2 (a 5-line footer); a dropdown opens below
 ;; the cell while 8 rows remain under it (up to the 8th row), else above (it used to be
 ;; the 10th row of 18)
 (in-project
  (fn [_root dir]
   (testing "below the cell when 8 rows remain under it"
    (let [lines (snap dir :ctrl-n "tris")]
     (is (< (line-of lines "*tris_") (line-of lines "> tris")))
     (is (frame-ok? lines))))
   (testing "above the cell when fewer than 8 remain, covering what is there"
    (add-rows dir 14)
    (let [lines (snap dir :ctrl-n "tris")
      cell (line-of lines "*tris_")]
     (is (= 16 cell) "row 15 of the table")
     (is (< (line-of lines "> tris") cell))
     (is (< (line-of lines "exit: esc") cell))
     (is (frame-ok? lines))
     (is (not (has? lines "s13")) "the rows it covers are blanked")
     (is (has? lines "s5") "the others stay")))
   (testing "the rows the dropdown covers come back when it closes"
    (let [lines (snap dir :ctrl-n "tris" esc)]
     (is (has? lines "s13"))
     (is (has? lines "s12"))))
   (testing "the cell on the 8th row still opens below"
    (add-rows dir 7)
    (let [lines (snap dir :ctrl-n "tris")]
     (is (< (line-of lines "*tris_") (line-of lines "> tris")))))
   (testing "the cell on the 9th row opens above"
    (add-rows dir 8)
    (let [lines (snap dir :ctrl-n "tris")]
     (is (> (line-of lines "*tris_") (line-of lines "> tris"))))))))

;; --- every kind through the screen, saved and read back

(defn ^:private saved-rows
 "The rows of the buffer after the keys `inputs` and a save."
 [dir & inputs]
 (apply run!-keys dir (concat inputs [:ctrl-w :ctrl-x]))
 (buffer/read-solutes dir))

(defn ^:private same-as-fixture
 [row fx-name]
 (= (dissoc row :name) (dissoc (fixture-row fx-name) :name)))

(deftest non-biological-and-grades
 (in-project
  (fn [_root dir]
   (let [rows (saved-rows dir :ctrl-n "nacl" enter "200" enter "10" enter)]
    (is (= 1 (count rows)))
    (is (= "nacl" (:name (first rows))))
    (is (same-as-fixture (first rows) "NaCl")))
   (testing
    "a grade has n/a params, and its basis is in the note while the cursor is there"
    (let [lines (snap dir :ctrl-p "ficoll 70" enter "0.05" enter "0.003" enter)]
     (is (has? lines "mM per 1000 Da"))
     (is (has? lines "n/a"))
     (is (frame-ok? lines)))
    (is
     (= :polymer
      (:kind
       (last
        (saved-rows dir :ctrl-p "ficoll 70" enter "0.05" enter "0.003" enter)))))
    (is (not (has? (snap dir) "mM per")) "on the first row there is no basis")))))

(deftest families-through-the-screen
 (in-project
  (fn [_root dir]
   (testing "PEG: the forms are a dropdown, then the number in the params cell"
    (let [lines (snap dir :ctrl-p "peg" enter)]
     (is (has? lines "units n"))
     (is (has? lines "Mn (g/mol)"))
     (is (has? lines "1 of 2 matches"))
     (is (frame-ok? lines)))
    (let [lines (snap dir :ctrl-p "peg" enter enter)]
     (is (has? lines "units n") "the prompt is in the border note")
     (is (has? lines "n=_")))
    (let [rows (saved-rows dir
       :ctrl-p
       "peg"
       enter
       enter
       "22" enter
       "0.1" enter
       "0.01"
       enter)]
     (is (same-as-fixture (last rows) "PEG 22"))
     (is (has? (snap dir) "n=22"))))
   (testing "PEG by Mn"
    (let [rows (saved-rows dir
       :ctrl-p
       "peg"
       enter
       down
       enter
       "3350" enter
       "0.05" enter
       "0.003" enter)]
     (is (same-as-fixture (last rows) "PEG 3350"))
     (is (has? (snap dir down) "Mn=3350"))))
   (testing "a family with two arguments shows them as they are typed"
    (let [lines (snap dir :ctrl-p "pluronic" enter "100" enter "6")]
     (is (has? lines "nEO=100 nPO=6_"))
     (is (has? lines "propylene oxide units n…")))
    (let [rows (saved-rows dir
       :ctrl-p
       "pluronic" enter
       "100" enter
       "65" enter
       "0.01" enter
       "0.001" enter)]
     (is (same-as-fixture (last rows) "Pluronic"))))
   (testing "an error stays in the cell"
    (let [lines (snap dir :ctrl-p "peg" enter enter "1" enter)]
     (is (has? lines "n: at least 2"))
     (is (has? lines "n=1_"))))
   (testing "dextran by Mn below 1000 is told as kDa, until the mM cell is done"
    (is (has? (snap dir :ctrl-p "dextran" enter down enter "40" enter)
      "below 1000 counts as kDa"))
    (is (not (has?
       (snap dir :ctrl-p "dextran" enter down enter "40" enter "1" enter)
       "below 1000")))
    (is (= "dextran 40"
      (:arg (last (saved-rows dir
         :ctrl-p
         "dextran"
         enter
         down
         enter
         "40" enter
         "1" enter
         "0.1" enter)))))))))

(deftest custom-solutes-through-the-screen
 (in-project
  (fn [root dir]
   (custom-store/write-solutes!
    root
    [{:kind :nonbiological,
      :name "N-acetylcysteine ethyl ester",
      :formula "C7H13NO3S",
      :z 102,
      :pmv 118.4,
      :sigma 4.0}
     {:kind :polymer,
      :name "chain-4",
      :z-ends 5,
      :pmv-ends 7.0,
      :sigma-ends 0.5,
      :units [{:label "A", :formula "C2H4O", :z 10, :slope 1.0, :sigma nil}
       {:label "B", :formula "C3H6O", :z 20, :slope 2.0, :sigma 0.1}
       {:label "C", :formula "C4H8O", :z 30, :slope 3.0, :sigma nil}
       {:label "D", :formula "C5H10O", :z 40, :slope 4.0, :sigma 0.2}]}])
   (testing "a custom non-biological solute stores a snapshot, params n/a"
    (let [rows (saved-rows dir
       :ctrl-n
       "n-acetylcysteine ethyl ester" enter
       "5" enter
       "0.1"
       enter)]
     (is (same-as-fixture
       (assoc (first rows) :custom "N-acetylcysteine ethyl ester")
       "NACET"))
     (is (= :custom-nonbio (:kind (first rows))))))
   (testing "a custom polymer asks the counts, with the labels as prompts"
    (let [lines (snap dir :ctrl-p "chain-4" enter)]
     (is (has? lines "nA"))
     (is (has? lines "nA=_")))
    (let [lines (snap dir :ctrl-p "chain-4" enter "3" enter "4" enter "5")]
     (is (has? lines "nA=3 nB=4 nC=5_"))
     (is (has? lines "nC")))
    (let [rows (saved-rows dir
       :ctrl-p
       "chain-4" enter
       "3" enter
       "4" enter
       "5" enter
       "6"
       enter
       "0.01" enter
       "0.0001" enter)]
     (is (= 2 (count rows)))
     (is (same-as-fixture (last rows) "four-unit chain"))
     (is (has? (snap dir down) "nA=3 nB=4 nC=5 nD=6")))
    (is (= "nA=3 nB=4 n"
      (let [l (first (filter #(str/includes? % "nA=3") (snap dir down)))]
       (subs l (str/index-of l "nA=3") (+ (str/index-of l "nA=3") 11))))
     "left-aligned in the params cell"))
   (testing
    "a custom file that is unusable is told once, and there are no custom entries"
    (spit (io/file root "custom-solutes.edn") "{:solutes")
    (let [lines (snap dir :ctrl-n)]
     (is (has? lines "custom file unusable!")))
    (let [lines (snap dir :ctrl-n "n")]
     (is (not (has? lines "custom file unusable!")))
     (is (not (has? lines "custom"))))))))

(deftest sequences-through-the-screen
 (in-project
  (fn [_root dir]
   (let [folder (support/temp-root)
     dna (write-file folder "primer.fasta" ">p1\nACGTTGCA\n")
     two (write-file folder "two.fa" ">r1 first\nACGTACGTAC\n>r2\nGGCC\n")
     rna (write-file folder "guide.fa" ">g1\nACGUUGCA\n")
     prot (write-file folder "carrier.fa" ">sp|P1\nMKTAYIAKQR\n")
     fq (write-file folder
      "reads.fastq"
      "@q1\nACGT\n+\nIIII\n@q2\nTTGA\n+\nIIII\n")]
    (testing "the path prompt hints the folder's sequence files, Tab completes"
     (let [lines (snap dir :ctrl-e enter (str folder "/"))]
      (is (has? lines "path: "))
      (is (has? lines "primer.fasta"))
      (is (not (has? lines "notes.txt")))
      (is (frame-ok? lines)))
     (write-file folder "notes.txt" "x")
     (is (not (has? (snap dir :ctrl-e enter (str folder "/")) "notes.txt")))
     (is (has? (snap dir :ctrl-e enter (str folder "/prim") tab) "primer.fasta_")
      "Tab completes the typed path")
     (is (has? (snap dir :ctrl-e enter) "o: file picker")))
    (testing "DNA: one record is one row, summary in the params cell"
     (let [lines (snap dir :ctrl-e enter dna enter "0.01" enter "0.001" enter)]
      (is (has? lines "ACGTTGCA (8 nt)"))
      (is (has? lines "*p1"))
      (is (frame-ok? lines)))
     (let [rows (saved-rows dir :ctrl-e enter dna enter "0.01" enter "0.001" enter)]
      (is (same-as-fixture (first rows) "primer-A"))
      (is (= "primer.fasta" (:source (first rows))))))
    (testing "a file of two records makes two rows with the same mM and ±"
     (buffer/write-solutes! dir [])
     (let [lines (snap dir :ctrl-e enter two enter "1.5" enter "0.2" enter)]
      (is (has? lines "[  1/2  ]"))
      (is (has? lines "ACGTACGTAC (10 nt)")))
     (let [rows (saved-rows dir :ctrl-e enter two enter "1.5" enter "0.2" enter)]
      (is (= [["r1" "ACGTACGTAC"] ["r2" "GGCC"]] (mapv (juxt :name :arg) rows)))
      (is (every?
        #(and (= 1.5 (:mM %)) (= 0.2 (:sigma-mM %)) (= "two.fa" (:source %)))
        rows))))
    (testing "RNA, protein and FASTQ"
     (buffer/write-solutes! dir [])
     (is (same-as-fixture
       (first
        (saved-rows dir :ctrl-e down enter rna enter "0.02" enter "0.002" enter))
       "guide"))
     (buffer/write-solutes! dir [])
     (is (same-as-fixture
       (first (saved-rows dir
         :ctrl-f
         prot
         enter
         "0.02" enter
         "0.002"
         enter))
       "carrier"))
     (buffer/write-solutes! dir [])
     (is (= [["q1" "ACGT"] ["q2" "TTGA"]]
       (mapv (juxt :name :arg)
        (saved-rows dir :ctrl-e enter fq enter "1" enter "0.1" enter)))))
    (testing "an error in the file is in the note and the prompt stays"
     (let [bad (write-file folder "bad.fa" ">x\nAC9\n")
       lines (snap dir :ctrl-e enter bad enter)]
      (is (has? lines "bad letter 9 (DNA)"))
      (is (has? lines "path: ")))
     (is (has? (snap dir :ctrl-e enter (str folder "/missing.fa") enter)
       "no such file"))
     (is (has? (snap dir :ctrl-e enter enter) "type a path first!")))
    (testing "o on an empty path asks the desktop's picker, a problem is the note"
     (with-redefs [file-picker/pick! (fn [& _] {:problem "no desktop"})]
      (is (has? (snap-staged dir [:ctrl-e enter "o"] 300 []) "no desktop")))
     (with-redefs [file-picker/pick! (fn [& _] {:files [dna]})]
      (is (has? (snap-staged dir [:ctrl-e enter "o"] 300 []) "primer.fasta_"))))
    (testing "Escape on the prompt, and after the mM, drops the rows"
     (buffer/write-solutes! dir [])
     (is (has? (snap dir :ctrl-e enter esc) "no solutes: ^n ^p ^f ^e"))
     (is (has? (snap dir :ctrl-e enter two enter "1" enter esc)
       "no solutes: ^n ^p ^f ^e")))
    (testing "the 999-row cap stops a file that would not fit, adding nothing"
     (add-rows dir 998)
     (let [lines (snap dir :ctrl-e enter two enter)]
      (is (has? lines "over 999 rows"))
      (is (has? lines "path: ")))
     (is (= 998 (count (saved-rows dir :ctrl-e enter two enter esc))))
     (is (= 999
       (count
        (saved-rows dir :ctrl-e enter dna enter "1" enter "0.1" enter)))))))))

;; --- cancelling at every stage

(deftest the-add-keys
 (in-project
  (fn [_root dir]
   (testing "^n opens a name dropdown, never with DNA, RNA or protein entries"
    (let [lines (snap dir :ctrl-n "dna")]
     (is (not (has? lines "◆")))
     (is (has? lines "*dna_"))))
   (testing "^p opens a name dropdown for polymers"
    (is (has? (snap dir :ctrl-p "peg") "family")))
   (testing "^f asks for the path of a protein file at once, with no dropdown"
    (let [lines (snap dir :ctrl-f)]
     (is (has? lines "path: "))
     (is (has? lines "type a path, o: file picker"))
     (is (not (has? lines "type a solute name")))))
   (testing "Tab at table level does nothing"
    (let [lines (snap dir tab)]
     (is (not (has? lines "path: ")))
     (is (has? lines "no solutes: ^n ^p ^f ^e"))))
   (testing "^f then a protein file adds a protein row"
    (let [folder (support/temp-root)
      prot (write-file folder "carrier.fa" ">sp|P1\nMKTAYIAKQR\n")
      rows (saved-rows dir :ctrl-f prot enter "0.02" enter "0.002" enter)]
     (is (= :protein (:kind (first rows)))))
    (buffer/write-solutes! dir []))
   (testing "inside a dropdown Tab still completes, in a path prompt too"
    (is (has? (snap dir :ctrl-n "tris" tab) "*tris_"))
    (let [folder (support/temp-root)]
     (write-file folder "primer.fasta" ">p1\nACGT\n")
     (is (has? (snap dir :ctrl-f (str folder "/prim") tab) "primer.fasta_"))))
   (testing "^e asks DNA or RNA, then the path of that kind; Escape drops the row"
    (let [lines (snap dir :ctrl-e)]
     (is (has? lines "DNA"))
     (is (has? lines "RNA"))
     (is (not (has? lines "path: "))))
    (is (has? (snap dir :ctrl-e enter) "path: "))
    (is (has? (snap dir :ctrl-e esc) "no solutes: ^n ^p ^f ^e"))
    (is (has? (snap dir :ctrl-e enter esc) "no solutes: ^n ^p ^f ^e"))
    (let [folder (support/temp-root)
      u (write-file folder "u.fa" ">x\nACGU\n")
      t (write-file folder "t.fa" ">x\nACGT\n")]
     (is (has? (snap dir :ctrl-e enter u enter) "bad letter U (DNA)"))
     (is (has? (snap dir :ctrl-e down enter t enter) "bad letter T (RNA)"))))
   (testing
    "the 999-row cap blocks all four keys, and all four add legends are gone"
    (add-rows dir 999)
    (doseq [k [:ctrl-n :ctrl-p :ctrl-f :ctrl-e]
      :let [lines (snap dir k)]]
     (is (= 999 (count (saved-rows dir k esc))))
     (is (has? lines "[  1/999]"))
     (is (not (has? lines "path: ")))
     (is (not (has? lines "type a")))
     (doseq [legend ["add nonbio:" "add polymer:" "add protein:" "add nucleotide:"]]
      (is (not (has? lines legend)) legend)))
    (is (has? (snap dir :ctrl-n) "rmv:"))))))

(deftest cancel-everywhere
 (in-project
  (fn [root dir]
   (custom-store/write-solutes!
    root
    [{:kind :polymer,
      :name "chain-2",
      :z-ends 5,
      :pmv-ends 7.0,
      :sigma-ends nil,
      :units [{:label "A", :formula "C2H4O", :z 10, :slope 1.0, :sigma nil}
       {:label "B", :formula "C3H6O", :z 20, :slope 2.0, :sigma nil}]}])
   (let [empty-page "no solutes: ^n ^p ^f ^e"
     stages {"name" [],
      "name typed" ["pe"],
      "form" ["peg" enter],
      "params" ["peg" enter enter],
      "second arg" ["pluronic" enter "10" enter],
      "counts" ["chain-2" enter "1" enter],
      "mM" ["tris" enter],
      "±" ["tris" enter "1" enter],
      "path" [enter]}]
    (doseq [[label typed-keys] stages]
     (let [lines (snap dir (vec (concat [:ctrl-n] typed-keys [esc])))]
      (is (has? lines empty-page) label)
      (is (= :back
        (first
         (apply run!-keys dir :ctrl-n (concat typed-keys [esc :ctrl-x]))))
       label))
     (is (= [] (saved-rows dir (vec (concat [:ctrl-n] typed-keys [esc])))) label))
    (testing "a draft that was saved before is not lost by cancelling a later add"
     (let [rows (saved-rows dir :ctrl-n "tris" enter "1" enter "0.1" enter)]
      (is (= 1 (count rows)))
      (is (= rows (saved-rows dir :ctrl-p "peg" esc)))))))))

;; --- editing

(deftest editing-each-kind
 (in-project
  (fn [_root dir]
   (buffer/write-solutes! dir fixture)
   (testing "the order: name (a free label), params where there are some, mM, ±"
    ;; row 0 is NaCl: name, mM, ±
    (let [lines (snap dir enter)]
     (is (has? lines "NaCl_") "the name cell is open")
     (is (frame-ok? lines)))
    (let [lines (snap dir enter enter)]
     (is (has? lines "200_") "the mM cell"))
    (let [lines (snap dir enter enter enter)]
     (is (has? lines "10_") "the ± cell")))
   (testing "NaCl: relabel and change mM; arg and kind stay"
    (let [rows (saved-rows dir enter (bs 4) "salt" enter (bs 3) "150" enter enter)]
     (is (= (assoc (fixture-row "NaCl") :name "salt" :mM 150.0) (first rows)))
     (is (= (rest fixture) (rest rows)))))
   (testing "a family: the numbers are re-typed in the params cell"
    (let [lines (snap dir down down enter enter)]
     (is (has? lines "22_"))
     (is (has? lines "units n")))
    (let [rows (saved-rows dir down down enter enter (bs 2) "30" enter enter enter)]
     (is (= "PEG n=30" (:arg (nth rows 2))))
     (is (has? (snap dir down down) "n=30"))))
   (testing "a two-argument family and a custom polymer ask each number again"
    (let [rows (saved-rows dir
       (vec (repeat 3 down))
       enter
       enter
       (bs 3)
       "90"
       enter
       enter
       enter
       enter)]
     (is (= "Pluronic nEO=90 nPO=65" (:arg (nth rows 3)))))
    (let [rows (saved-rows dir
       (vec (repeat 9 down))
       enter
       enter
       (bs 2)
       "7"
       enter
       enter
       enter)]
     (is (= [7.0] (:counts (nth rows 9))))
     (is (= "chain-1" (:custom (nth rows 9))))))
   (testing "a sequence: no params, and the note says to add it again"
    (let [lines (snap dir (vec (repeat 4 down)) enter)]
     (is (has? lines "re-add to change the se…"))
     (is (has? lines "primer-A_")))
    (let [lines (snap dir (vec (repeat 4 down)) enter enter)]
     (is (has? lines "0.01_") "the next cell is the mM"))
    (let [rows (saved-rows dir
       (vec (repeat 4 down))
       enter
       enter
       (bs 4)
       "0.5"
       enter
       enter)]
     (is (= "ACGTTGCA" (:arg (nth rows 4))))
     (is (= 0.5 (:mM (nth rows 4))))))
   (testing "Escape stops an edit and what was taken stays a draft"
    (buffer/write-solutes! dir fixture)
    (let [[_ text] (run!-keys dir enter enter (bs 3) "150" enter esc :ctrl-x)]
     (is (str/includes? text "*NaCl"))))
   (testing "a row marked for removal cannot be edited"
    (let [lines (snap dir :ctrl-r enter)]
     (is (not (has? lines "NaCl_"))))))))

(deftest old-rows-keep-working
 (in-project
  (fn [_root dir]
   (buffer/write-solutes!
    dir
    [{:kind :nonbiological,
      :name "my buffer salt",
      :arg "my buffer salt",
      :mM 5.0,
      :sigma-mM 0.5}])
   (is (has? (snap dir) "my buffer salt"))
   (is (has? (snap dir) "n/a"))
   (let [rows (saved-rows dir
      enter
      (bs 14)
      "salt"
      enter
      (bs 1)
      "6"
      enter
      (bs 3)
      "0.6"
      enter)]
    (is (= [{:kind :nonbiological,
        :name "salt",
        :arg "my buffer salt",
        :mM 6.0,
        :sigma-mM 0.6}]
      rows))))))

;; --- widths

(deftest nothing-breaks-a-border
 (in-project
  (fn [root dir]
   (let [long-name (apply str "long" (repeat 76 "x"))]
    (custom-store/write-solutes!
     root
     [{:kind :nonbiological,
       :name long-name,
       :formula "C7H13NO3S",
       :z 102,
       :pmv 118.4,
       :sigma 4.0}])
    (testing "a long name in the dropdown ends in an ellipsis and keeps the frame"
     (let [lines (snap dir :ctrl-n "longxx")]
      (is (frame-ok? lines))
      (is (has? lines (str (subs long-name 0 36) "…")))
      (is (has? lines "custom"))))
    (testing "a long name in a row is cut with an ellipsis"
     (let [lines (snap dir :ctrl-n long-name enter "1" enter "0.1" enter)]
      (is (frame-ok? lines))
      (is (has? lines "…"))))
    (testing "a long typed name is shown by its end"
     (let [lines (snap dir :ctrl-n (apply str (repeat 59 "q")))]
      (is (frame-ok? lines))
      (is (has? lines "…qqqq"))))
    (testing "a long path and file name keep the frame"
     (let [folder (support/temp-root)
       fname (str (apply str (repeat 70 "n")) ".fasta")
       f (write-file
        folder
        fname
        ">a-long-record-id-that-goes-on-and-on-and-on-and-on\nACGT\n")
       lines (snap dir :ctrl-e enter f)]
      (is (frame-ok? lines))
      (is (has? lines "path: …"))
      (let [lines (snap dir :ctrl-e enter f enter "1" enter "0.1" enter)]
       (is (frame-ok? lines))
       (is (has? lines "ACGT (4 nt)")))
      (let [rows (saved-rows dir :ctrl-e enter f enter "1" enter "0.1" enter)]
       (is (= fname (:source (first rows))) "the file name, not the path")
       (is (= "a-long-record-id-that-goes-on-and-on-and-on-and-on"
         (:name (first rows)))))))
    (testing "three-digit row numbers fit the counter and the dropdown"
     (add-rows dir 120)
     (let [lines (snap dir :ctrl-p "peg")]
      (is (frame-ok? lines))
      (is (has? lines "[121/121]"))
      (is (has? lines "*peg_")))
     (let [lines (snap dir (vec (repeat 99 down)))]
      (is (frame-ok? lines))
      (is (has? lines "[100/120]")))
     (let [lines (snap dir (vec (repeat 99 down)) enter)]
      (is (frame-ok? lines))
      (is (has? lines "s99_"))))))))

(deftest the-editor-takes-a-target
 (let [saved (atom nil)
   target {:title "t",
    :load! (fn [] [(first fixture)]),
    :save! (fn [rows] (reset! saved rows)),
    :unusable-note "t unusable!",
    :idle-note "recipe: t"}
   run (fn [opts & inputs]
    (let [vs (support/virtual-screen)
      f (future
       (solutes-menu/show! (:screen vs) background target opts))]
     (apply support/feed! vs (concat inputs [eof]))
     (deref f 20000 :timeout)
     (str/split-lines (support/screen-text vs))))]
  (testing "the rows come from `load!`, the idle note from the target"
   (let [lines (run {})]
    (is (has? lines "NaCl"))
    (is (has? lines "recipe: t"))
    (is (has? lines "[  1/1  ]"))))
  (testing "^w calls `save!` with the rows"
   (run {} :ctrl-w)
   (is (= [(first fixture)] @saved)))
  (testing
   "drafts replace the rows and are unsaved until ^w; the hint shows until then"
   (reset! saved nil)
   (let [lines (run {:drafts (vec (take 2 fixture)), :hint "replaces it at ^w"})]
    (is (has? lines "*NaCl"))
    (is (has? lines "[  1/2  ]"))
    (is (has? lines "replaces it at ^w")))
   (is (nil? @saved))
   (let [lines (run {:drafts (vec (take 2 fixture)), :hint "replaces it at ^w"}
      :ctrl-w)]
    (is (= (vec (take 2 fixture)) @saved))
    (is (not (has? lines "replaces it at ^w")))
    (is (not (has? lines "*NaCl")))))
  (testing "empty drafts: an empty table"
   (is (has? (run {:drafts []}) "no solutes: ^n ^p ^f ^e")))
  (testing "a target that throws is unusable: told, nothing saved"
   (reset! saved nil)
   (let [bad (assoc target :load! (fn [] (throw (ex-info "x" {}))))
     vs (support/virtual-screen)
     f (future (solutes-menu/show! (:screen vs) background bad {}))]
    (support/feed! vs :ctrl-n "x" enter :ctrl-w eof)
    (deref f 20000 :timeout)
    (is (has? (str/split-lines (support/screen-text vs)) "t unusable!"))
    (is (nil? @saved))))))
