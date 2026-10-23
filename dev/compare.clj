#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Compare fitting-test results between git revisions and the working tree.
;;
;;     bb compare [REV ...] [--no-tree] [--csv out.csv] [--csv-all all.csv]
;;     bb compare --bench old.json new.json
;;
;; Each REV is any git revision (tag, branch, commit hash, `HEAD~3`, ...). With none given
;; the comparison is with the LATEST RELEASE (the newest tag whose name starts with `v` and
;; a digit, found with `git for-each-ref`): a result is always judged against the version
;; users have, not against an arbitrary older one. Name any revisions to compare with those
;; instead. The columns appear in the order given, followed by the working tree, which is
;; the one being judged: every speedup and every χ² comparison is "last column against each
;; of the others". `--no-tree` drops the working tree, so the last REV is judged instead.
;;
;; Reads every `test/fitting_tests/*/res*.txt` at each REV via `git show` (no
;; checkout, nothing rerun) and prints, over the fits present in every column: the
;; time of every stage, fit quality (the χ² spread and the parameter distributions),
;; sampler health (acceptance, tree depth, steps, E-BFMI, divergences, chains, R-hat,
;; ESS), the MAP search, the problem sizes, the posterior widths and the worst fits.
;; `--csv` writes a fixed set of per-fit numbers, `--csv-all` every parsed key.
;; `--bench` instead compares the JSON results of `bb bench` (cold/steady
;; benchmarks): the last file is the one judged, and with a single file it is compared
;; with the newest baseline of the latest release in test/baselines/ (README there).
;;
;; Examples:
;;     bb compare v0.1.0-sɩngre v0.2.0-soukouratou HEAD
;;         three tags/commits against the tree
;;     bb compare HEAD~2 HEAD --no-tree
;;         two commits only
;;     bb compare
;;         the working tree against the latest release
;;     bb compare --bench baseline.json new.json
;;         cold/steady benchmark results
;;     bb compare --bench new.json
;;         ... against the latest release's baseline
;;
;; Conventions (CLAUDE.md): speedups are cumulative against the reference and not additive;
;; the wall clock excludes PROPKA, every pdb2pqr stage and a component download; fit
;; comparisons are judged on distributions, not 1:1. Needs Babashka; shared helpers
;; are in common.clj, the report parser in report.clj.

(ns compare
    (:require [babashka.classpath :refer [add-classpath]]
        [babashka.fs :as fs]
        [cheshire.core :as json]
        [clojure.string :as str]))

(add-classpath (str (fs/parent (fs/absolutize *file*))))

(require '[common :as c] '[report])

(def ^:private who "bb compare")

;; --- the result sets
;;
;; A result set is a sorted map of path -> parsed report (see report.clj). Sorted, so
;; that sums run over the fits in the same order whatever the source.

(defn- git-reports
    "The parsed reports of every res*.txt under the fitting tests at `rev`."
    [rev]
    (into
        (sorted-map)
        (for
            [p (str/split-lines (c/git "ls-tree" "-r" "--name-only" rev c/fit-dir))
                :when (re-matches (re-pattern (str c/fit-dir "/[^/]+/res[^/]*\\.txt")) p)]
            [p (report/parse (c/git "show" (str rev ":" p)))])))

(defn- tree-reports
    "The same for the files in the working tree."
    []
    (into (sorted-map)
        (for [f (fs/glob c/*root* (str c/fit-dir "/*/res*.txt"))]
            [(str (fs/relativize c/*root* f)) (report/parse (c/slurp8 f))])))

;; --- small numeric and formatting helpers

(defn- column
    "The non-empty values of `k` over a map of reports, as numbers."
    [reports k]
    (->> (vals reports)
        (map #(c/as-number (% k)))
        (remove #{""})))

(defn- total
    "Sum of `k` over the reports, or nil if no report has it (older formats lack some
    fields)."
    [reports k]
    (when-let [xs (seq (column reports k))] (reduce + 0.0 xs)))

(defn- or-zero [v] (if (or (nil? v) (= v "")) 0 (c/as-number v)))

(defn- mean [xs] (/ (reduce + xs) (double (count xs))))

(defn median
    "Median of the numbers `xs`."
    [xs]
    (let [xs (vec (sort xs))
            n (count xs)]
        (if (odd? n)
            (xs (quot n 2))
            (/ (+ (xs (dec (quot n 2))) (xs (quot n 2))) 2.0))))

(defn pct
    "Quantile `q` (0..1) of `xs`, by linear interpolation between order statistics."
    [xs q]
    (let [xs (vec (sort xs))
            last-i (dec (count xs))
            k (* last-i q)
            lo (long k)
            hi (if (< (inc lo) last-i) (inc lo) last-i)
            a (xs lo)]
        (+ a (* (- (xs hi) a) (- k lo)))))

(defn commas
    "`x` with `dec` decimals and thousands separators: 4782.4 0 -> \"4,782\"."
    [x decimals]
    (loop [s (c/fmt (str "%." decimals "f") x)]
        (let [t (str/replace-first s #"^(-?\d+)(\d{3})" "$1,$2")]
            (if (= t s) s (recur t)))))

(defn dash
    "`v` by the conversion `spec`, or \"-\" when it is empty."
    [spec v]
    (if (or (nil? v) (= v "")) "-" (c/fmt spec v)))

(defn ratio
    "\"x.xx\" ratio of two numbers, or n/a when either is missing or zero."
    [numer denom]
    (if (some #(or (nil? %) (= % "") (zero? %)) [numer denom])
        "n/a"
        (str (c/fmt "%.2f" (/ (double numer) denom)) "x")))

(defn- med
    "The median of `xs` by `spec`, or \"-\" when there are none."
    [xs spec]
    (if (seq xs) (c/fmt spec (median xs)) "-"))

(defn- stat
    "`(f xs)` of the known values of `k`, by `spec`, or \"-\" when no report has it."
    [reports k f spec]
    (if-let [xs (seq (column reports k))]
        (c/fmt spec (f xs))
        "-"))

(defn- p90 [xs] (pct xs 0.9))

(defn- n-where [pred xs] (count (filter pred xs)))

(defn- row
    "Prints a markdown table row."
    [& cells]
    (println (str "| " (str/join " | " cells) " |")))

(defn- head
    "Prints the header and rule lines of a markdown table."
    [cells]
    (row (str/join " | " cells))
    (println (str "|" (apply str (repeat (count cells) "---|")))))

(defn- heading [text] (println (str "\n### " text "\n")))

;; --- the tables of the revision comparison

(def ^:private timing-rows
    "The stages of the report's timing table: [label key]. A revision whose report
    lacks one (an old format, or a protein-only run for the nucleotide stages) shows -,
    not 0."
    [["static build" :static_build] ["  resolve_structure" :resolve_structure]
        ["  components" :components] ["  structure checks" :structure_checks]
        ["  classify" :classify] ["  propka" :propka]
        ["  pdb2pqr (any variant)" :pdb2pqr]
        ["  modified nucleotide hydrogens" :modified_hydrogens]
        ["  modified amino acid hydrogens" :modified_amino_hydrogens]
        ["  heavy atoms" :heavy_atoms] ["  load_molecule" :load_molecule]
        ["  SASA" :sasa] ["  shannon" :shannon] ["  forward_cache" :fwd]
        ["    vacuum + excluded volume" :vacuum_excluded] ["    hydration" :hydration]
        ["    Gram + r_m" :gram_rm] ["  seed_fitting" :seed_fitting]
        ["sampling" :sampling] ["  MAP search + whitening" :map_s]
        ["  NUTS setup" :nuts_setup] ["  NUTS" :nuts]
        ["  per-draw c1 re-profile" :reprofile] ["  MAP + quantiles" :map_quantiles]
        ["report write" :report_write] ["unaccounted" :unaccounted] ["GC" :gc]
        ["wall clock excl. PROPKA/pdb2pqr/downloads" :wall_ex]
        ["leapfrog steps (x1e6)" :leapfrog]])

(defn- timing-table
    "Timing totals over all common fits, one column per revision plus \"last vs each
    other\" ratios. `agg` is name -> reports."
    [agg names]
    (let [cur (last names)
            others (butlast names)
            wall (total (agg cur) :wall)]
        (row "(all fits, summed)"
            (str/join " | " names)
            (str/join " | " (map #(str cur " vs " %) others))
            "% of wall")
        (println (str "|---|"
                (apply str
                    (repeat (+ (count names) (count others) 1) "---|"))))
        (doseq [[label k] timing-rows
                :let [v (into {} (map (fn [n] [n (total (agg n) k)])) names)
                    denom (v cur)]]
            (row label
                (str/join " | "
                    (for [n names
                            :let [x (v n)]]
                        (cond (nil? x) "-"
                            (= k :leapfrog) (commas (* x 1e-6) 2)
                            :else (str (commas x (if (< x 10) 2 0))
                                " s"))))
                (str/join " | " (map #(ratio (v %) denom) others))
                (if (and denom wall (not= k :leapfrog))
                    (str (c/fmt "%.1f" (/ (* 100 denom) wall)) " %")
                    "-")))
        (println (str "\n(ratio > 1: the last column is faster "
                "/ does less work than that revision)"))))

(defn- quality
    "How many common fits got better / worse / stayed within 1 % in `latest` against
    `old`."
    [latest old label cur]
    (let [pairs (for [[k r] latest
                    :let [a (c/as-number (r :chi2_cmp))
                        b (c/as-number (get-in old [k :chi2_cmp]))]
                    :when (and (old k) (number? a) (number? b))]
                [a b])
            lower (n-where (fn [[a b]] (< a (* 0.99 b))) pairs)
            higher (n-where (fn [[a b]] (> a (* 1.01 b))) pairs)]
        (println (str "χ² of "
                cur
                " vs "
                label
                " ("
                (count pairs)
                " common fits, ±1 % counts "
                "as unchanged): "
                lower
                " lower, "
                higher
                " higher, "
                (- (count pairs) lower higher)
                " unchanged"))))

(defn- distribution
    "One row of the distribution table: fit quality and parameter distributions of a
    set of reports."
    [reports label]
    (let [chi2 (column reports :chi2_cmp)
            rs (vals reports)]
        (row label
            (count reports)
            (med chi2 "%.2f")
            (if (seq chi2)
                (str (c/fmt "%.2f" (pct chi2 0.25))
                    " / "
                    (c/fmt "%.2f" (pct chi2 0.75)))
                "-")
            ;; more than 1 % divergent transitions
            (n-where #(> (or-zero (% :div)) 0.01) rs)
            ;; c1 at its bound
            (n-where #(not (#{"" "false" "0"} (% :sat))) rs)
            (n-where #(> % 3) (map abs (column reports :z3)))
            (med (column reports :d3) "%+.2f")
            ;; deep trees
            (n-where #(> (or-zero (% :steps)) 100) rs)
            (med (column reports :steps) "%.1f"))))

;; --- the expanded tables: fit quality spread, sampler health, MAP search, sizes,
;; posterior widths

(defn- chi2-row
    "The χ² distribution of a column: spread, geometric mean and how many fits are
    above a few thresholds."
    [reports label]
    (let [x (column reports :chi2_cmp)
            g #(c/fmt "%.3g" %)]
        (row label
            (count reports)
            (g (pct x 0))
            (g (pct x 0.25))
            (g (median x))
            (g (pct x 0.75))
            (g (pct x 0.9))
            (g (pct x 1))
            (g (Math/exp (mean (map #(Math/log %) x))))
            (n-where #(< % 1.5) x)
            (n-where #(> % 5) x)
            (n-where #(> % 10) x))))

(defn- sampler-row
    "Sampler health of a column: acceptance, tree depth and steps, E-BFMI, divergences,
    and (reports with chains) the worst R-hat and the smallest ESS."
    [reports label]
    (let [col #(column reports %)
            rhat (col :rhat_max)
            div (col :div)]
        (row
            label
            (med (col :accept) "%.3f")
            (stat reports :accept #(apply min %) "%.3f")
            (med (col :depth) "%.2f")
            (stat reports :depth_max #(apply max %) "%d")
            (med (col :steps) "%.1f")
            (stat reports :steps p90 "%.1f")
            (med (col :ms_per_step) "%.2f")
            (stat reports :ebfmi #(apply min %) "%.2f")
            (n-where #(< % 0.3) (col :ebfmi))
            (n-where pos? div)
            (if (seq div) (c/fmt "%.3f" (* 100 (mean div))) "-")
            (if (seq rhat)
                (str (c/fmt "%.3f" (apply max rhat))
                    " ("
                    (n-where #(> % 1.01) rhat)
                    ")")
                "-")
            (med (col :ess_min) "%.0f")
            (med (col :ess_tail_min) "%.0f")
            (if (seq (col :chains_total)) (long (total reports :chains_dropped)) "-")
            (n-where #(> % 1) (col :modes))
            (stat reports :mode_share_max #(apply min %) "%.3f"))))

(defn- map-row
    "The MAP search of a column: modes, starts that converged, its time and its share of
    the wall clock."
    [reports label]
    (let [ok (column reports :map_starts_ok)
            m (total reports :map_s)
            w (total reports :wall_ex)]
        (row label
            (med (column reports :map_modes) "%.0f")
            (n-where #(> % 1) (column reports :map_modes))
            (if (seq ok) (c/fmt "%.2f" (mean ok)) "-")
            (med (column reports :map_s) "%.3f")
            (if (and m w) (str (c/fmt "%.1f" (/ (* 100 m) w)) " %") "-"))))

(defn- size-row
    "What the fits were (a rebinned or re-sized problem is not comparable 1:1): medians
    of the problem sizes."
    [reports label]
    (apply row
        label
        (for [[k spec] [[:n_atoms "%.0f"] [:lMax "%.0f"] [:n_q_raw "%.0f"]
                    [:n_q "%.0f"] [:dmax "%.1f"] [:n_samples "%.0f"]
                    [:n_adapt "%.0f"]]]
            (med (column reports k) spec))))

(defn- width-row
    "One parameter's posterior: the median MAP z-score, how many fits have it beyond 3
    sigma of the prior, and the width of the quantile interval in prior standard
    deviations (z_hi - z_lo): median, p10, p90."
    [reports label prefix]
    (let [key* #(keyword (str prefix %))
            zmap (column reports (key* "_Z_MAP"))
            w (for [r (vals reports)
                    :let [lo (c/as-number (r (key* "_Z_QUANT_LO")))
                        hi (c/as-number (r (key* "_Z_QUANT_HI")))]
                    :when (and (number? lo) (number? hi))]
                (- hi lo))]
        (row label
            (if (seq zmap) (c/fmt "%.2f" (median zmap)) "-")
            (if (seq zmap) (n-where #(> (abs %) 3) zmap) 0)
            (if (seq w) (c/fmt "%.3f" (median w)) "-")
            (if (seq w) (c/fmt "%.3f" (pct w 0.1)) "-")
            (if (seq w) (c/fmt "%.3f" (pct w 0.9)) "-"))))

(defn- worst
    "The eight worst fits of the judged column by `k`, with every column's cell (made by
    `cell` from a report)."
    [title sets names k cell]
    (let [ranked (->> (sets (last names))
                (map (fn [[path r]] [path (or-zero (r k))]))
                (sort-by second #(compare %2 %1)))]
        (when-not (zero? (second (first ranked)))
            (println (str "\n" title " (columns: " (str/join " | " names) ")"))
            (doseq [[path _] (take 8 ranked)]
                (println (format "  %-42s %s"
                        (str/replace path (str c/fit-dir "/") "")
                        (str/join " | "
                            (for [n names]
                                (if-let [r (get-in sets [n path])]
                                    (cell r)
                                    "-")))))))))

(defn- cell-nuts
    [r]
    (str (dash "%.1f" (r :steps)) " / " (dash "%.1f" (r :nuts)) "s"))

(defn- cell-chi2
    [r]
    (str (c/fmt "%.3g" (or-zero (r :chi2_cmp))) " / " (dash "%.4f" (r :div))))

(defn- cell-rhat
    [r]
    (str (dash "%.3f" (r :rhat_max))
        " / " (dash "%.0f" (r :ess_min))
        " / " (dash "%.0f" (r :ess_tail_min))))

(defn- detail-tables
    "Every expanded table, over the common fits (`agg`: name -> reports) and the judged
    column's full sets."
    [agg sets names]
    (let [cur (last names)
            each (fn [f] (doseq [n names] (f (agg n) n)))]
        (heading "Fit quality, spread")
        (head ["" "fits" "min" "Q1" "median" "Q3" "p90" "max" "geo. mean" "χ² <1.5"
                "χ² >5" "χ² >10"])
        (each chi2-row)
        (heading "Sampler health")
        (head ["" "median accept" "min accept" "median depth" "max depth"
                "median steps/iter" "p90 steps/iter" "median ms/step" "min E-BFMI"
                "E-BFMI <0.3" "fits with divergences" "mean divergence %"
                "R-hat max (fits >1.01)" "median min bulk ESS" "median min tail ESS"
                "chains dropped" "fits with >1 mode"
                "smallest share of the top mode"])
        (each sampler-row)
        (heading "MAP search")
        (head ["" "median modes" "fits with >1 mode" "mean starts ok" "median MAP s"
                "share of wall"])
        (each map-row)
        (heading "Problem sizes (medians)")
        (head ["" "atoms" "lMax" "measured points" "fitted points" "Dmax Å"
                "iterations" "warm-up"])
        (each size-row)
        (heading (str "Posterior of " cur " (z in prior standard deviations)"))
        (head ["parameter" "median MAP z" "fits |z|>3" "median width" "width p10"
                "width p90"])
        (doseq [[label prefix] [["ρₑ" "rho_e"] ["δρ₁" "dro1"] ["δρ₂" "dro2"]
                    ["δρ₃" "dro3"]]]
            (width-row (agg cur) label prefix))
        (heading "Worst fits")
        (worst "Most NUTS work: steps/iter / NUTS seconds"
            sets
            names
            :steps
            cell-nuts)
        (worst "Highest χ²: χ² / divergent share" sets names :chi2_cmp cell-chi2)
        (worst "Least converged chains: R-hat max / min bulk ESS / min tail ESS"
            sets
            names
            :rhat_max
            cell-rhat)))

;; --- the benchmark comparison (--bench)

(def ^:private stages
    "Stage rows of the benchmark tables: [label prefix of the stage names summed into
    that row]. `pdb2pqr` takes its three variants (`pdb2pqr (nucleic, none)`, ...); the
    first four rows are the ones the steady-state table repeats."
    [["forward_cache" "forward_cache"] ["MAP search" "MAP search"]
        ["NUTS" "NUTS  ("] ["c1 re-profile" "per-draw c1 re-profile"]
        ["propka" "propka"] ["pdb2pqr" "pdb2pqr"] ["components" "components"]
        ["classify" "classify"] ["structure checks" "structure checks"]
        ["heavy atoms" "heavy atoms"]
        ["modified nucleotide hydrogens" "modified nucleotide hydrogens"]
        ["modified amino acid hydrogens" "modified amino acid hydrogens"]])

(defn- stage-total
    "Seconds of `field` (:stage_seconds, :stage_compile or :stage_gc) summed over the
    stages named `prefix`*, nil when the fit has no such stage (an older run, or a
    stage that did not apply to that structure)."
    [fit field prefix]
    (when-let [vs (seq (for [[stage v] (map vector (:stage_name fit) (field fit))
                        :when (str/starts-with? stage prefix)]
                    v))]
        (reduce + 0.0 vs)))

(defn- compile-in-stages
    "Seconds of compile time inside the timed stages (those at depth 1) of a fit."
    [fit]
    (reduce +
        0.0
        (for [[depth cmp] (map vector (:stage_depth fit) (:stage_compile fit))
                :when (== depth 1)]
            cmp)))

(defn- bench-row
    "Prints one table row of the benchmark report: `getter` is given the fit of a run
    and returns a number; a run lacking the fit shows \"-\"."
    [runs names spec label getter]
    (let [cells (for [n names
                    :let [fit (get-in runs [n :fit (keyword spec)])]]
                (when fit (getter fit)))]
        (row label
            (str/join " | " (map #(dash "%.2f" %) cells))
            (str/join " | " (map #(ratio % (last cells)) (butlast cells))))))

(defn- bench-main
    "Side-by-side report of benchmark JSON files from `bb bench` (the last file is the
    one judged)."
    [files]
    (let [files
            (if (= 1 (count files))
                (let [tag (c/latest-release)
                        base (when tag (c/baseline-for tag))]
                    (when-not base
                        (binding [*out* *err*]
                            (println
                                (str "no benchmark baseline for the latest release ("
                                    (or tag "none found")
                                    ") in test/baselines/; name "
                                    "the file to compare with, as: bb compare --bench "
                                    "OLD.json NEW.json (test/baselines/README.md)")))
                        (c/exit 1))
                    (println (str "baseline: "
                            (fs/file-name base)
                            " (the latest release, "
                            tag
                            ")"))
                    (cons base files))
                files)
            ;; a run is named after its file
            names (map #(str (fs/strip-ext (fs/file-name %))) files)
            runs (zipmap names (map #(json/parse-string (c/slurp8 %) true) files))
            cur (last names)]
        (doseq [n names
                :let [m (:meta (runs n))]]
            (println (str n
                    ": " (:state m)
                    " state, " (:git_rev m)
                    ", " (:host m)
                    ", Julia " (:julia m)
                    ", " (:cpu m))))
        ;; results from different machines or cold vs warm state are not comparable
        (doseq [[field warning]
                [[:host "results from different hosts are not comparable"]
                    [:state "mixing cold and warm results; compare like with like"]]]
            (when (> (count (distinct (map #(get-in runs [% :meta field]) names)))
                    1)
                (println (str "WARNING: " warning))))
        (println (str "\ninstall (instantiate + precompile): "
                (str/join ", "
                    (for [n names]
                        (format
                            "%s: %.1f s"
                            n
                            (c/as-number
                                (get-in runs [n :install :precompile_s])))))))
        ;; one table per fit that appears in any file
        (doseq [spec (sort (distinct (mapcat #(map name (keys (:fit (runs %))))
                            names)))
                :let [r (partial bench-row runs names spec)
                    top (fn [k] #(c/as-number (k %)))
                    total-of (fn [which]
                        #(c/as-number (get-in % [which :total_s])))]]
            (println (str "\n== " spec))
            (row "seconds"
                (str/join " | " names)
                (str/join " | " (map #(str cur " vs " %) (butlast names))))
            (println (str "|---|"
                    (apply str (repeat (dec (* 2 (count names))) "---|"))))
            (r "process wall" (top :process_wall_s))
            (r "using BAYSOL" (top :using_baysol_s))
            (r "tooling load (not product)" (top :tooling_load_s))
            ;; first fit = includes JIT compilation
            (r "FIRST FIT total (seed + run)" (total-of :first))
            (r "  first - steady (JIT and first-use cost)"
                #(- (c/as-number (get-in % [:first :total_s]))
                    (c/as-number (get-in % [:second :total_s]))))
            (r "  compile inside the timed stages" #(compile-in-stages (:first %)))
            (doseq [[label prefix] stages]
                (r (str "  first: " label)
                    #(stage-total (:first %) :stage_seconds prefix)))
            ;; steady fit = second fit in the same process, everything compiled
            (r "STEADY FIT total (seed + run)" (total-of :second))
            (doseq [[label prefix] (take 4 stages)]
                (r (str "  steady: " label)
                    #(stage-total (:second %) :stage_seconds prefix))
                (r (str "  steady: " label " GC")
                    #(stage-total (:second %) :stage_gc prefix))))
        (println (str
                "\n(ratio > 1: the last file is faster; first fit includes JIT, "
                "steady fit does not; compare cold with cold only)"))))

;; --- the stage notes

(def ^:private note-stages
    "The stages whose notes the notes table shows, in the order of the report."
    ["components" "classify" "propka" "pdb2pqr" "modified nucleotide hydrogens"
        "modified amino acid hydrogens" "heavy atoms"])

(defn- stage-note
    "The note of the stage `nm` in `report` (a variant such as `pdb2pqr (mixed, propka)`
    counts as `pdb2pqr`), or \"\"."
    [report nm]
    (or (some (fn [[k v]] (when (str/starts-with? k nm) v)) (:stage_notes report))
        ""))

(defn- notable?
    "Is a fit worth a line of the notes table: not protein-only, or a cache missed, or
    a component downloaded."
    [report]
    (let [notes (vals (:stage_notes report))]
        (boolean (or (some #(str/starts-with? % "[nucleic") notes)
                (some #(str/starts-with? % "[mixed") notes)
                (some #(str/includes? % "cache miss") notes)
                (pos? (or-zero (:components_download report)))))))

(defn- notes-table
    "The notes of the judged column's fits that are not plain protein runs with every
    cache hit: what the nucleotide stages found, and which lookups missed. Reports
    without notes (older formats) give no line."
    [reports cur]
    (heading (str "Stage notes of " cur))
    (let [rows (for [[path r] reports
                    :when (notable? r)]
                (cons (str/replace path (str c/fit-dir "/") "")
                    (map #(stage-note r %) note-stages)))]
        (if (seq rows)
            (do (head (cons "fit" note-stages))
                (doseq [cells rows] (apply row cells)))
            (println
                "(every fit is protein-only with all caches hit, or has no notes)"))))

;; --- the CSV files

(defn- shown [path] (str/replace path (str c/fit-dir "/") ""))

(defn- write-csv
    "Writes `file`: a header `fit,<name>:<key>,...`, then one line per fit of the judged
    column, with `cell` giving the text of a report value (nil: blank)."
    [file sets names keys* header-key cell]
    (let [latest (sets (last names))]
        (c/spit8 file
            (str
                (str/join
                    ","
                    (cons "fit" (for [n names k keys*] (str n ":" (header-key k)))))
                "\n"
                (apply str
                    (for [path (keys latest)]
                        (str (shown path)
                            ","
                            (str/join ","
                                (for [n names
                                        k keys*
                                        :let [r (get-in sets [n path])]]
                                    (cell (when r (r k)))))
                            "\n")))))))

;; --- the main program

(defn- parse-args
    "The command line: {:revs :no-tree :bench :csv :csv-all}. A bad option stops with
    the usage line."
    [argv]
    (loop [[a & more] argv
            acc {:revs []}]
        (cond (nil? a) acc
            (= a "--no-tree") (recur more (assoc acc :no-tree true))
            (= a "--bench") (recur more (assoc acc :bench true))
            (= a "--csv") (recur (rest more) (assoc acc :csv (first more)))
            (= a "--csv-all") (recur (rest more)
                (assoc acc :csv-all (first more)))
            (str/starts-with? a "--")
            (do (binding [*out* *err*]
                    (println (str "usage: " who
                            " [REV ...] [--no-tree] [--csv FILE] "
                            "[--csv-all FILE] | --bench FILE.json ...")))
                (c/exit 2))
            :else (recur more (update acc :revs conj a)))))

(defn- load-sets
    "The result sets to compare: [names sets], one per revision then the working tree.
    Stops with a message on an unknown revision."
    [revs no-tree]
    (let [loaded (reduce
                (fn [acc rev]
                    (when-not (c/resolve-rev rev)
                        (binding [*out* *err*]
                            (println (str "unknown git revision '" rev
                                    "'; tags here: "
                                    (str/join ", "
                                        (str/split-lines
                                            (str/trim
                                                (c/git "tag" "--list")))))))
                        (c/exit 1))
                    ;; the same rev twice stays distinguishable
                    (let [label (if (some #{rev} (:names acc))
                                (str rev "#" (count (:names acc)))
                                rev)
                            reports (git-reports rev)]
                        (if (empty? reports)
                            (do (println (str
                                        "warning: no fitting-test reports at "
                                        rev
                                        "; skipped"))
                                acc)
                            (-> acc
                                (update :names conj label)
                                (assoc-in [:sets label] reports)))))
                {:names [], :sets {}}
                revs)]
        (if no-tree
            [(:names loaded) (:sets loaded)]
            [(conj (:names loaded) "working tree")
                (assoc (:sets loaded) "working tree" (tree-reports))])))

(defn run
    "The tool's main program for the argument list `argv`; returns the exit status."
    [argv]
    (if (some #{"--help" "-h"} argv)
        (c/usage)
        (let [{:keys [revs no-tree bench csv csv-all]} (parse-args argv)]
            (if bench
                (bench-main revs)
                (let [revs
                        (if (seq revs)
                            revs
                            (if-let [tag (c/latest-release)]
                                (do (println (str
                                            "baseline: "
                                            tag
                                            ", the latest release (name "
                                            "other revisions to compare with those "
                                            "instead)"))
                                    [tag])
                                (do (binding [*out* *err*]
                                        (println
                                            "no release tag (v<digit>...) in this "
                                            "repository; name the revisions to compare"))
                                    (c/exit 1))))
                        [names sets] (load-sets revs no-tree)]
                    (when (< (count names) 2)
                        (binding [*out* *err*]
                            (println "need at least two result sets to compare"))
                        (c/exit 1))
                    (let [cur (last names)
                            ;; only fits that have a report in every column are
                            ;; aggregated, so the columns are comparable
                            common (filter (fn [path]
                                    (every? #(contains? (sets %) path)
                                        names))
                                (keys (sets (first names))))
                            _ (when (empty? common)
                                (binding [*out* *err*]
                                    (println "no fit has a report in every column"))
                                (c/exit 1))
                            agg (into {}
                                (for [n names]
                                    [n
                                        (into (sorted-map)
                                            (map (fn [p] [p
                                                        (get-in sets [n p])]))
                                            common)]))
                            latest (sets cur)]
                        (println (str "Reports: "
                                (str/join ", "
                                    (for [n names]
                                        (str n "=" (count (sets n)))))))
                        (println
                            (str
                                "Everything below except the per-fit list and the CSV is "
                                "aggregated over the " (count common)
                                " fits that have a " "report in every column.\n"))
                        ;; --- the report
                        (timing-table agg names)
                        (notes-table (agg cur) cur)
                        (println (str "\n| | fits | median χ² | χ² Q1 / Q3 "
                                "| >1 % divergent | c1 pinned"
                                " | MAP >3σ from δρ₃ prior | median δρ₃ "
                                "| fits >100 steps/iter"
                                " | median steps/iter |"))
                        (println "|---|---|---|---|---|---|---|---|---|---|")
                        (doseq [n names] (distribution (agg n) n))
                        (println)
                        (doseq [n (butlast names)]
                            (quality (agg cur) (agg n) n cur))
                        (detail-tables agg sets names)
                        ;; every parsed key of every column (the keys of the judged
                        ;; column's first report)
                        (when csv-all
                            (write-csv csv-all
                                sets
                                names
                                (:order (meta (latest (first (keys
                                                    latest)))))
                                name
                                #(c/num-str (or % ""))))
                        ;; the fixed list of per-fit numbers, blank where a revision
                        ;; lacks a value
                        (when csv
                            (write-csv csv
                                sets
                                names
                                [:chi2_cmp :steps :depth :nuts :wall_ex :div
                                    :c1 :d1 :d2 :d3 :z3 :n_modes]
                                #(if (= % :chi2_cmp) "chi2" (name %))
                                #(if (or (nil? %) (= % ""))
                                    ""
                                    (c/fmt "%.6g" %))))))))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
    (c/main run *command-line-args*))
