;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Parsing fitting-test runs into maps of numbers: `parse-log` reads a run log
;; (`<ID>.LOG`, see BAYSOL.write_log), the one file every tool looks at; `parse` reads a
;; text report (`res*.txt`), which the revisions before the logs keep their results in, so
;; `compare` can read them. A value a source lacks is the empty
;; string, so "defined" means `(seq v)`. The map carries its
;; keys in first-seen order as metadata (`(:order (meta r))`), since the TSV columns
;; follow that order.
;;
;; The stages of the timing table are read by name; the three stage variants of the
;; hydrogenation (`pdb2pqr`, `pdb2pqr (nucleic, none)`, `pdb2pqr (mixed, propka)`) are
;; one key, since a run records exactly one of them. A stage a report lacks is "".
;;
;; Every pattern below finds the last number on its line: after a greedy `.*` comes
;; `\s`, then the number.

(ns report
 (:require [clojure.string :as str]
  [common :refer [as-number num-re]]))

;; In a pattern, @N@ and @FLP@ are a number (one capture group), @NUM@ the same without
;; a capture group (to skip a column), @QTY@ a number with an optional k (x1000) or
;; M (x1000000) suffix (one capture group).
(def ^:private tokens
 {"@N@" num-re,
  "@FLP@" num-re,
  "@NUM@" "[-+]?\\d+\\.?\\d*(?:[eE][-+]?\\d+)?",
  "@QTY@" "([-+]?(?:\\d+(?:\\.\\d*)?|\\.\\d+)(?:[eE][-+]?\\d+)?[kM]?)"})

;; The compiled pattern with its tokens replaced. Line mode by default (`(?m)`: ^ and $
;; match at line ends; `(?d)`: only \n ends a line; `.` stops at a newline), the mode
;; of a line-oriented tool. Memoized: a report is read with ~150 patterns.
(def ^:private rx
 (memoize (fn [pat & [flags]]
   (re-pattern (str (or flags "(?md)")
     (reduce-kv str/replace (str pat) tokens))))))

(defn ^:private grab
 "First capture group of `pat` in `text`, \"\" if absent."
 [text pat]
 (or (second (re-find (rx pat) text)) ""))

(defn ^:private qty
 "'496.68k' -> 496680.0, '1.2M' -> 1.2e6, rounded to 6 decimals (so 8.03k is exactly
 8030.0, not 8029.999999999999)."
 [tok]
 (let [scale (case (last tok)
    \k 1e3
    \M 1e6
    1.0)
   x (parse-double (str/replace tok #"[kM]+$" ""))]
  (/ (double (Math/round (* x scale 1e6))) 1e6)))

(defn ^:private whole
 "x as an integer when it is a whole number."
 [x]
 (if (== x (Math/floor x)) (long x) x))

;; The one-line quantities of a report as [key pattern ...]. A line a report lacks
;; gives "".
(def ^:private entries
 [:n_atoms #"^n_atoms\s+= (\d+)" :lMax #"^lMax\s+= (\d+)" :n_q_raw
  #"^n_q_raw\s+= (\d+)" :n_q #"^n_q\s+= (\d+)" :n_samples #"^n_samples\s+= (\d+)"
  :n_adapt #"^n_adapt\s+= (\d+)" :rng_seed #"^rng_seed\s+= (\d+)" :dmax
  #"^Dₘₐₓ\s+= @FLP@ Å" :channels #"^channels\s+= @FLP@" :rebin_per_channel
  #"^rebin\s+= (\d+) per channel" :rebin_measured
  #"^rebin\s+= \d+ per channel: (\d+) measured" :rebin_fitted
  #"^rebin\s+= \d+ per channel: \d+ measured → (\d+) fitted points" :rebin_dropped
  (str #"^rebin\s+= \d+ per channel: \d+ measured → "
   #"\d+ fitted points \((\d+) non-positive dropped\)") :iterations
  #"^iterations\s+= (\d+)" :accept #"^mean_accept\s+= @FLP@" :depth
  #"^tree_depth\s+= @FLP@" :depth_max #"^tree_depth\s+=[^\n]*\(max (\d+)\)" :steps
  #"^mean_n_steps\s+= @FLP@" :ebfmi #"^EBFMI\s+= @FLP@" :cavity_frac
  #"^cavity_frac\s+= @FLP@" :sat #"^excl_vol_sat\s+= (\w+)" :div
  #"^divergence_rate\s+= @FLP@" :chains_pooled #"^chains\s+= (\d+) pooled of \d+"
  :chains_total #"^chains\s+= \d+ pooled of (\d+)" :rhat_max #"^rhat_max\s+= @FLP@"
  :ess_min #"^ess_min\s+= @FLP@" :ess_tail_min #"^ess_tail_min\s+= @FLP@" :modes
  #"^modes\s+= (\d+)" :optima #"^optima\s+= (\d+) with mass" :lgdn_MAP
  #"^log_density\s+= @FLP@" :rho_e_MAP #"^ρₑ\s+= @FLP@" :dro1_MAP #"^δρ₁\s+= @FLP@"
  :dro2_MAP #"^δρ₂\s+= @FLP@" :dro3_MAP #"^δρ₃\s+= @FLP@" :scale_MAP
  #"^scale\s+= @FLP@" :bkgrnd_MAP #"^bkgrnd_corr\s+= @FLP@" :excl_MAP
  #"^excl_vol_corr\s+= @FLP@" :chi2_MAP #"^χ²\s+= @FLP@" :quantile_lo
  #"^=== Quantiles \((\d+)-\d+\) ===" :quantile_hi
  #"^=== Quantiles \(\d+-(\d+)\) ==="
  ;; the `=== Timing ===` section
  :wall #"^wall clock.*\s@FLP@\s+100\.0" :static_build #"^\s+static build\s+@FLP@"
  :resolve_structure #"^\s+resolve_structure\s+@FLP@" :components
  #"^\s+components.*\s@FLP@\s*$" :components_download
  #"^\s+components(?:[^\n]*\n\s*)?[^\n]*, (\d+) download\]" :structure_checks
  #"^\s+structure checks.*\s@FLP@\s*$" :classify #"^\s+classify.*\s@FLP@\s*$"
  :propka #"^\s+propka.*\s@FLP@\s*$" :pdb2pqr #"^\s+pdb2pqr.*\s@FLP@\s*$"
  :modified_hydrogens #"^\s+modified nucleotide hydrogens.*\s@FLP@\s*$"
  :modified_amino_hydrogens #"^\s+modified amino acid hydrogens.*\s@FLP@\s*$"
  :heavy_atoms #"^\s+heavy atoms.*\s@FLP@\s*$" :load_molecule
  #"^\s+load_molecule\s+@FLP@" :sasa #"^\s+SASA\s+@FLP@" :shannon
  #"^\s+shannon \(diameter, binning\)\s+@FLP@" :fwd #"^\s+forward_cache\s+@FLP@"
  :vacuum_excluded #"^\s+vacuum \+ excluded volume \(vols \+ B_lm\)\s+@FLP@"
  :hydration #"^\s+hydration \(B_lm\)\s+@FLP@" :gram_rm #"^\s+Gram \+ r_m\s+@FLP@"
  :seed_fitting #"^\s+seed_(?:fitting|sampler) \(priors, WLS\)\s+@FLP@" :sampling
  #"^\s+sampling\s+@FLP@" :map_s #"^\s+MAP search \+ whitening .*\)\s+@FLP@\s*$"
  :nuts_setup #"^\s+NUTS setup \(.*\)\s+@FLP@\s*$" :nuts
  #"^\s+NUTS\s+\(.*\)\s+@FLP@\s*$" :reprofile
  #"^\s+per-draw c1 re-profile.*\)\s+@FLP@\s*$" :map_quantiles
  #"^\s+MAP \+ quantiles\s+@FLP@" :report_write #"^\s+report write\s+@FLP@"
  :unaccounted #"^\s+unaccounted\s+@FLP@" :gc #"^GC: @FLP@" :fit_timing
  #"^fit timing\s+= @FLP@" :plot_timing #"^plot timing\s+= @FLP@" :map_starts_ok
  #"^\s+MAP search \+ whitening \((\d+)/\d+ starts" :map_starts_total
  #"^\s+MAP search \+ whitening \(\d+/(\d+) starts" :map_modes
  #"^\s+MAP search \+ whitening \(\d+/\d+ starts, (\d+) modes?"
  ;; counts with a k or M suffix, stored as plain numbers
  :nuts_iters #"^\s+NUTS\s+\(@QTY@ iters" :leapfrog
  #"^\s+NUTS\s+\(\S+ iters, @QTY@ leapfrog" :ms_per_step
  #"^\s+NUTS\s+\(\S+ iters, \S+ leapfrog, @QTY@ ms/step\)" :draws
  #"^\s+per-draw c1 re-profile.*\((\d+) draws\)"])

;; The parameter rows: [prefix label]. Each has the quantile and bound columns of the
;; `=== Quantiles ===` table; the four with a prior also the z-score columns.
(def ^:private params
 [[:lgdn "log_density"] [:rho_e "ρₑ"] [:dro1 "δρ₁"] [:dro2 "δρ₂"] [:dro3 "δρ₃"]
  [:scale "scale"] [:bkgrnd "bkgrnd_corr"] [:excl "excl_vol_corr"] [:chi2 "χ²"]])

(defn ^:private columns
 "[key pattern] pairs for the columns `cols` of the table rows labelled `<label>_<tag>`
 of the parameters `ps`: column i is the (i+1)-th number after the label."
 [ps tag cols]
 (for [[p label] ps
   [i col] (map-indexed vector cols)]
  [(keyword (str (name p) "_" col))
   (str "^" label "_" tag "\\s+" (str/join (repeat i "@NUM@\\s+")) "@FLP@")]))

(def ^:private table-entries
 (concat (columns params "Q" ["QUANT_LO" "QUANT_HI" "BOUND_LO" "BOUND_HI"])
  (columns (subvec params 1 5) "Z" ["Z_MAP" "Z_QUANT_LO" "Z_QUANT_HI"])))

;; Later passes re-read lines the ones above already took, so a key set twice keeps its
;; first position and takes the last value (see `put`). Patterns here use @N@: the
;; values are the ones the tools compare.
(def ^:private sampler-quality
 [:div #"^divergence_rate = @N@" :steps #"^mean_n_steps\s+= @N@" :depth
  #"^tree_depth\s+= @N@" :accept #"^mean_accept\s+= @N@" :ebfmi #"^EBFMI\s+= @N@"])

(def ^:private fit-quality
 [:chi2 #"^χ²\s+= @N@" :c1 #"^excl_vol_corr\s+= @N@" :sat #"^excl_vol_sat\s+= (\w+)"
  :rho_e #"^ρₑ\s+= @N@" :d1 #"^δρ₁\s+= @N@" :d2 #"^δρ₂\s+= @N@" :d3
  #"^δρ₃\s+= @N@"])

(def ^:private timing
 [:wall #"^wall clock.*\s@N@\s+100\.0" :fwd #"^\s+forward_cache\s+@N@" :propka
  #"^\s+propka.*\s@N@\s*$" :pdb2pqr #"^\s+pdb2pqr.*\s@N@\s*$" :map_s
  #"^\s+MAP search \+ whitening .*\)\s+@N@\s*$" :reprofile
  #"^\s+per-draw c1 re-profile.*\)\s+@N@\s*$" :gc #"^GC: @N@"])

(def ^:private n-modes-re #"MAP search \+ whitening \(\d+/\d+ starts, (\d+) modes?")

(def ^:private share-re
 #"^mode_\d+\s+= chains [\d,]+, share ([\d.]+(?:e[-+]?\d+)?)")

;; "NUTS  (2k iters, 496.68k leapfrog, 0.2 ms/step)   <seconds>"
(def ^:private nuts-re
 #"NUTS  \(([\d.]+k?) iters, ([\d.]+[kM]?) leapfrog, ([\d.]+) ms/step\)\s+@N@")

;; The map being built, with its keys in first-seen order: {:ks [k ...] :m {k v ...}}.
(defn ^:private put
 [st k v]
 (-> st
  (update :ks #(if (contains? (:m st) k) % (conj % k)))
  (assoc-in [:m k] v)))

(defn ^:private puts [st kvs] (reduce (fn [s [k v]] (put s k v)) st kvs))

(defn ^:private grabs
 "[key value] pairs from the flat [key pattern ...] list."
 [text kv-flat]
 (for [[k pat] (partition 2 kv-flat)] [k (grab text pat)]))

(defn ^:private by-value
 "The largest (`max-key`) or smallest value among the strings `shares`, as a number,
 \"\" if there are none."
 [pick shares]
 (if (seq shares) (as-number (apply pick parse-double shares)) ""))

;; The notes of the timing table. Today a stage prints its note on a line of its own under
;; it (`    classify   <seconds>` then `      [nucleic: AMBER, titration none]`); older
;; reports print `<name>  [note]  <seconds>` on one line, where the name and the note can
;; touch (`pdb2pqr (mixed, propka)[cache hit]`, a name longer than the label column), so
;; the note is cut at its first `[` and last `]`.
(def ^:private note-re #"^\s+([^\[\n]*?)\s*(\[.*\])\s")

(def ^:private note-line-re #"^\s+(\[.*\])\s*$")

(def ^:private stage-numbers-re
 #"(\s+[-+]?\d[\d.]*(?:e[-+]?\d+)?){1,2}(\s+\([\d.]+\))?\s*$")

(defn stage-notes
 "The notes of the stages in the `=== Timing ===` section of `text`, as a map from
 stage name to note (`{\"classify\" \"[nucleic: AMBER, titration none]\"}`), in either
 layout; a note wrapped over several lines is joined with single spaces. A stage
 without a note (and a report without the section) is absent from the map."
 [text]
 (let [section (or (second (re-find #"(?ms)^=== Timing ===[^\n]*\n(.*)" text))
    ;; a timing file is the table alone, below its column-label line
    (when-not (str/includes? text "=== ")
     (second (re-find #"(?s)\A[^\n]*\n(.*)" text))))]
  (loop [lines (str/split-lines (or section ""))
    prev nil
    open nil
    notes {}]
   (if-let [line (first lines)]
    (let [[_ own] (re-find note-line-re line)
      [_ nm note] (re-find note-re (str line " "))]
     (cond
      ;; the lines of a wrapped note up to the one that closes it
      open (let [joined (str (:text open) " " (str/trim line))]
       (if (str/ends-with? (str/trim line) "]")
        (recur (rest lines) nil nil (assoc notes (:name open) joined))
        (recur (rest lines) prev (assoc open :text joined) notes)))
      (and prev (re-find #"^\s+\[" line) (not own))
      (recur (rest lines) prev {:name prev, :text (str/trim line)} notes)
      (and own prev) (recur (rest lines) nil nil (assoc notes prev own))
      (and note (not own)) (recur (rest lines) nil nil (assoc notes nm note))
      :else (recur (rest lines)
       (str/trim (str/replace line stage-numbers-re ""))
       nil
       notes)))
    notes))))

(def ^:private or-zero
 "A number from the string `v`, 0 if it is empty."
 #(if (seq %) (as-number %) 0))

(defn ^:private wall-ex
 "The wall clock of the run map `m` without the startup (before `seed_model`), the
 external-tool time (PROPKA and every `pdb2pqr*` stage, which depend on the cache, and a
 component download) and without
 the plotting (`plot timing`, which older reports lack: the fit is what is compared),
 the convention for every comparison; \"\" without a wall clock. A stage a report
 lacks (an older format) contributes nothing. The seconds of the `components` stage
 count as download time when its note says `N download`, N > 0: network time, not
 computing, and the stage cannot split it from the table load."
 [{:keys [wall startup propka pdb2pqr components components_download plot_timing]}]
 (if (seq wall)
  (- (as-number wall)
   (or-zero startup)
   (or-zero propka)
   (or-zero pdb2pqr)
   (if (pos? (or-zero components_download)) (or-zero components) 0)
   (or-zero plot_timing))
  ""))

(defn parse
 "The numbers of one report as a map; a key is \"\" where a revision's format lacks it.
 The map also carries `:stage_notes` (see `stage-notes`), which is not one of the
 ordered keys, so the TSV and CSV outputs leave it out."
 [text]
 (let [g (partial grab text)
   ;; a quantity with a k or M suffix is stored as the plain number
   quantity
   (fn [[k pat]]
    (let [v (g pat)]
     [k
      (if (and (str/includes? (str pat) "@QTY@") (seq v)) (whole (qty v)) v)]))
   ;; the mass shares of the posterior modes (each has a `mode_<k>` line)
   shares (map second (re-seq (rx share-re) text))
   ;; the NUTS line: groups are iterations, leapfrog steps, ms/step, seconds
   [_ _ leap ms secs] (re-find (rx nuts-re) text)
   ;; the z-score of the MAP δρ₃ from the prior: the number after its row
   ;; label. The label is found first (lazily, across lines), then the number
   ;; after it; a later δρ₃ label is not tried if the first has no number.
   z3 (let [m (re-matcher #"(?ms)=== Standard deviations from prior.*?^δρ₃"
      text)]
    (if (.find m) (grab (subs text (.end m)) #"\A\s*@N@") ""))
   st (puts {:ks [], :m {}}
    (concat (map quantity (partition 2 entries))
     (map quantity table-entries)
     [[:mode_share_max (by-value max-key shares)]
      [:mode_share_min (by-value min-key shares)]
      ;; chains that were not pooled (a `chain_dropped` line
      ;; each)
      [:chains_dropped
       (count (re-seq (rx #"^chain_dropped\s+=") text))]]
     (grabs text sampler-quality)
     (grabs text fit-quality)))
   ;; the Shannon-binned fit's χ² on the measured grid (reports since Shannon
   ;; binning only), and the χ² every comparison uses: that one when there is
   ;; one, else the (unbinned) fit's own
   raw (g #"^measured grid\s+lag-1.*χ²_red\s+@N@")
   st (puts st
    (concat [[:chi2_raw raw]
      [:chi2_cmp (if (seq raw) raw (get-in st [:m :chi2]))]]
     (grabs text timing)
     [[:leapfrog (if leap (qty leap) "")] [:ms_step (or ms "")]
      [:nuts (or secs "")]
      ;; reports since the `_Z` row labels have it in its own key
      [:z3 (if (seq z3) z3 (get-in st [:m :dro3_Z_MAP]))]
      ;; number of distinct local optima the MAP search found
      [:n_modes (g n-modes-re)]]))
   st (put st :wall_ex (wall-ex (:m st)))]
  (with-meta (assoc (:m st) :stage_notes (stage-notes text)) {:order (:ks st)})))

;; --- the run log

(def ^:private log-keys
 "The key of the run map <- the row of a log section (its first value), in the order the
 map lists them. The map has the keys `parse` makes, so the tools read either source."
 [[:n_atoms "n_atoms"] [:lMax "lmax"] [:dmax "dmax"] [:n_q_raw "n_q_raw"]
  [:n_q "n_q"] [:n_samples "n_samples"] [:n_adapt "n_adapt"] [:rng_seed "rng_seed"]
  [:baysol "baysol"] [:structure "structure"] [:ref_chi2 "ref_chi2"] [:chi2 "chi2"]
  [:chi2_MAP "chi2"] [:chi2_cmp "chi2"] [:rho_e "rho_e"] [:rho_e_MAP "rho_e"]
  [:d1 "delta_rho_1"] [:dro1_MAP "delta_rho_1"] [:d2 "delta_rho_2"]
  [:dro2_MAP "delta_rho_2"] [:d3 "delta_rho_3"] [:dro3_MAP "delta_rho_3"]
  [:scale_MAP "scale"] [:bkgrnd_MAP "bkgrnd_corr"] [:c1 "c1"] [:excl_MAP "c1"]
  [:z3 "z_delta_rho_3"] [:dro3_Z_MAP "z_delta_rho_3"] [:cavity_frac "cavity_frac"]
  [:div "divergence_rate"] [:n_divergent "n_divergent"] [:rhat_max "rhat_max"]
  [:ess_min "ess_min"] [:ess_tail_min "ess_tail_min"] [:ebfmi "ebfmi"]
  [:accept "mean_accept"] [:depth "tree_depth_avg"] [:depth_max "tree_depth_max"]
  [:steps "mean_n_steps"] [:iterations "iterations"] [:leapfrog "leapfrog"]
  [:ms_step "ms_step"] [:ms_per_step "ms_step"] [:chains_pooled "chains_pooled"]
  [:chains_total "chains_run"] [:modes "modes"] [:optima "optima"]
  [:mode_share_max "mode_share_max"] [:mode_share_min "mode_share_min"]
  [:map_starts_ok "map_starts_ok"] [:map_starts_total "map_starts_total"]
  [:map_modes "map_modes"] [:n_modes "map_modes"]
  [:components_download "components_download"]])

(def ^:private log-stages
 "The key of the run map <- the stage of the timing table of a log section (the stage's
 name without what it carries in parentheses or after a comma; the seconds)."
 {"wall clock" :wall,
  "startup" :startup,
  "static build" :static_build,
  "resolve_structure" :resolve_structure,
  "components" :components,
  "structure checks" :structure_checks,
  "classify" :classify,
  "propka" :propka,
  "pdb2pqr" :pdb2pqr,
  "modified nucleotide hydrogens" :modified_hydrogens,
  "modified amino acid hydrogens" :modified_amino_hydrogens,
  "heavy atoms" :heavy_atoms,
  "load_molecule" :load_molecule,
  "SASA" :sasa,
  "shannon" :shannon,
  "forward_cache" :fwd,
  "vacuum + excluded volume" :vacuum_excluded,
  "hydration" :hydration,
  "Gram + r_m" :gram_rm,
  "seed_sampler" :seed_fitting,
  "sampling" :sampling,
  "MAP search + whitening" :map_s,
  "NUTS setup" :nuts_setup,
  "NUTS" :nuts,
  "optima from the draws" :optima_s,
  "per-draw c1 re-profile + curves" :reprofile,
  "MAP + quantiles" :map_quantiles,
  "plotting" :plotting,
  "report write" :report_write,
  "unaccounted" :unaccounted})

;; a row of the timing table: indent, stage, seconds, % wall, (JIT), (GC), then the notes,
;; if there are any, after two spaces
(def ^:private timing-row-re
 #"^( *)(\S.*?)\s+(-?\d\S*)\s+(-?\d\S*)\s+\((\S+)\)\s+\((\S+)\)(?:\s{2}(.*?))?\s*$")

(defn ^:private timing-values
 "What a log section's timing table (its lines) says: {:kvs {key value ...} :notes
 {stage \"[note]\" ...}}. The `kvs` are the seconds of each stage, the process's `GC`,
 the `fit timing` and the `plot timing`, and what the notes carry (the MAP search's
 starts
 and modes, the NUTS iterations, leapfrog steps and ms/step, the draws re-profiled); the
 first row of a stage name wins. A stage's note comes back in square brackets, the shape
 the text reports had."
 [lines]
 (let [rows (keep #(re-matches timing-row-re %) lines)
   by-stage
   (reduce (fn [m [_ _ stage secs _ _ _ note]]
     (if (contains? m stage) m (assoc m stage {:secs secs, :note note})))
    {}
    rows)
   note (fn [stage] (get-in by-stage [stage :note] ""))
   [_ _ leap ms]
   (re-find #"([\d.]+[kM]?) iters, ([\d.]+[kM]?) leapfrog, ([\d.]+) ms/step"
    (note "NUTS"))
   [_ ok total modes] (re-find #"(\d+)/(\d+) starts, (\d+) modes?"
    (note "MAP search + whitening"))
   line (fn [re] (first (filter #(re-find re %) lines)))]
  {:kvs (merge (into {}
     (for [[stage k] log-stages
       :when (contains? by-stage stage)]
      [k (get-in by-stage [stage :secs])]))
    {:gc (if-let [l (line #"^GC: ")]
      (grab l #"^GC: @N@")
      ""),
     :fit_timing (if-let [l (line #"^fit timing")]
      (grab l #"^fit timing\s+= @N@")
      ""),
     :plot_timing (if-let [l (line #"^plot timing")]
      (grab l #"^plot timing\s+= @N@")
      ""),
     :leapfrog_label (if leap (whole (qty leap)) ""),
     :ms_step_label (or ms ""),
     :map_starts_ok_label (or ok ""),
     :map_starts_total_label (or total ""),
     :map_modes_label (or modes ""),
     :draws (or (second (re-find #"(\d+) draws"
        (note
         "per-draw c1 re-profile + curves")))
      "")}),
   :notes (into {}
    (for [[stage {:keys [note]}] by-stage
      :when (seq note)]
     [stage (str "[" note "]")]))}))

(defn ^:private log-sections
 "The sections of a log's text, in file order: [title lines], the lines of the section
 (the stamp before the first section is in none)."
 [text]
 (reduce (fn [out line]
   (if-let [[_ title] (re-matches #"=== (.*) ===" line)]
    (conj out [title []])
    (if (empty? out) out (update-in out [(dec (count out)) 1] conj line))))
  []
  (str/split-lines text)))

(defn ^:private split-blocks
 "The lines of a section split at its `--- name ---` markers: {:stats [...] :timing
 [...] :machine [...]}; the lines before the first marker are the stats."
 [lines]
 (loop [ls lines
   cur :stats
   out {}]
  (if-let [line (first ls)]
   (if-let [[_ nm] (re-matches #"--- (\w+) ---" line)]
    (recur (rest ls) (keyword nm) out)
    (recur (rest ls) cur (update out cur (fnil conj []) line)))
   out)))

(defn ^:private rows-of
 "The rows `name<tab>value` of lines, as {name [value ...]} (the cells trimmed; blank
 lines skipped)."
 [lines]
 (into {}
  (for [l lines
    :when (not (str/blank? l))
    :let [[k & vs] (map str/trim (str/split l #"\t"))]]
   [k (vec vs)])))

(defn ^:private log-run
 "The run map of one section's lines."
 [lines]
 (let [{:keys [stats machine], timing-lines :timing} (split-blocks lines)
   m (merge (rows-of stats) (rows-of machine))
   v (fn [k] (or (first (get m k)) ""))
   {:keys [kvs notes]} (timing-values timing-lines)
   base (into {} (for [[k lk] log-keys] [k (v lk)]))
   base (merge base
    (into {} (for [k (vals log-stages)] [k (get kvs k "")]))
    (select-keys kvs [:gc :fit_timing :plot_timing :draws])
    ;; the leapfrog steps, ms/step and MAP search of the notes, where the
    ;; stats rows do not have them
    (into {}
     (for [[k lab] [[:leapfrog :leapfrog_label]
        [:ms_step :ms_step_label]
        [:ms_per_step :ms_step_label]
        [:map_starts_ok :map_starts_ok_label]
        [:map_starts_total :map_starts_total_label]
        [:map_modes :map_modes_label]
        [:n_modes :map_modes_label]]
       :when (empty? (get base k ""))]
      [k (get kvs lab "")])))
   ;; the flag of c1 on its bound, as the text reports wrote it
   base (assoc base
    :sat
    (case (v "c1_sat")
     "" ""
     "0" "false"
     "true"))
   ks (concat (map first log-keys)
    (vals log-stages)
    [:gc :fit_timing :plot_timing :draws :sat :wall_ex])]
  (with-meta (assoc base :stage_notes notes :wall_ex (wall-ex base))
   {:order (vec ks)})))

(defn parse-log
 "The runs of the text of a run log: a vector of [title run-map], in file order. A run
 map has the keys `parse` makes (`:chi2`, `:d1`, `:div`, `:wall`, ...), and `:ref_chi2`
 (the reference χ² text, the depositor's, \"\" if the log has none); a value the log
 lacks is \"\"."
 [text]
 (vec (for [[title lines] (log-sections text)] [title (log-run lines)])))
