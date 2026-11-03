;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The add flow of the buffer page (`baysol.tui.screens.solutes-menu`), as pure functions of
;; the page's state `st` (`{:s solutes-state :cursor :offset :note :ui}`), so none of it
;; needs a terminal. `ui` is what is being typed, nil when nothing is:
;;
;;   {:type :name  ...}  `^p` appended a draft row and its name cell is open with a dropdown
;;                       of every solute BAYSOL knows (`solute-index/search`, plus the
;;                       custom solutes) and the three `◆ ... from a FASTA/FASTQ file`
;;                       entries; up/down move, Tab completes the typed text, Enter picks,
;;                       Escape drops the new row
;;   {:type :form  ...}  a polymer family with several forms (PEG by n or by Mn): a
;;                       dropdown of the forms
;;   {:type :path  ...}  the path of a DNA, RNA or protein file, hinted as models' paths are
;;                       (`models/hints-for`), `o` on an empty path opens the desktop's
;;                       picker
;;   {:type :edit  ...}  one cell is typed into: `:field` (`:name` free text, `:params`,
;;                       `:mM`, `:sigma-mM`), `:text`, `:queue` (the fields still to
;;                       do), `:add` (the indices of the rows this add made: Escape drops
;;                       them; nil when an existing row is edited, where Escape just stops
;;                       and what was taken stays a draft), `:batch` (the rows a file made,
;;                       which get the same mM and ±), `:ctx` (the arguments of the params
;;                       cell) and `:hint` (a note to keep while mM is typed)
;;
;; After the pick, by kind of the picked entry: a non-biological solute or a built-in
;; polymer grade goes on to mM and ±; a polymer family asks its numbers in the params cell
;; (`units n`, `Mn (g/mol)`, ...); a custom non-biological solute stores a snapshot of the
;; entry (the project never reads the global file); a custom polymer asks the count of each
;; unit kind (`nA`, `nB` ... the unit labels) in the params cell; DNA, RNA and protein ask a
;; path and make one row for each record of the file. Every row is the one of
;; `test/fixtures/buffer/buffer.edn` (see `baysol.tui.buffer`). The flow never saves: the
;; rows are drafts until `^w`.

(ns baysol.tui.add-flow
 (:require [baysol.tui.text :as txt]
  [baysol.tui.buffer :as buffer]
  [baysol.tui.custom :as custom]
  [baysol.tui.custom-store :as store]
  [baysol.tui.limits :as limits]
  [baysol.tui.models :as models]
  [baysol.tui.screens.page-load :as pgld]
  [baysol.tui.screens.picker :as picker]
  [baysol.tui.screens.table :as table]
  [baysol.tui.sequences :as sequences]
  [baysol.tui.solute-index :as solute-index]
  [baysol.tui.solutes :as solutes]
  [clojure.java.io :as io]
  [clojure.string :as str])
 (:import (com.googlecode.lanterna.input KeyType)))

(set! *warn-on-reflection* true)

(def max-typed
 "The most characters a cell takes."
 60)

(def fields
 "The columns of the table, by the field typed into each."
 [:name :mM :sigma-mM :params])

;; --- numbers

(defn format-number
 "`x` as plain decimal text with no exponent and no trailing zeros (200.0 gives \"200\",
 1.0E-5 gives \"0.00001\"); \"\" for nil."
 [x]
 (txt/format-number x))

(defn parse-field
 "What the text `text` typed for `field` comes to: `{:value v}` (the trimmed name, or the
 number) or `{:error \"short message\"}`. A concentration must be above 0, an uncertainty
 0 or more."
 [field text]
 (let [t (str/trim text)]
  (if (= field :name)
   (if (str/blank? t) {:error "name needed"} {:value t})
   (let [x (txt/number-text t)]
    (cond (nil? x) {:error "a number, please"}
     (and (= field :mM) (not (pos? x))) {:error "mM must be > 0"}
     (neg? x) {:error "not below 0"}
     :else {:value x})))))

(defn ^:private parse-count
 "The count of units typed as `text`: `{:value x}` for a number above 0, else `{:error}`."
 [text]
 (let [x (txt/number-text (str/trim text))]
  (cond (nil? x) {:error "a number, please"}
   (not (pos? x)) {:error "must be > 0"}
   :else {:value x})))

;; --- the custom solutes

(defn load-customs
 "The custom solutes of the BAYSOL folder `root` for the autocomplete: `{:customs [entry
 ...]}`, the entries with a name; no entries, and `{:note \"custom file unusable!\"}`, for
 a file that cannot be used (a missing one is just no entries)."
 [root]
 (try {:customs (filterv #(not (str/blank? (:name %))) (store/read-solutes root))}
  (catch Exception _ {:customs [], :note "custom file unusable!"})))

;; --- the dropdown of names

(def ^:private add-kinds
 "The kinds of index entry each dropdown lists: `^n` (`:nonbio`) the non-biological
 solutes and the custom non-biological ones, `^p` (`:polymer`) the polymer grades, the
 families and the custom polymers."
 {:nonbio #{:nonbiological :custom-nonbio},
  :polymer #{:polymer :polymer-family :custom-polymer}})

(defn entry-tag
 "The short tag shown at the right of the entry `e`: `solute`, `polymer`, `family` or
 `custom`."
 [e]
 (if (= (:kind e) :polymer-family) "family" (:tag e)))

(defn entries
 "The entries of the dropdown of the add key `kind` (`:nonbio` or `:polymer`) for the typed
 `query`: what `solute-index/search` finds of that kind (with the custom solutes
 `customs`), and nothing of another kind; none for a blank query."
 [kind query customs]
 (solute-index/search query customs solute-index/default-limit (add-kinds kind)))

(defn name-pick-initial
 "The state of the name dropdown of the add key `kind` with nothing typed, over the custom
 solutes `customs`."
 [kind customs]
 {:kind kind,
  :buffer "",
  :customs customs,
  :matches [],
  :index 0,
  :armed? false,
  :error nil})

(defn ^:private refilter
 "`st` with the text `buffer` typed: the entries it finds, the first highlighted."
 [{:keys [customs kind], :as st} buffer]
 (let [matches (entries kind buffer customs)]
  (assoc st
   :buffer buffer
   :matches matches
   :index 0
   :armed? (boolean (seq matches))
   :error nil)))

(defn name-pick-step
 "What `input` does in the name dropdown `st`: `{:state new}`, `{:chosen entry}` for Enter
 on a highlighted entry (\"no match\" when there is none), or `:cancel` for Escape (or the
 terminal going away)."
 [{:keys [buffer matches index armed?], :as st} input]
 (cond
  (or (= input KeyType/Escape) (= input KeyType/EOF)) :cancel

  (= input KeyType/Enter)
  (if armed?
   {:chosen (nth matches index)}
   {:state (assoc st :error "no match")})

  (and (#{KeyType/ArrowDown KeyType/ArrowUp} input) (seq matches))
  {:state (assoc st
    :armed? true
    :error nil
    :index (txt/cycle-index index
     (count matches)
     (= input KeyType/ArrowDown)))}

  (and (= input KeyType/Tab) (seq matches))
  {:state (refilter st (:name (nth matches index)))}

  (txt/edits? input buffer 60) {:state (refilter st (txt/typed buffer input 60))}

  (txt/at-cap? input buffer 60) {:state (assoc st :error (txt/too-long "name" 60))}

  :else {:state st}))

(def ^:private tag-room 7)

(defn item-text
 "The text of the entry `e` in a dropdown line `room` characters wide: its name (an
 ellipsis when it does not fit) and its tag at the right."
 [e room]
 (let [n (max 1 (- room tag-room 1))
   s (str (:name e))
   name-text (if (> (txt/display-width s) n)
    (str (txt/take-width s (dec n)) "…")
    s)
   pad (txt/spaces (max 0 (- n (txt/display-width name-text))))
   tag (entry-tag e)]
  (str name-text
   pad
   " "
   (txt/spaces (max 0 (- tag-room (count tag))))
   tag)))

;; ^e is a key of the GLOBAL settings (main menu > settings), not of a project's own
;; settings, so the way there is spelled out; 40 characters is what the row holds.
(def no-match "no match (custom: main menu>settings>^e)")

(defn pick-display
 "The state of the name dropdown `st` as `picker/layout` takes it, for lines `room` wide:
 `{:matches [text ...] :index :error}`; `:error` is the text of the status row when it is
 not the count of the entries."
 [{:keys [buffer matches index error kind]} room]
 (let [hits (count matches)]
  {:matches (mapv #(item-text % room) matches),
   :index index,
   :error (cond error error
    (str/blank? buffer) (if (= kind :polymer)
     "type a polymer name"
     "type a solute name")
    (zero? hits) no-match)}))

(defn basis-note
 "The note for a polymer whose molarity has a basis `basis` (`per monomer unit`), or nil."
 [basis]
 (when basis (str "mM " basis)))

;; --- placement of a dropdown

(def dropdown-rows
 "The most rows a dropdown has, its status row included."
 8)

(defn below?
 "Whether a dropdown opens below the cell on row `r` (0-based) of a table of `window` body
 rows: when at least `dropdown-rows` rows remain below it."
 [r window]
 (>= (- window 1 r) dropdown-rows))

(defn box-top
 "The line of the page (0-based) where a dropdown of `h` lines starts for the cell on row
 `r` of a table of `window` body rows: under the cell, else above it. The body starts on
 line `top` (the art's header block, `table/body-top`)."
 [r window h top]
 (if (below? r window) (+ top r 1) (- (+ top r) h)))

(defn overlay-box
 "The lines `lines` of a page with the `texts` written over them, one to a line, in the
 columns `col` to `col` + `width`, below or above the cell on body row `r` of a table of
 `window` rows (blanking what they cover)."
 [lines texts r {:keys [col width window top]}]
 (let [top (box-top r window (count texts) top)]
  (reduce (fn [ls [k text]] (update ls (+ top k) pgld/put-text col width text))
   lines
   (map-indexed vector texts))))

;; --- the params of a row

(def ^:private number-re "([-+0-9.eE]+)")

(defn ^:private template-regex
 "The pattern of the `arg` strings a form's template makes, a number for each `{key}`."
 [template]
 (re-pattern
  (str "(?i)^"
   (str/join number-re
    (map #(java.util.regex.Pattern/quote %)
     (str/split template #"\{\w+\}" -1)))
   "$")))

(def ^:private form-patterns
 (delay (vec (for [fam (solute-index/all-families)
     [fi form] (map-indexed vector (:forms fam))]
    {:fam fam,
     :form-index fi,
     :keys (mapv :key (:args form)),
     :regex (template-regex (:template form))}))))

(defn family-match
 "The family and form a `:polymer` row's `arg` was made from, or nil for a grade or any
 other text: `{:fam :form-index :values {key \"text\"}}`, the values as written in the
 `arg` (`PEG n=22` gives `{\"n\" \"22\"}`)."
 [arg]
 (some (fn [{:keys [fam form-index regex], arg-keys :keys}]
   (when-let [m (re-matches regex (str/trim (str arg)))]
    {:fam fam,
     :form-index form-index,
     :values (zipmap arg-keys (if (string? m) [] (rest m)))}))
  @form-patterns))

(defn values-text
 "The key=value text of the numbers of a family form: `n=22`, `nEO=100 nPO=65`; `values`
 is a map from key to text, an argument it lacks is shown as `key=`."
 [form values]
 (str/join " "
  (map (fn [a] (str (:key a) "=" (get values (:key a) ""))) (:args form))))

(defn counts-text
 "The text of the counts of a custom polymer's `units`: `nA=100 nB=65` (the labels of the
 units; a unit without a count yet is left out)."
 [units counts]
 (str/join
  " "
  (map (fn [u c] (str "n" (:label u) "=" (format-number c))) units counts)))

(defn params-cell
 "What the params cell says of the solute `s`, `width` characters being the room for text:
 `{:text :align}`. `n/a` centred for a non-biological solute, a grade and a custom
 non-biological solute; the key=value text, left, for a polymer family and a custom
 polymer; the summary of the sequence for DNA, RNA and protein."
 [s width]
 (let [na {:text "n/a", :align :center}]
  (case (:kind s)
   :polymer (if-let [{:keys [fam form-index values]} (family-match (:arg s))]
    {:text (values-text (nth (:forms fam) form-index) values),
     :align :left}
    na)
   :custom-polymer {:text (counts-text (:units s) (:counts s)), :align :left}
   (:dna :rna :protein) {:text (sequences/summary (:kind s) (str (:arg s)) width),
    :align :left}
   na)))

(defn ^:private editable-params
 "The context to type the params of the solute `s` in: nil when the row has none to type
 (a sequence is read-only, the others have `n/a`)."
 [s]
 (case (:kind s)
  :polymer (when-let [{:keys [fam form-index values]} (family-match (:arg s))]
   {:type :family,
    :fam fam,
    :form-index form-index,
    :k 0,
    :values {},
    :prefill values})
  :custom-polymer {:type :counts,
   :labels (mapv :label (:units s)),
   :k 0,
   :counts [],
   :prefill (mapv format-number (:counts s))}
  nil))

(defn ^:private ctx-prompt
 "The prompt of the argument being typed in `ctx`, shown in the border note."
 [{:keys [fam form-index k labels], ctx-type :type}]
 (if (= ctx-type :family)
  (get-in (nth (:forms fam) form-index) [:args k :prompt])
  (str "n" (nth labels k))))

(defn ^:private ctx-initial-text
 "The text the argument being typed in `ctx` starts as: the old value when a row is edited."
 [{:keys [fam form-index k prefill], ctx-type :type}]
 (if (= ctx-type :family)
  (get prefill (get-in (nth (:forms fam) form-index) [:args k :key]) "")
  (nth prefill k "")))

(defn ^:private ctx-text
 "What the params cell shows while `typed` is typed for the argument being asked in `ctx`:
 the ones taken, then the one in progress."
 [{:keys [fam form-index k labels values counts], ctx-type :type} typed]
 (if (= ctx-type :family)
  (let [args (:args (nth (:forms fam) form-index))]
   (str/join " "
    (concat (map (fn [a] (str (:key a) "=" (get values (:key a))))
      (take k args))
     [(str (:key (nth args k)) "=" typed)])))
  (str/join " "
   (concat (map (fn [l c] (str "n" l "=" (format-number c))) labels counts)
    [(str "n" (nth labels k) "=" typed)]))))

(defn ^:private arg-problem
 "What is wrong with `text` as the argument `arg-key` of the form `form-index` of the family
 `fam`, or nil. The other arguments stand at a value that is always fine."
 [fam form-index arg-key text]
 (let [form (nth (:forms fam) form-index)
   dummy (into {} (map (fn [a] [(:key a) "1000"])) (:args form))]
  (:error (solute-index/family-arg fam form-index (assoc dummy arg-key text)))))

;; --- state helpers

(defn ^:private row-solute
 [st i]
 (solutes/value (get-in st [:s :rows i])))

(defn ^:private cancel-add
 "`st` with the rows of an add dropped and nothing typed any more."
 [st]
 (let [{:keys [add from-cursor]} (:ui st)
   s (solutes/drop-new-rows (:s st) add)]
  (assoc st
   :s s
   :ui nil
   :cursor (txt/clamp-cursor (or from-cursor (:cursor st)) s))))

(defn close-flow
 "`st` with the flow that is open dropped, as Escape or Ctrl-X drops it: the rows of an
 add go, and nothing typed is kept. A state with no flow open is returned as it is."
 [st]
 (cond (nil? (:ui st)) st
  (:add (:ui st)) (cancel-add st)
  :else (assoc st :ui nil)))

(defn ^:private field-text
 "The text to start typing `field` of row `i` from."
 [st i field]
 (let [v (row-solute st i)]
  (case field
   :name (str (:name v))
   :mM (format-number (:mM v))
   :sigma-mM (format-number (:sigma-mM v))
   "")))

(defn ^:private open-field
 "`st` with the field `field` of row `i` open for typing (its `ui` map `base` carries
 `:add`, `:batch`, `:queue`, `:hint`); a params field gets the context `ctx`."
 [st i field base ctx]
 (let [base (assoc base :type :edit :i i :field field :ctx ctx)]
  (assoc st
   :cursor i
   :ui (assoc base
    :text
    (if ctx (ctx-initial-text ctx) (field-text st i field))))))

(defn ^:private next-field
 "`st` after the field of the edit in `ui` is done: the next field of its queue opens (a
 params field with the context `ctxs`, a map from row to context), or the edit ends."
 [st ui]
 (let [[field & more] (:queue ui)
   i (:i ui)]
  (if-not field
   (assoc st :ui nil)
   (open-field
    st
    i
    field
    (assoc (select-keys ui [:add :batch :from-cursor :hint]) :queue (vec more))
    (when (= field :params) (:next-ctx ui))))))

;; --- the steps of the pick

(def nucleotide-kinds
 "The choice `^e` asks first: the label shown and the sequence kind it stands for."
 [["DNA" :dna] ["RNA" :rna]])

(defn ^:private path-ui
 "The `:ui` of the path prompt for a sequence file of the kind `seq-kind` for the new row
 `n`."
 [n from-cursor seq-kind]
 {:type :path,
  :add [n],
  :from-cursor from-cursor,
  :seq-kind seq-kind,
  :buffer "",
  :index 0})

(defn start-add
 "`st` with a new row added at the end and its first question open, for the add key `kind`:
 `:nonbio` and `:polymer` the name, typed into the dropdown of that kind over the custom
 solutes `customs`; `:protein` the path of the sequence file at once; `:nucleotide` the
 choice of DNA or RNA, then that path. `loaded` is `{:customs [...] :note ...}` of
 [[load-customs]]. A table of 999 rows is returned as it is."
 [st {:keys [customs note]} kind]
 (let [n (count (get-in st [:s :rows]))
   from-cursor (:cursor st)]
  (if (>= n limits/max-rows)
   st
   (assoc st
    :s (solutes/add-row (:s st))
    :cursor n
    :note note
    :ui (case kind
     :protein (path-ui n from-cursor :protein)
     :nucleotide {:type :nuc,
      :add [n],
      :from-cursor from-cursor,
      :pick (picker/initial (mapv first nucleotide-kinds)
       nil)}
     {:type :name,
      :add [n],
      :from-cursor from-cursor,
      :pick (name-pick-initial kind customs)})))))

(defn ^:private set-new
 "`st` with the draft of row `i` set to the new solute `solute`."
 [st i solute]
 (update st :s solutes/set-solute i solute))

(defn ^:private to-money
 "`st` with mM then ± opened for row `i`."
 [st i base]
 (open-field st i :mM (assoc base :queue [:sigma-mM]) nil))

(defn ^:private family-start
 "`st` with the numbers of the form `form-index` of the family `fam` being asked for the
 new row `i`."
 [st i fam form-index base]
 (let [ctx {:type :family,
    :fam fam,
    :form-index form-index,
    :k 0,
    :values {},
    :prefill {}}]
  (open-field st i :params (assoc base :queue [:mM :sigma-mM]) ctx)))

(defn ^:private form-label
 "How the form `form` asks for its numbers: the prompts of its arguments."
 [form]
 (str/join ", " (map :prompt (:args form))))

(defn ^:private picked
 "`st` after the entry `e` was picked in the name dropdown of its `ui`."
 [st e]
 (let [{:keys [add from-cursor]} (:ui st)
   i (first add)
   base {:add add, :from-cursor from-cursor}
   solute {:name (:name e), :mM nil, :sigma-mM nil}]
  (case (:kind e)
   (:nonbiological :polymer)
   (to-money (set-new st i (assoc solute :kind (:kind e) :arg (:target e))) i base)

   :polymer-family
   (let [fam (solute-index/family (:family e))
     st (set-new st i (assoc solute :kind :polymer :arg ""))]
    (if (> (count (:forms fam)) 1)
     (assoc st
      :ui
      {:type :form,
       :add add,
       :from-cursor from-cursor,
       :fam fam,
       :pick (picker/initial (mapv form-label (:forms fam)) nil)})
     (family-start st i fam 0 base)))

   :custom-nonbio
   (let [snap (merge (custom/snapshot (:entry e)) solute)]
    (if (buffer/row-problem (assoc snap :mM 1.0 :sigma-mM 0.0))
     (assoc st :note "custom entry invalid")
     (to-money (set-new st i snap) i base)))

   :custom-polymer
   (let [entry (:entry e)
     labels (mapv :label (:units entry))
     probe (merge (custom/snapshot entry (vec (repeat (count labels) 1.0)))
      {:mM 1.0, :sigma-mM 0.0})]
    (if (buffer/row-problem probe)
     (assoc st :note "custom entry invalid")
     (open-field (set-new st i (assoc solute :kind :custom-polymer))
      i
      :params
      (assoc base :queue [:mM :sigma-mM])
      {:type :counts,
       :entry entry,
       :labels labels,
       :k 0,
       :counts [],
       :prefill []})))

   st)))

;; --- the path of a sequence file

(defn path-problem
 "What is wrong with `path` as the sequence file to read, as a short message (22 characters
 at most), or nil: empty, not absolute, not there, a folder, not readable."
 [path]
 (let [file (io/file path)]
  (cond (str/blank? path) "type a path first!"
   (not (.isAbsolute file)) "use a full path"
   (not (.exists file)) "no such file"
   (.isDirectory file) "that is a folder"
   (not (.canRead file)) "cannot read the file"
   :else nil)))

(defn path-hints
 "The names the typed path `buffer` can go on with: folders, then the FASTA and FASTQ
 files (`models/hints-for`)."
 [buffer]
 (models/hints-for buffer sequences/fasta-file?))

(defn ^:private sequence-rows
 "The solutes of the `records` of the file `path`, of `kind`: one for each record, its id
 as the name and the record, the clean sequence as the arg, the file name as the source."
 [kind records path]
 (let [fname (.getName (io/file path))]
  (mapv (fn [{:keys [id], letters :sequence}]
    {:kind kind,
     :name id,
     :arg letters,
     :source fname,
     :record id,
     :mM nil,
     :sigma-mM nil})
   records)))

(defn ^:private path-enter
 "`st` after Enter on the path typed: the file is read and its rows added, or the note says
 why not and the prompt stays."
 [st]
 (let [{:keys [seq-kind add from-cursor], :as ui} (:ui st)
   buffer (str/trim (:buffer ui)) ; a typed or pasted path may end in blanks or a newline
   problem (path-problem buffer)
   parsed (when-not problem (sequences/parse-file buffer seq-kind))
   error (or problem (:error parsed))
   i (first add)
   existing (- (count (get-in st [:s :rows])) (count add))]
  (cond error (assoc st :note error)
   (> (+ existing (count (:records parsed))) limits/max-rows)
   (assoc st
    :note
    (str "over "
     limits/max-rows
     " rows"))
   :else
   (let [rows (sequence-rows seq-kind (:records parsed) buffer)
     st (-> st
      (update :s solutes/set-solute i (first rows))
      (update :s solutes/append-solutes (rest rows)))
     idx (vec (range i (+ i (count rows))))]
    (open-field
     st
     i
     :mM
     {:add idx, :batch idx, :from-cursor from-cursor, :queue [:sigma-mM]}
     nil)))))

(defn path-step
 "`st` after `input` while the path of a sequence file is typed; `pick-file` is called
 (no arguments, giving `{:files [...]}` or `{:problem text}`) for `o` on an empty path."
 [st input pick-file]
 (let [{:keys [buffer index]} (:ui st)
   hs (path-hints buffer)
   set-ui (fn [& kvs] (update st :ui #(apply assoc % kvs)))]
  (cond
   (or (= input KeyType/Escape) (= input KeyType/EOF)) (cancel-add st)
   (= input KeyType/Enter) (path-enter st)

   (and (str/blank? buffer) (contains? #{\o \O} input))
   (let [{:keys [files problem]} (pick-file)]
    (cond problem (assoc st :note problem)
     (seq files) (assoc-in st [:ui :buffer] (first files))
     :else st))

   (and (#{KeyType/ArrowDown KeyType/ArrowUp} input) (seq hs))
   (set-ui :index
    (txt/cycle-index (min index (dec (count hs)))
     (count hs)
     (= input KeyType/ArrowDown)))

   (and (= input KeyType/Tab) (seq hs))
   (set-ui :buffer (models/complete buffer (nth hs (min index (dec (count hs)))))
    :index 0)

   (txt/edits? input buffer 300) (set-ui :buffer (txt/typed buffer input 300)
    :index 0)
   (txt/at-cap? input buffer 300) (assoc st :note (txt/too-long "path" 300))

   :else st)))

;; --- editing a cell

(defn start-edit
 "`st` with the row under the cursor open for editing: its name (a free label), the params
 of a polymer family or a custom polymer, mM, then ±. A row that is marked for removal, or
 no row, leaves `st` as it is."
 [st]
 (let [i (:cursor st)
   row (get-in st [:s :rows i])]
  (if (or (nil? row) (:removed? row))
   st
   (let [s (solutes/value row)
     ctx (editable-params s)]
    (open-field st
     i
     :name
     {:queue (vec (concat (when ctx [:params]) [:mM :sigma-mM])),
      :next-ctx ctx}
     nil)))))

(defn ^:private set-batch-field
 "`st` with `field` of every row of `batch` (or of row `i`) set to `v`."
 [st i batch field v]
 (reduce (fn [st j] (update st :s solutes/set-field j field v)) st (or batch [i])))

(defn ^:private params-enter
 "`st` after Enter in the params cell: the argument typed is taken and the next one asked,
 or the row's `arg` (a family) or `counts` (a custom polymer) is made and the edit goes on."
 [st]
 (let [{:keys [ctx text i], :as ui} (:ui st)
   k (:k ctx)]
  (if (= (:type ctx) :family)
   (let [{:keys [fam form-index]} ctx
     args (:args (nth (:forms fam) form-index))
     arg-key (:key (nth args k))
     problem (arg-problem fam form-index arg-key text)]
    (if problem
     (assoc st :note problem)
     (let [values (assoc (:values ctx) arg-key (str/trim text))]
      (if (< (inc k) (count args))
       (let [ctx (assoc ctx :values values :k (inc k))]
        (assoc st
         :ui
         (assoc ui :ctx ctx :text (ctx-initial-text ctx))))
       (let [{:keys [arg note]} (solute-index/family-arg fam form-index values)
         st (update st :s solutes/set-field i :arg arg)]
        (next-field st (assoc ui :hint note :next-ctx nil)))))))
   (let [{:keys [value error]} (parse-count text)]
    (if error
     (assoc st :note error)
     (let [counts (conj (:counts ctx) value)
       labels (:labels ctx)]
      (if (< (inc k) (count labels))
       (let [ctx (assoc ctx :counts counts :k (inc k))]
        (assoc st :ui (assoc ui :ctx ctx :text (ctx-initial-text ctx))))
       (let [row (row-solute st i)
         new-row (if (:entry ctx)
          (merge row (custom/snapshot (:entry ctx) counts))
          (assoc row :counts (mapv double counts)))]
        (next-field (set-new st i new-row) (assoc ui :next-ctx nil))))))))))

(defn ^:private edit-enter
 "`st` after Enter in the cell being typed into."
 [st]
 (let [{:keys [i field text batch], :as ui} (:ui st)]
  (if (= field :params)
   (params-enter st)
   (let [{:keys [value error]} (parse-field field text)]
    (if error
     (assoc st :note error)
     (let [st (set-batch-field st i batch field value)]
      (next-field st (cond-> ui (= field :mM) (assoc :hint nil)))))))))

(defn ^:private edit-step
 [st input]
 (let [{:keys [text add]} (:ui st)]
  (cond
   (or (= input KeyType/Escape) (= input KeyType/EOF))
   (if add (cancel-add st) (assoc st :ui nil))
   (= input KeyType/Enter) (edit-enter st)

   (txt/edits? input text max-typed)
   (update-in st [:ui :text] txt/typed input max-typed)
   (txt/at-cap? input text max-typed)
   (assoc st :note (txt/too-long "text" max-typed))

   :else st)))

(defn step
 "`st` after `input` while a flow is open (`(:ui st)` is not nil); `env` has `:pick-file`,
 a function of no arguments that opens the desktop's file picker and gives `{:files
 [path ...]}` or `{:problem text}`."
 [st input env]
 (case (get-in st [:ui :type])
  :name (let [r (name-pick-step (get-in st [:ui :pick]) input)]
   (cond (= r :cancel) (cancel-add st)
    (:chosen r) (picked st (:chosen r))
    :else (assoc-in st [:ui :pick] (:state r))))
  :form (let [r (picker/step (get-in st [:ui :pick]) input)
    {:keys [fam add from-cursor]} (:ui st)]
   (cond (= r :cancel) (cancel-add st)
    (:chosen r)
    (let [labels (mapv form-label (:forms fam))
      form-index (max 0
       (.indexOf ^java.util.List labels (:chosen r)))]
     (family-start st
      (first add)
      fam
      form-index
      {:add add, :from-cursor from-cursor}))
    :else (assoc-in st [:ui :pick] (:state r))))
  :nuc (let [r (picker/step (get-in st [:ui :pick]) input)
    {:keys [add from-cursor]} (:ui st)]
   (cond (= r :cancel) (cancel-add st)
    (:chosen r)
    (assoc st
     :ui
     (path-ui (first add)
      from-cursor
      (second (first (filter #(= (first %) (:chosen r))
         nucleotide-kinds)))))
    :else (assoc-in st [:ui :pick] (:state r))))
  :path (path-step st input (:pick-file env))
  :edit (edit-step st input)
  st))

;; --- what to draw

(defn edit-view
 "The cell being typed into, `{:i row :col column :text shown-text}` (the screen adds the
 cursor), or nil when no cell is open: the name cell while a name is searched, the cell of
 an edit. A params cell shows what is typed of every argument."
 [st]
 (let [{:keys [i field text ctx add pick], ui-type :type} (:ui st)]
  (case ui-type
   :name {:i (first add), :col 0, :text (:buffer pick)}
   :edit {:i i,
    :col (.indexOf ^java.util.List fields field),
    :text (if (= field :params) (ctx-text ctx text) text)}
   nil)))

(defn ^:private edit-note
 "The note while a cell is open: the prompt of a params argument, the hint kept for mM, or
 the reminder on a sequence's row."
 [st]
 (let [{:keys [field ctx hint i]} (:ui st)
   kind (:kind (row-solute st i))]
  (cond (= field :params) (ctx-prompt ctx)
   (and (= field :mM) hint) hint
   (and (= field :name) (contains? #{:dna :rna :protein} kind))
   "re-add to change the sequence")))

(defn ui-note
 "The border note for the flow in `st` (not counting a transient `:note`), or nil."
 [st]
 (case (get-in st [:ui :type])
  :name (let [{:keys [matches index]} (get-in st [:ui :pick])]
   (basis-note (:basis (nth matches index nil))))
  :edit (edit-note st)
  nil))

(defn row-note
 "The border note for the row under the cursor when nothing is open: the basis of a
 polymer's molarity (`mM per monomer unit`), or nil."
 [s]
 (when (= (:kind s) :polymer) (basis-note (solute-index/polymer-basis (:arg s)))))

(defn dropdown-lines
 "The lines `lines` of the page with the dropdown (or the path prompt) of the flow in `st`
 written over them, for the cell on body row `r` of a table of `window` rows; `art` is the
 table's art (the columns). `lines` itself when no dropdown is open."
 [lines st r art window]
 (let [spans (:spans art)
   col (first (first spans))
   width (- (second (nth spans 2)) col)
   place {:col col, :width width, :window window, :top (table/body-top art)}
   ui (:ui st)
   texts (fn [pick-state rows prefix]
    (let [{:keys [texts]} (picker/layout pick-state rows (- width 1))]
     (into (vec prefix) texts)))]
  (case (:type ui)
   :name (overlay-box lines
    (texts (pick-display (:pick ui) (- width 4)) dropdown-rows [])
    r
    place)
   (:form :nuc) (overlay-box lines
    (texts (:pick ui) dropdown-rows [])
    r
    place)
   :path (let [hs (path-hints (:buffer ui))
     shown (str "path: " (table/tail-text (:buffer ui) (- width 9)) "_")
     status (cond (str/blank? (:buffer ui)) "type a path, o: file picker"
      (empty? hs) "no hint"
      :else nil)]
    (overlay-box lines
     (texts {:matches hs,
       :index (min (:index ui) (max 0 (dec (count hs)))),
       :error status}
      (dec dropdown-rows)
      [(str " " shown)])
     r
     place))
   lines)))
