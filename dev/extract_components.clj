#!/usr/bin/env bb
;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Regenerate the bundled component table src/MolecularStructure/components.tsv from the
;; wwPDB Chemical Component Dictionary.
;;
;;     bb extract-components --check                  # download, compare, exit 1 if stale
;;     bb extract-components --update                 # download, rewrite the table
;;     bb extract-components components.cif.gz --check
;;     bb extract-components SOURCE [OUT]             # write the table to OUT, or stdout
;;
;; SOURCE is a local components.cif.gz or an http(s) URL (downloaded to a temporary
;; file, deleted afterwards); the default is the wwPDB file
;; https://files.wwpdb.org/pub/pdb/data/monomers/components.cif.gz (about 120 MB). The
;; gzip is streamed line by line, never held in memory. Only the _chem_comp.id, .type,
;; .formula and .mon_nstd_parent_comp_id lines of each data_ block are read.
;;
;; Table: `#` header lines, then one row per component sorted by id, tab separated:
;;     id       _chem_comp.id
;;     class    dna / rna when the type contains the word DNA / RNA (so L-DNA / L-RNA
;;              linking and the 3'/5' terminus types count), else other
;;     type     _chem_comp.type, lower-cased
;;     parent   _chem_comp.mon_nstd_parent_comp_id, `-` when it is `?` or empty
;;     formula  _chem_comp.formula without its quotes
;; A tab inside a value becomes a space. A field a block lacks reads as `?`.
;;
;; Options:
;;     --check            exit 1 if the generated table differs from OUT (printing the
;;                        first differing lines); the header's source date and fetch date
;;                        default to the ones OUT carries, so only the data is compared
;;     --update           rewrite OUT (default src/MolecularStructure/components.tsv)
;;     --source-date STR  the "Last-Modified" text of the header (default: the HTTP
;;                        Last-Modified of the download, or the file's modification time
;;                        for a local file)
;;     --fetched DATE     the "fetched" date of the header (default: today, ISO format)
;;     --url URL          the source URL named in the header (default: SOURCE if a URL,
;;                        else the wwPDB URL above)
;;     --out FILE         the table to write or compare (default as above)
;; With --source-date and --fetched set to the checked-in header's values, a regeneration
;; from the same dictionary file is byte-identical to the checked-in table.
;;
;; The shared helpers (`common`) live beside this file; it puts its folder on its
;; classpath.

(ns extract-components
    (:require [babashka.classpath :refer [add-classpath]]
        [babashka.fs :as fs]
        [clojure.java.io :as io]
        [clojure.set :as set]
        [clojure.string :as str])
    (:import (java.net URI)
        (java.net.http HttpClient
            HttpClient$Redirect
            HttpRequest
            HttpResponse$BodyHandlers)
        (java.time LocalDate ZoneOffset ZonedDateTime)
        (java.time.format DateTimeFormatter)
        (java.util.zip GZIPInputStream)))

(add-classpath (str (fs/parent (fs/absolutize *file*))))

(require '[common :as c])

(def ^:private who "bb extract-components")

(def default-url "https://files.wwpdb.org/pub/pdb/data/monomers/components.cif.gz")

(def default-out (c/in-root "src" "MolecularStructure" "components.tsv"))

;; --- parsing

(defn unquote-value
    "A CIF value without the single or double quotes that surround it. A value that only
    begins with a quote (an apostrophe inside a bare word) is left alone."
    [v]
    (if (and (>= (count v) 2) (#{\' \"} (first v)) (= (first v) (last v)))
        (subs v 1 (dec (count v)))
        v))

(defn component-class
    "`\"dna\"`, `\"rna\"` or `\"other\"` for a lower-case `_chem_comp.type`: the word DNA
    or RNA anywhere in it, hyphens and spaces counting as word breaks (\"l-rna linking\",
    \"dna oh 5 prime terminus\")."
    [typ]
    (cond (re-find #"\bdna\b" typ) "dna"
        (re-find #"\brna\b" typ) "rna"
        :else "other"))

(defn- nucleic?
    "Is the data block `block` (a map as `read-blocks` makes it) a nucleic acid component?"
    [block]
    (not= "other" (component-class (str/lower-case (get block "type" "?")))))

;; The tokens of one row of a CIF loop: a word, or text in single or double quotes. As in
;; CIF, a quote closes only when whitespace (or the line end) follows it, so an atom name
;; like "O5'" or "H5''" can sit inside double quotes.
(def ^:private token-re
    #"\"(?:[^\"]|\"(?=\S))*\"(?=\s|$)|'(?:[^']|'(?=\S))*'(?=\s|$)|\S+")

(defn tokens
    "The unquoted tokens of one CIF loop row."
    [line]
    (mapv unquote-value (re-seq token-re line)))

;; The first heavy-atom bookkeeping of a loop: which columns hold what.
(def ^:private atom-cols ["_chem_comp_atom.atom_id" "_chem_comp_atom.type_symbol"])

(def ^:private bond-cols ["_chem_comp_bond.atom_id_1" "_chem_comp_bond.atom_id_2"])

(defn- loop-row
    "Adds one data row of a loop with the column names `cols` to the nucleic block `cur`:
    an atom `[name element]` (hydrogens and deuterium are dropped) or a bond `[a b]`."
    [cur cols line]
    (let [toks (tokens line)
            at (fn [col]
                (let [i (.indexOf ^java.util.List cols col)]
                    (when (and (>= i 0) (< i (count toks))) (nth toks i))))]
        (cond (some #{(first atom-cols)} cols)
            (let [[n e] (map at atom-cols)]
                (if (and n e (not (#{"H" "D"} (str/upper-case e))))
                    (update cur :atoms (fnil conj []) [n (str/upper-case e)])
                    cur))
            (some #{(first bond-cols)} cols)
            (let [[a b] (map at bond-cols)]
                (if (and a b) (update cur :bonds (fnil conj []) [a b]) cur))
            :else cur)))

;; The `_chem_comp` items kept: the five columns need id, type, formula and the parent;
;; the base inference reads the name and the one-letter code.
(def ^:private fields
    #{"id" "type" "formula" "mon_nstd_parent_comp_id" "name" "one_letter_code"})

;; One `_chem_comp.<field> [value]` line of a data block. The dot and the field name
;; keep `_chem_comp_atom.*` out; the value is empty for a `;` text block that follows.
(def ^:private item-re #"^_chem_comp\.([a-z_]+)(?:\s+(.*?))?\s*$")

(defn read-blocks
    "The data blocks of a component dictionary read from `rdr`, streamed line by line, as
    maps: the `_chem_comp` items of `fields` by name (unquoted; a `;` text block, as the
    name often is, joined into one line) and, for nucleic acid blocks only, `:atoms`
    (`[name ELEMENT]`, heavy atoms) and `:bonds` (`[atom-1 atom-2]`) from the
    `_chem_comp_atom` and `_chem_comp_bond` loops. Everything else is skipped, so the 120
    MB file is never held. A block without an id is an error."
    [^java.io.BufferedReader rdr]
    (let [flush-block
            (fn [acc cur]
                (cond (nil? cur) acc
                    (nil? (get cur "id"))
                    (throw (ex-info (str who ": a data block has no _chem_comp.id")
                            {}))
                    :else (conj! acc cur)))]
        ;; `text` is the field whose `;` text block is being read (with the lines so
        ;; far); `mode` is the loop being read: its column names and whether its header
        ;; is still going on.
        (loop [acc (transient [])
                cur nil
                text nil
                mode nil]
            (if-let [line (.readLine rdr)]
                (cond text
                    (cond
                        ;; the line after an empty value: a `;` text block opens, or
                        ;; the value itself sits on this line
                        (nil? (:lines text))
                        (if (str/starts-with? line ";")
                            (recur acc
                                cur
                                {:field (:field text), :lines [(subs line 1)]}
                                mode)
                            (recur acc
                                (assoc cur
                                    (:field text)
                                    (unquote-value (str/trim line)))
                                nil
                                mode))
                        ;; the closing `;`
                        (str/starts-with? line ";")
                        (recur acc
                            (assoc cur
                                (:field text)
                                (str/trim (str/join " " (:lines text))))
                            nil
                            mode)
                        :else (recur acc cur (update text :lines conj line) mode))
                    (str/starts-with? line "data_")
                    (recur (flush-block acc cur) {} nil nil)
                    (str/starts-with? line "loop_")
                    (recur acc cur nil {:cols [], :header? true})
                    (str/starts-with? line "#") (recur acc cur nil nil)
                    (and mode (:header? mode) (str/starts-with? line "_"))
                    (recur acc cur nil (update mode :cols conj (str/trim line)))
                    mode (recur acc
                        (if (and cur (nucleic? cur))
                            (loop-row cur (:cols mode) line)
                            cur)
                        nil
                        (assoc mode :header? false))
                    (str/starts-with? line "_chem_comp.")
                    (let [[_ k v] (re-matches item-re line)]
                        (cond (not (and k (fields k) cur))
                            (recur acc cur nil mode)
                            (seq v)
                            (recur acc (assoc cur k (unquote-value v)) nil mode)
                            ;; an empty value: a `;` text block follows
                            :else (recur acc cur {:field k, :lines nil} mode)))
                    :else (recur acc cur nil mode))
                (persistent! (flush-block acc cur))))))

;; --- the base of a nucleotide
;;
;; Which of A C G U T a nucleic acid component is built on, written to the table's `base`
;; column with the signal that decided it in `base_source`. The signals, from the most to
;; the least trusted: the declared parent (`mon_nstd_parent_comp_id`, followed up through
;; non-standard parent-of), the standard residues themselves (`self`), the one-letter code
;; (`letter`), the ring chemistry (`ring`) and keywords of the name (`name`). `validate`
;; measures the last three on the components that declare a parent.

(def ^:private standard-bases
    {"A" "A",
        "C" "C",
        "G" "G",
        "U" "U",
        "T" "T",
        "DA" "A",
        "DC" "C",
        "DG" "G",
        "DT" "T",
        "DU" "U"})

(defn- parent-ids
    "The ids of a `parent` column text (\"DT, DT\", \"C\", \"-\"), as a vector."
    [parent]
    (if (#{"-" "?" ""} parent) [] (mapv str/trim (str/split parent #","))))

(defn parent-base
    "The base A/C/G/U/T that the declared parent `parent` of a component leads to, or nil.
    `parent-of` maps every id to its parent column text. A comma list must agree on one
    base; a non-standard parent is followed through its own parent; cycles and unknown
    ids give nil."
    [parent-of parent]
    (letfn [(of-id [id seen]
                (cond (standard-bases id) (standard-bases id)
                    (seen id) nil
                    :else (of-list (parent-ids (get parent-of id "-"))
                        (conj seen id))))
            (of-list [ids seen]
                (let [bs (set (map #(of-id % seen) ids))]
                    (when (and (seq ids) (= 1 (count bs)) (first bs)) (first bs))))]
        (of-list (parent-ids parent) #{})))

(defn letter-base
    "The base of a usable `_chem_comp.one_letter_code` (A C G U T), else nil. Other codes
    (N, I, ?, ...) do not name a natural base."
    [code]
    (#{"A" "C" "G" "U" "T"}
        (some-> code
            str/upper-case)))

;; Keywords of nucleoside names, per base.
(def ^:private name-keywords
    {"A" #"ADENO|ADENIN|ADENYL",
        "G" #"GUANO|GUANIN|GUANYL",
        "C" #"CYTID|CYTOSIN|CYTIDYL",
        "T" #"THYMID|THYMIN|THYMIDYL",
        "U" #"URID|URACIL|URIDYL"})

(defn name-base
    "The base a component's name `nm` mentions (adenosine, guanine, cytidine, thymidine,
    uridine, ...), or nil when it mentions none or more than one."
    [nm]
    (let [up (str/upper-case (or nm ""))
            found (for [[b re] name-keywords :when (re-find re up)] b)]
        (when (= 1 (count found)) (first found))))

(defn- adjacency
    "The bond graph of a block: atom name to the set of bonded heavy atoms. Bonds to
    unknown (hydrogen) atoms are dropped."
    [{:keys [atoms bonds]}]
    (let [known (set (map first atoms))]
        (reduce (fn [g [a b]]
                (if (and (known a) (known b) (not= a b))
                    (-> g
                        (update a (fnil conj #{}) b)
                        (update b (fnil conj #{}) a))
                    g))
            (zipmap known (repeat #{}))
            bonds)))

(defn- cycles-of-length
    "Every simple cycle of `n` atoms of the graph `g`, as a set of atom-name sets."
    [g n]
    (set (for [start (keys g)
                path (letfn [(extend-path [path]
                            (if (= n (count path))
                                (when ((g (peek path)) (first path)) [path])
                                (mapcat extend-path
                                    (for [nb (g (peek path))
                                            :when (and (not (some #{nb} path))
                                                (pos? (compare nb start)))]
                                        (conj path nb)))))]
                    (extend-path [start]))]
            (set path))))

(defn- glycosidic
    "The `[c1 n furanose]` of the nucleoside in graph `g` (elements in `el`): a five-ring
    of one O and four C whose carbon next to the ring O carries a nitrogen outside the
    ring; nil unless there is exactly one such pair (abasic sugars, C-nucleosides and
    molecules with several nucleosides have none)."
    [g el]
    (let [hits (set (for [ring (cycles-of-length g 5)
                        :let [os (filter #(= "O" (el %)) ring)]
                        :when (and (= 1 (count os))
                            (= 4 (count (filter #(= "C" (el %)) ring))))
                        c1 (g (first os))
                        :when (ring c1)
                        n (g c1)
                        :when (and (not (ring n)) (= "N" (el n)))]
                    [c1 n ring]))]
        (when (= 1 (count hits)) (first hits))))

(defn- base-core
    "The atoms of the base ring system hanging on the glycosidic nitrogen `n`: everything
    reachable from `n` without passing through the sugar (`c1` and the furanose ring
    atoms `sugar`), pruned of its dead ends until only rings and the bonds between them
    remain."
    [g n sugar]
    (let [reach (loop [seen #{n}
                    todo [n]]
                (if-let [x (peek todo)]
                    (let [fresh (remove #(or (seen %) (sugar %)) (g x))]
                        (recur (into seen fresh) (into (pop todo) fresh)))
                    seen))]
        (loop [core reach]
            (let [dead (filter #(<= (count (filter core (g %))) 1) core)]
                (if (seq dead) (recur (reduce disj core dead)) core)))))

(defn- subs-of
    "The heavy atoms bonded to `a` that are not in `core`."
    [g core a]
    (remove core (g a)))

(defn- ring-pyrimidine
    "The base of a pyrimidine base ring: the ring `core` (6 atoms, glycosidic nitrogen `n1`)
    in graph `g` with elements `el`, numbered from N1. \"C\" for a C4 amine with a C2
    oxygen (a C5 substituent does not matter: an amine only at C5 is not a C), `:ut` for
    oxygens on C2 and C4 (a uracil or a thymine: the dictionary's parent-of do not follow
    the C5 methyl, so the ring does not decide), else nil."
    [g el core n1]
    (let [others (remove #{n1} core)
            n3 (first (filter #(= "N" (el %)) others))
            c2 (when n3 (first (filter #((g n3) %) (filter core (g n1)))))
            c6 (when c2 (first (remove #{c2} (filter core (g n1)))))
            c4 (when n3 (first (remove #{c2} (filter core (g n3)))))
            c5 (first (remove (set [n1 n3 c2 c4 c6]) core))
            sub-els #(vec (sort (map el (subs-of g core %))))]
        (when (and n3
                c2
                c6
                c4
                c5
                (= 1 (count (filter #(= "N" (el %)) others)))
                (= (set (filter core (g c4))) #{n3 c5})
                (= (set (filter core (g c5))) #{c4 c6}))
            (let [s2 (sub-els c2)
                    s4 (sub-els c4)]
                (when (= ["O"] s2)
                    (case s4
                        ["N"] "C"
                        ["O"] :ut
                        nil))))))

(defn- ring-purine
    "The base (A or G) of a purine base ring system: `core` (9 atoms) with glycosidic
    nitrogen `n9` in graph `g` with elements `el`, numbered from N9, or nil. Inosine-like
    bases (C6 oxygen, no C2 amine) and bases with other substituents give nil."
    [g el core n9]
    (let [deg #(count (filter core (g %)))
            nb9 (filter core (g n9))
            c4 (first (filter #(= 3 (deg %)) nb9))
            c8 (first (remove #{c4} nb9))
            c4n (when c4 (remove #{n9} (filter core (g c4))))
            c5 (first (filter #(= 3 (deg %)) c4n))
            n3 (first (remove #{c5} c4n))
            c5n (when c5 (remove #{c4} (filter core (g c5))))
            n7 (first (filter #((g c8 #{}) %) c5n))
            c6 (first (remove #{n7} c5n))
            c2 (when n3 (first (remove #{c4} (filter core (g n3)))))
            n1 (when c2 (first (remove #{n3} (filter core (g c2)))))
            seq-ok? (and c4
                c8
                c5
                n3
                n7
                c6
                c2
                n1
                (= "C" (el c4) (el c8) (el c5) (el c6) (el c2))
                (= "N" (el n3) (el n7) (el n1))
                (= #{n9 c4 c8 n7 c5 n3 c2 n1 c6} core)
                (some #{c6} (g n1)))]
        (when seq-ok?
            (let [s6 (vec (sort (map el (subs-of g core c6))))
                    s2 (vec (sort (map el (subs-of g core c2))))]
                (cond (and (= ["N"] s6) (not-any? #{"N" "O"} s2)) "A"
                    (and (= ["O"] s6) (= ["N"] s2)) "G"
                    :else nil)))))

(defn ring-base
    "The base A/C/G/U/T a nucleic acid component's heavy-atom bond graph describes, or
    nil. `block` has `:atoms` and `:bonds`. The sugar is the furanose ring (one O, four
    C) whose C1' carries a nitrogen; the base ring system is numbered from that
    glycosidic nitrogen so that the substituents are read by position: pyrimidine C4
    amine and C2 oxygen: C; C4 and C2 oxygens: U, or T with a methyl on C5 (an amine at
    C5 is not a C); purine C6 amine: A; C6 oxygen with a C2 amine: G."
    [block]
    (let [g (adjacency block)
            el (into {} (:atoms block))]
        (when-let [[c1 n ring] (glycosidic g el)]
            (let [core (base-core g n (conj ring c1))
                    nn (count (filter #(= "N" (el %)) core))
                    nc (count (filter #(= "C" (el %)) core))]
                (cond (and (= 6 (count core))
                        (= 2 nn)
                        (= 4 nc)
                        (every? #(= 2 (count (filter core (g %)))) core))
                    (ring-pyrimidine g el core n)
                    (and (= 9 (count core)) (= 4 nn) (= 5 nc))
                    (ring-purine g el core n)
                    :else nil)))))

;; The signals that may write a base; `validate` shows the precision that decides it.
(def ^:private trusted-signals #{:letter :ring :name})

(defn base-signals
    "The base each inference signal finds for a nucleic acid `block`, a map of
    `:letter`, `:ring` and `:name` to a base or nil."
    [block]
    {:letter (letter-base (get block "one_letter_code")),
        :ring (ring-base block),
        :name (name-base (get block "name"))})

(defn infer-base
    "`[base source]` of a nucleic acid `block` without a usable declared parent: the
    standard residue itself (`self`), else the base of the first of letter, ring and name
    that finds one, as long as the signals that found one agree; `[\"-\" \"-\"]` when none
    finds one or two disagree. A ring that sees a uracil or thymine (`:ut`) agrees with a
    letter or name that says U or T, and alone it decides nothing."
    [block]
    (let [id (get block "id")
            sig (base-signals block)
            found (into {}
                (for [s [:letter :ring :name]
                        :when (and (trusted-signals s) (sig s))]
                    [s (sig s)]))
            agree? (fn [bs]
                (let [bs (map #(if (= :ut %) #{"U" "T"} #{%}) bs)]
                    (= 1 (count (apply set/intersection bs)))))]
        (cond (standard-bases id) [(standard-bases id) "self"]
            (and (seq found) (agree? (vals found)))
            (let [base (or (some (fn [s] (when-not (= :ut (found s)) (found s)))
                            [:letter :ring :name])
                        nil)
                    src (first (filter #(= base (found %)) [:letter :ring :name]))]
                (if base [base (name src)] ["-" "-"]))
            :else ["-" "-"])))

(defn row-of
    "The table row (a vector of the seven columns) of one data block `block` (field name
    to unquoted value, as `read-blocks` makes it). Missing fields read as `?`; tabs
    become spaces. `base-of` is the `[base source]` of the block."
    [block base-of]
    (let [clean #(str/replace % \tab \space)
            id (clean (get block "id"))
            typ (str/lower-case (clean (get block "type" "?")))
            parent (clean (get block "mon_nstd_parent_comp_id" "?"))]
        (into [id (component-class typ) typ (if (#{"?" ""} parent) "-" parent)
                (clean (get block "formula" "?"))]
            base-of)))

(defn rows-of
    "The unsorted table rows of the data `blocks`: five columns, then the base and its
    source. A nucleic acid component takes its base from the declared parent when that
    leads to a standard base, else from `infer-base`; every other component has `-`."
    [blocks]
    (let [parent-of (into {}
                (for [b blocks]
                    [(get b "id")
                        (let [p (get b "mon_nstd_parent_comp_id" "?")]
                            (if (#{"?" ""} p) "-" p))]))]
        (for [b blocks]
            (row-of b
                (if (nucleic? b)
                    (if-let [pb (parent-base parent-of
                                (parent-of (get b "id")))]
                        [pb "parent"]
                        (infer-base b))
                    ["-" "-"])))))

;; --- validating the inference

(defn validate
    "How well each signal of `signals` finds the base of the nucleic acid components of
    `blocks` that declare a parent (the base that parent leads to is the truth). Returns
    `{:total n, :signals {signal {:found :correct :confusion}} ...}` where `:confusion`
    maps `[truth predicted]` to a count; `:combined` is the same for `infer-base` as it
    stands."
    [blocks]
    (let [parent-of (into {}
                (for [b blocks]
                    [(get b "id") (get b "mon_nstd_parent_comp_id" "?")]))
            judged (for [b blocks
                    :when (nucleic? b)
                    :let [truth (parent-base parent-of (parent-of (get b "id")))]
                    :when truth]
                [truth b])
            tally (fn [pairs]
                (let [found (filter second pairs)]
                    {:found (count found),
                        :correct (count (filter #(= (first %) (second %)) found)),
                        :confusion (frequencies found)}))]
        {:total (count judged),
            :signals (into {}
                (for [s [:letter :ring :name]]
                    [s
                        (tally (for [[t b] judged
                                    :let [v ((base-signals b) s)]]
                                [t (when-not (= :ut v) v)]))])),
            ;; the ring's "uracil or thymine" answers: how many, how many truly U or T
            :ring-ut (let [ut (filter #(= :ut (:ring (base-signals (second %))))
                        judged)]
                {:found (count ut),
                    :correct (count (filter #(#{"U" "T"} (first %)) ut))}),
            :combined (tally (for [[t b] judged
                        :let [[base src] (infer-base (dissoc b "id"))]]
                    [t (when (not= "-" src) base)]))}))

(defn validation-text
    "The report of `validate` as text: per signal the coverage and precision and the
    confusion counts (truth -> predicted)."
    [{:keys [total signals combined ring-ut]}]
    (let [line (fn [k {:keys [found correct confusion]}]
                (str (format
                        "%-9s found %4d of %d (coverage %5.1f %%), correct %4d "
                        (name k)
                        found
                        total
                        (* 100.0 (/ found (max total 1)))
                        correct)
                    (format "(precision %5.1f %%)\n"
                        (* 100.0 (/ correct (max found 1))))
                    (str/join ""
                        (for [[[t p] n] (sort confusion)]
                            (format "          %s -> %s: %d%s\n"
                                t
                                p
                                n
                                (if (= t p) "" "   <-- wrong"))))))]
        (str
            "validation on "
            total
            " nucleic acid components with a declared parent\n"
            (apply str (for [[k v] signals] (line k v)))
            (format
                "ring: %d more are a uracil or a thymine (%d truly U or T), not decided\n"
                (:found ring-ut)
                (:correct ring-ut))
            (line :combined combined))))

;; --- the table text

(defn header-lines
    "The `#` header of the table; `rows` is the number of data rows."
    [{:keys [url source-date fetched]} rows]
    [(str "# Chemical Component Dictionary subset: one row per component "
            "(id, class, type, parent, formula, base, base_source).")
        (str "# Source: " url " (Last-Modified " source-date "; fetched " fetched ").")
        (str
            "# Fields come from _chem_comp.id, .type, .mon_nstd_parent_comp_id ('-' when "
            "none) and .formula; class is dna/rna when the type names DNA or RNA, else "
            "other.")
        (str
            "# base is the natural base (A C G U T, '-' when none) of a dna/rna "
            "component; base_source says where it comes from: parent (the declared "
            "parent, followed up to a standard residue), self (a standard residue), "
            "letter (a usable _chem_comp.one_letter_code), ring (the bond graph: the "
            "base ring read by position from the glycosidic nitrogen), name (keywords of "
            "_chem_comp.name), or '-'. Components that are not dna/rna have '-' '-'.")
        "# Generated by dev/extract_components.clj; do not edit by hand."
        (str "# rows: " rows) "#id\tclass\ttype\tparent\tformula\tbase\tbase_source"])

(defn table-text
    "The whole table as text (every line ended by a newline): the header for `head`
    (`:url`, `:source-date`, `:fetched`) and the `rows` sorted by id. Two blocks with one
    id are an error."
    [head rows]
    (let [sorted (sort-by first rows)
            dup (->> sorted
                (map first)
                (partition-by identity)
                (some #(when (next %) (first %))))]
        (when dup
            (throw (ex-info (str who ": component id " dup " occurs twice") {})))
        (str (str/join "\n"
                (concat (header-lines head (count sorted))
                    (map #(str/join "\t" %) sorted)))
            "\n")))

(defn header-meta
    "The `:url`, `:source-date` and `:fetched` the `# Source:` line of table `text`
    carries, or nil if it has none."
    [text]
    (when-let [[_ url date fetched]
            (re-find
                #"(?m)^# Source: (\S+) \(Last-Modified (.*?); fetched (.*?)\)\.$"
                text)]
        {:url url, :source-date date, :fetched fetched}))

;; --- the source

(def ^:private http-date DateTimeFormatter/RFC_1123_DATE_TIME)

(defn- url? [s] (boolean (re-find #"^https?://" s)))

(defn- download!
    "Downloads `url` to the file `dest` (streamed, redirects followed); returns the
    Last-Modified header text, or nil if the server sent none. A status other than 200 is
    an error."
    [url dest]
    (let [client (-> (HttpClient/newBuilder)
                (.followRedirects HttpClient$Redirect/NORMAL)
                .build)
            request (-> (HttpRequest/newBuilder (URI/create url))
                .build)
            response
            (.send client request (HttpResponse$BodyHandlers/ofFile (fs/path dest)))]
        (when-not (= 200 (.statusCode response))
            (throw (ex-info
                    (str who ": " url " answered HTTP " (.statusCode response))
                    {})))
        (.orElse (.firstValue (.headers response) "Last-Modified") nil)))

(defn- mtime-text
    "The modification time of the local file `path` in the HTTP date form."
    [path]
    (.format http-date
        (ZonedDateTime/ofInstant (.toInstant (fs/last-modified-time path))
            ZoneOffset/UTC)))

(defn- read-gz
    "The data blocks of the gzip file `path` (see `read-blocks`)."
    [path]
    (with-open [rdr (io/reader (GZIPInputStream. (io/input-stream (str path)) 65536)
                :encoding
                "UTF-8")]
        (read-blocks rdr)))

(defn- with-source
    "Calls `(f blocks last-modified)` with the data blocks of `source` (a gzip path or an
    http(s) URL, downloaded to a temporary file that is deleted afterwards) and the
    text of its Last-Modified header or modification time."
    [source f]
    (let [remote? (url? source)
            tmp (when remote?
                (str (fs/create-temp-file {:prefix "components-",
                            :suffix ".cif.gz"})))]
        (try (let [lm (if remote? (download! source tmp) (mtime-text source))]
                (f (read-gz (or tmp source)) lm))
            (finally (when tmp (fs/delete-if-exists tmp))))))

(defn generate
    "Reads `source` (a gzip path or an http(s) URL) and returns the table text. `opts`
    (all optional) override the header's `:url`, `:source-date` and `:fetched`;
    `:defaults` supplies the values used when the source gives none itself (the header
    of the table being checked)."
    [source opts]
    (with-source
        source
        (fn [blocks lm]
            (let [{:keys [defaults]} opts]
                (table-text
                    {:url (or (:url opts)
                            (:url defaults)
                            (if (url? source) source default-url)),
                        :source-date
                        (or (:source-date opts) (:source-date defaults) lm "unknown"),
                        :fetched
                        (or (:fetched opts) (:fetched defaults) (str (LocalDate/now)))}
                    (rows-of blocks))))))

;; --- check and update

(defn- check
    "Compares `text` with the table file `out`: prints the first differing lines to
    stderr and returns 1, or reports the table up to date and returns 0."
    [text out]
    (let [have-text (when (fs/exists? out) (c/slurp8 out))
            have (some-> have-text
                str/split-lines
                vec)
            want (str/split-lines text)]
        (if (= have-text text)
            (do (println (str out " is up to date (" (count want) " lines)")) 0)
            (binding [*out* *err*]
                (println
                    (str
                        out
                        " is out of date; regenerate: bb extract-components --update"))
                (doseq [i (take 10
                            (filter #(not= (get have %) (get want %))
                                (range (max (count have) (count want)))))]
                    (println (str "  line " (inc i) " checked-in: " (get have i)))
                    (println (str "  line " (inc i) " generated : " (get want i))))
                1))))

(defn run
    "The tool's main program for the argument list `argv`; returns the exit status."
    [argv]
    (let [{:keys [opts flags specs]}
            (c/split-args who
                ["--source-date" "--fetched" "--url" "--out"]
                ["--check" "--update" "--validate-inference" "--help" "-h"]
                argv)
            opt (fn [k] (some (fn [[k* v]] (when (= k* k) v)) (reverse opts)))
            flag? (set flags)]
        (cond (or (flag? "--help") (flag? "-h")) (c/usage)
            (and (flag? "--check") (flag? "--update"))
            (c/fail who "give --check or --update, not both")
            (> (count specs) 2) (c/fail who "at most a SOURCE and an OUT")
            (flag? "--validate-inference")
            (do (with-source (or (first specs) default-url)
                    (fn [blocks _]
                        (print (validation-text (validate blocks)))))
                0)
            :else (let [source (or (first specs) default-url)
                    out (or (second specs) (opt "--out") default-out)
                    existing (when (and (flag? "--check") (fs/exists? out))
                        (header-meta (c/slurp8 out)))
                    t0 (System/nanoTime)
                    text (generate source
                        {:url (opt "--url"),
                            :source-date (opt "--source-date"),
                            :fetched (opt "--fetched"),
                            :defaults existing})
                    secs (/ (- (System/nanoTime) t0) 1e9)]
                (binding [*out* *err*]
                    (println (format "read %s in %.1f s" source secs)))
                (cond (flag? "--check") (check text out)
                    (flag? "--update") (do (c/spit8 out text)
                        (println "wrote" (str out)))
                    (second specs) (do (c/spit8 out text)
                        (println "wrote" (str out)))
                    :else (print text))))))

;; Run only when executed as a script, so the functions can be loaded for testing.
(when (= *file* (System/getProperty "babashka.file"))
    (c/main run *command-line-args*))
