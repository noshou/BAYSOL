;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Parsing one fitting-test run into a map of numbers: `parse-run` reads the run's
;; workbook (`res*.xlsx`, see workbook.clj) and its timing file (`res*_timings.txt`);
;; `parse` reads a text report (`res*.txt`), which the revisions before the workbook keep
;; their results in, so `compare` can read them. A value a source lacks is the empty
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
        [common :refer [as-number num-re]]
        [workbook]))

(defn timings-path
    "The timing file that goes with the workbook at `xlsx-path`: `res_x.xlsx` ->
    `res_x_timings.txt`."
    [xlsx-path]
    (str/replace (str xlsx-path) #"\.xlsx$" "_timings.txt"))

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
        #"^rebin\s+= \d+ per channel: \d+ measured → (\d+) fitted points"
        :rebin_dropped
        (str #"^rebin\s+= \d+ per channel: \d+ measured → "
            #"\d+ fitted points \((\d+) non-positive dropped\)") :iterations
        #"^iterations\s+= (\d+)" :accept #"^mean_accept\s+= @FLP@" :depth
        #"^tree_depth\s+= @FLP@" :depth_max #"^tree_depth\s+=[^\n]*\(max (\d+)\)"
        :steps #"^mean_n_steps\s+= @FLP@" :ebfmi #"^EBFMI\s+= @FLP@" :cavity_frac
        #"^cavity_frac\s+= @FLP@" :sat #"^excl_vol_sat\s+= (\w+)" :div
        #"^divergence_rate\s+= @FLP@" :chains_pooled #"^chains\s+= (\d+) pooled of \d+"
        :chains_total #"^chains\s+= \d+ pooled of (\d+)" :rhat_max
        #"^rhat_max\s+= @FLP@" :ess_min #"^ess_min\s+= @FLP@" :ess_tail_min
        #"^ess_tail_min\s+= @FLP@" :modes #"^modes\s+= (\d+)" :optima
        #"^optima\s+= (\d+) with mass" :lgdn_MAP #"^log_density\s+= @FLP@" :rho_e_MAP
        #"^ρₑ\s+= @FLP@" :dro1_MAP #"^δρ₁\s+= @FLP@" :dro2_MAP #"^δρ₂\s+= @FLP@"
        :dro3_MAP #"^δρ₃\s+= @FLP@" :scale_MAP #"^scale\s+= @FLP@" :bkgrnd_MAP
        #"^bkgrnd_corr\s+= @FLP@" :excl_MAP #"^excl_vol_corr\s+= @FLP@" :chi2_MAP
        #"^χ²\s+= @FLP@" :quantile_lo #"^=== Quantiles \((\d+)-\d+\) ===" :quantile_hi
        #"^=== Quantiles \(\d+-(\d+)\) ==="
        ;; the `=== Timing ===` section
        :wall #"^wall clock.*\s@FLP@\s+100\.0" :static_build
        #"^\s+static build\s+@FLP@" :resolve_structure #"^\s+resolve_structure\s+@FLP@"
        :components #"^\s+components.*\s@FLP@\s*$" :components_download
        #"^\s+components(?:[^\n]*\n\s*)?[^\n]*, (\d+) download\]" :structure_checks
        #"^\s+structure checks.*\s@FLP@\s*$" :classify #"^\s+classify.*\s@FLP@\s*$"
        :propka #"^\s+propka.*\s@FLP@\s*$" :pdb2pqr #"^\s+pdb2pqr.*\s@FLP@\s*$"
        :modified_hydrogens #"^\s+modified nucleotide hydrogens.*\s@FLP@\s*$"
        :modified_amino_hydrogens #"^\s+modified amino acid hydrogens.*\s@FLP@\s*$"
        :heavy_atoms #"^\s+heavy atoms.*\s@FLP@\s*$" :load_molecule
        #"^\s+load_molecule\s+@FLP@" :sasa #"^\s+SASA\s+@FLP@" :shannon
        #"^\s+shannon \(diameter, binning\)\s+@FLP@" :fwd #"^\s+forward_cache\s+@FLP@"
        :vacuum_excluded #"^\s+vacuum \+ excluded volume \(vols \+ B_lm\)\s+@FLP@"
        :hydration #"^\s+hydration \(B_lm\)\s+@FLP@" :gram_rm
        #"^\s+Gram \+ r_m\s+@FLP@" :seed_fitting
        #"^\s+seed_(?:fitting|sampler) \(priors, WLS\)\s+@FLP@" :sampling
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
        #"^tree_depth\s+= @N@" :accept #"^mean_accept\s+= @N@" :ebfmi
        #"^EBFMI\s+= @N@"])

(def ^:private fit-quality
    [:chi2 #"^χ²\s+= @N@" :c1 #"^excl_vol_corr\s+= @N@" :sat
        #"^excl_vol_sat\s+= (\w+)" :rho_e #"^ρₑ\s+= @N@" :d1 #"^δρ₁\s+= @N@" :d2
        #"^δρ₂\s+= @N@" :d3 #"^δρ₃\s+= @N@"])

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
                                (recur (rest lines)
                                    nil
                                    nil
                                    (assoc notes (:name open) joined))
                                (recur (rest lines)
                                    prev
                                    (assoc open :text joined)
                                    notes)))
                        (and prev (re-find #"^\s+\[" line) (not own))
                        (recur (rest lines)
                            prev
                            {:name prev, :text (str/trim line)}
                            notes)
                        (and own prev)
                        (recur (rest lines) nil nil (assoc notes prev own))
                        (and note (not own))
                        (recur (rest lines) nil nil (assoc notes nm note))
                        :else (recur (rest lines)
                            (str/trim
                                (str/replace line stage-numbers-re ""))
                            nil
                            notes)))
                notes))))

(defn parse
    "The numbers of one report as a map; a key is \"\" where a revision's format lacks it.
    The map also carries `:stage_notes` (see `stage-notes`), which is not one of the
    ordered keys, so the TSV and CSV outputs leave it out."
    [text]
    (let [g (partial grab text)
            ;; a quantity with a k or M suffix is stored as the plain number
            quantity (fn [[k pat]]
                (let [v (g pat)]
                    [k
                        (if (and (str/includes? (str pat) "@QTY@") (seq v))
                            (whole (qty v))
                            v)]))
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
                    [[:leapfrog (if leap (qty leap) "")]
                        [:ms_step (or ms "")] [:nuts (or secs "")]
                        ;; reports since the `_Z` row labels have it in its own key
                        [:z3 (if (seq z3) z3 (get-in st [:m :dro3_Z_MAP]))]
                        ;; number of distinct local optima the MAP search found
                        [:n_modes (g n-modes-re)]]))
            {:keys [wall propka pdb2pqr components components_download plot_timing]}
            (:m st)
            or-zero #(if (seq %) (as-number %) 0)
            ;; the seconds of the `components` stage when it downloaded a component (its
            ;; note says `N download`, N > 0): network time, not computing, and the
            ;; stage cannot split it from the table load. A lookup that downloaded
            ;; nothing is computing and stays in the wall clock.
            download-s
            (if (pos? (or-zero components_download)) (or-zero components) 0)
            ;; wall clock without the external-tool time (PROPKA and every `pdb2pqr*`
            ;; stage, which depend on the cache, and a component download) and
            ;; without the plotting (`plot timing`, which older reports lack: the
            ;; fit is what is compared), the convention for every comparison. A
            ;; stage a report lacks (an older format) contributes nothing.
            st (put st
                :wall_ex
                (if (seq wall)
                    (- (as-number wall)
                        (or-zero propka)
                        (or-zero pdb2pqr)
                        download-s
                        (or-zero plot_timing))
                    ""))]
        (with-meta (assoc (:m st) :stage_notes (stage-notes text))
            {:order (:ks st)})))

;; The workbook's names for the parameters, and the prefix of their keys in the map.
(def ^:private param-prefix
    {"log_density" :lgdn,
        "rho_e" :rho_e,
        "delta_rho_1" :dro1,
        "delta_rho_2" :dro2,
        "delta_rho_3" :dro3,
        "scale" :scale,
        "bkgrnd_corr" :bkgrnd,
        "excl_vol_corr" :excl,
        "chi2" :chi2})

;; Keys of the `run` sheet: key of the map <- row of the sheet.
(def ^:private run-rows
    {:n_atoms "n_atoms",
        :lMax "lmax",
        :n_q_raw "n_q_raw",
        :n_q "n_q",
        :n_samples "n_samples",
        :n_adapt "n_adapt",
        :rng_seed "rng_seed",
        :dmax "dmax",
        :channels "channels",
        :rebin_per_channel "rebin_channels",
        :rebin_measured "rebin_measured",
        :rebin_fitted "rebin_fitted",
        :rebin_dropped "rebin_non_positive_dropped",
        :iterations "iterations",
        :accept "mean_accept",
        :depth "tree_depth_avg",
        :depth_max "tree_depth_max",
        :steps "mean_n_steps",
        :ebfmi "ebfmi",
        :cavity_frac "cavity_frac",
        :div "divergence_rate",
        :chains_pooled "chains_pooled",
        :chains_total "chains_run",
        :rhat_max "rhat_max",
        :ess_min "ess_min",
        :ess_tail_min "ess_tail_min",
        :modes "modes",
        :optima "optima"})

(defn ^:private table
    "The rows of a sheet below its header as maps of column name -> cell text."
    [rows]
    (let [header (first rows)] (for [r (rest rows)] (zipmap header r))))

(defn ^:private sheet-values
    "The workbook's numbers as [key value] pairs for the map `parse-run` builds."
    [sheets]
    (let [run (into {}
                (map (juxt #(get % "key") #(get % "value")))
                (table (get sheets "run")))
            qname (first (filter #(str/starts-with? % "quantiles_") (keys sheets)))
            [q-lo q-hi] (some-> qname
                (subs (count "quantiles_"))
                (str/split #"-"))
            by-param (fn [sheet]
                (for [r (table (get sheets sheet))
                        :let [p (param-prefix (get r "parameter"))]
                        :when p]
                    [p r]))
            shares (map #(get % "share") (table (get sheets "modes")))
            share-of
            (fn [pick]
                (if (seq shares) (as-number (apply pick parse-double shares)) ""))]
        (concat (for [[k row] run-rows] [k (get run row "")])
            [[:sat
                    (if-let [v (get run "excl_vol_sat")]
                        (if (zero? (parse-double v)) "false" "true")
                        "")]
                [:chains_dropped
                    (if (and (get run "chains_run") (get run "chains_pooled"))
                        (- (parse-long (get run "chains_run"))
                            (parse-long (get run "chains_pooled")))
                        0)] [:quantile_lo (or q-lo "")] [:quantile_hi (or q-hi "")]
                [:mode_share_max (share-of max-key)]
                [:mode_share_min (share-of min-key)]]
            (for [[p r] (by-param "map")
                    :let [v (get r "value")]
                    kv (concat [[(keyword (str (name p) "_MAP")) v]]
                        (case p
                            :chi2 [[:chi2 v]]
                            :excl [[:c1 v]]
                            :rho_e [[:rho_e v]]
                            :dro1 [[:d1 v]]
                            :dro2 [[:d2 v]]
                            :dro3 [[:d3 v]]
                            []))]
                kv)
            (for [[p r] (by-param qname)
                    [k col] [["QUANT_LO" "quantile_lo"] ["QUANT_HI" "quantile_hi"]
                        ["BOUND_LO" "bound_lo"] ["BOUND_HI" "bound_hi"]]]
                [(keyword (str (name p) "_" k)) (get r col)])
            (for [[p r] (by-param "stdev_from_prior")
                    [k col] [["Z_MAP" "z_map"] ["Z_QUANT_LO" "z_quantile_lo"]
                        ["Z_QUANT_HI" "z_quantile_hi"]]]
                [(keyword (str (name p) "_" k)) (get r col)]))))

(defn parse-run
    "The numbers of one run as a map like `parse`'s: `sheets` are the run's workbook
    (`workbook/read-sheets`) and `timings` the text of its timing file. A quantity the
    workbook lacks is \"\". The measured-grid χ² is the MAP's χ² in the workbook, so
    `:chi2_cmp` is that."
    [sheets timings]
    (let [base (parse timings)
            kvs (sheet-values sheets)
            m (reduce (fn [m [k v]] (assoc m k v)) base kvs)
            m (assoc m :z3 (get m :dro3_Z_MAP "") :chi2_cmp (get m :chi2 ""))]
        (with-meta m (meta base))))
