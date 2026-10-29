;; SPDX-License-Identifier: LGPL-3.0-or-later

;; Reading the workbook (`<name>.xlsx`) that `results` writes: the sheets as rows of
;; strings, with nothing but the JDK and clojure.data.xml (an .xlsx is a zip of XML files).
;; A cell is the text it holds (a number as written, a string as itself); an empty cell is
;; "". Only what the pipeline's workbooks use is understood: shared and inline strings,
;; numbers and booleans.

(ns workbook
 (:require [clojure.data.xml :as xml]
  [clojure.string :as str])
 (:import (java.io ByteArrayInputStream)
  (java.nio.file Files)
  (java.util.zip ZipInputStream)))

(defn ^:private zip-entries
 "The files of a zip given as bytes: a map of entry name -> bytes."
 [^bytes data]
 (with-open [zis (ZipInputStream. (ByteArrayInputStream. data))]
  (loop [out {}]
   (if-let [e (.getNextEntry zis)]
    (recur (assoc out (.getName e) (.readAllBytes zis)))
    out))))

(defn ^:private parse-entry
 "The XML root element of the zip entry `entry`, or nil if the file lacks it."
 [files entry]
 (when-let [data (get files entry)] (xml/parse (ByteArrayInputStream. data))))

(defn ^:private tag-of [e] (name (:tag e)))

(defn ^:private elements
 "Every element below `root` (and `root`) whose local tag name is `tag`, in document
 order."
 [root tag]
 (filter #(and (xml/element? %) (= tag (tag-of %)))
  (tree-seq xml/element? :content root)))

(defn ^:private attr
 "The attribute of `e` whose local name is `k` (the namespace prefix is ignored)."
 [e k]
 (some (fn [[a v]] (when (= k (name a)) v)) (:attrs e)))

(defn ^:private text-of
 "All the text inside element `e`, joined."
 [e]
 (apply str (filter string? (tree-seq xml/element? :content e))))

(defn ^:private string-of
 "The string a shared-string or inline-string element holds: the text of its `t`
 elements, not the white space between them."
 [e]
 (apply str (map text-of (elements e "t"))))

(defn ^:private col-index
 "The zero-based column of a cell reference such as \"AB12\"."
 [cell-ref]
 (dec (reduce (fn [n ch] (+ (* n 26) (- (int ch) 64)))
   0
   (take-while #(Character/isLetter ^char %) cell-ref))))

(defn ^:private cell-value
 [shared c]
 (let [t (attr c "t")
   v (first (elements c "v"))]
  (cond (= t "inlineStr") (string-of c)
   (nil? v) ""
   (= t "s") (nth shared (parse-long (text-of v)))
   (= t "b") (if (= "1" (text-of v)) "true" "false")
   :else (text-of v))))

(defn ^:private sheet-rows
 "The rows of a worksheet element as vectors of cell text."
 [shared ws]
 (vec (for [row (elements ws "row")]
   (let [cells (for [c (elements row "c")]
      [(col-index (attr c "r")) (cell-value shared c)])
     n (inc (reduce max -1 (map first cells)))]
    (reduce (fn [v [i x]] (assoc v i x)) (vec (repeat n "")) cells)))))

(defn read-sheets
 "The sheets of the workbook whose bytes are `data`: a map of sheet name -> rows (a
 vector of vectors of strings)."
 [^bytes data]
 (let [files (zip-entries data)
   shared (mapv string-of
    (elements (parse-entry files "xl/sharedStrings.xml") "si"))
   targets (into {}
    (for [r (elements (parse-entry files
        "xl/_rels/workbook.xml.rels")
       "Relationship")]
     [(attr r "Id") (attr r "Target")]))]
  (into {}
   (for [s (elements (parse-entry files "xl/workbook.xml") "sheet")
     :let [target (get targets (attr s "id"))
      path (str "xl/" (str/replace target #"^/?(xl/)?" ""))]]
    [(attr s "name") (sheet-rows shared (parse-entry files path))]))))

(defn read-file
 "`read-sheets` of the workbook file at `path`."
 [path]
 (read-sheets (Files/readAllBytes (.toPath (java.io.File. (str path))))))
