;; SPDX-License-Identifier: LGPL-3.0-or-later

;; The FASTA and FASTQ reader: records, alphabets, the strict FASTQ shape, the error
;; messages (at most 22 characters), the file entry points and the summary.

(ns baysol.tui.sequences-test
 (:require [baysol.tui.sequences :as sq]
  [baysol.tui.support :refer [temp-root]]
  [clojure.java.io :as io]
  [clojure.string :as str]
  [clojure.test :refer [deftest is testing]]))

(defn ^:private ids+seqs
 [result]
 (mapv (juxt :id :sequence) (:records result)))

(deftest fasta-records
 (testing
  "one record, lines joined, lower case and spaces fixed, id up to the blank"
  (is (= [["p1" "ACGTTGCA"]]
    (ids+seqs (sq/parse-text ">p1 primer one\nacgt\nTG CA\n" :dna)))))
 (testing "several records, blank lines between them, CRLF line ends"
  (is (= [["a" "ACGT"] ["b" "GGCC"]]
    (ids+seqs (sq/parse-text
      ">a\r\nAC\r\nGT\r\n\r\n>b desc\r\nGGCC\r\n\r\n\r\n"
      :dna)))))
 (testing "blank lines before the first record and no final newline"
  (is (= [["a" "AC"]] (ids+seqs (sq/parse-text "\n\n>a\nAC" :dna)))))
 (testing "a header without an id gets a number"
  (is (= [["seq1" "AC"] ["seq2" "GT"]]
    (ids+seqs (sq/parse-text ">\nAC\n> \nGT\n" :dna))))))

(deftest alphabets-follow-julia
 (testing "DNA takes T and the ambiguity codes, RNA takes U instead of T"
  (is (:records (sq/parse-text ">d\nACGTRYSWKMBDHVN\n" :dna)))
  (is (:records (sq/parse-text ">r\nACGURYSWKMBDHVN\n" :rna)))
  (is (= "bad letter U (DNA)" (:error (sq/parse-text ">d\nACGU\n" :dna))))
  (is (= "bad letter T (RNA)" (:error (sq/parse-text ">r\nACGT\n" :rna)))))
 (testing "protein: the residues, B J Z, O and U, the placeholders * and X"
  (is (:records (sq/parse-text ">p\nACDEFGHIKLMNPQRSTVWYBJZOUX*\n" :protein)))
  (is (= "bad letter 1 (protein)" (:error (sq/parse-text ">p\nMK1\n" :protein))))
  (is (= "bad letter - (protein)" (:error (sq/parse-text ">p\nMK-L\n" :protein)))))
 (testing "a placeholder is kept, a record of nothing else is empty"
  (is (= [["p" "MKT*"]] (ids+seqs (sq/parse-text ">p\nMKT*\n" :protein))))
  (is (= "empty sequence" (:error (sq/parse-text ">p\n*\n" :protein))))
  (is (= "bad letter X (DNA)" (:error (sq/parse-text ">p\nACX\n" :dna)))))
 (testing "an unknown kind is a programming error"
  (is (thrown? IllegalArgumentException (sq/parse-text ">p\nAC\n" :lipid)))))

(deftest fasta-errors
 (is (= "no records" (:error (sq/parse-text "" :dna))))
 (is (= "no records" (:error (sq/parse-text "\n \n" :dna))))
 (is (= "empty sequence" (:error (sq/parse-text ">a\n" :dna))))
 (is (= "empty sequence" (:error (sq/parse-text ">a\nAC\n>b\n\n>c\nGT\n" :dna))))
 (is (= "wrong format" (:error (sq/parse-text "ACGT\n" :dna))))
 (is (= "wrong format" (:error (sq/parse-text "#>a\nACGT\n" :dna))))
 (testing "an @ in a FASTA body is no header"
  (is (= "bad letter @ (DNA)" (:error (sq/parse-text ">a\nAC\n@b\nGT\n" :dna)))))
 (testing "every message fits the border note"
  (doseq [text ["" ">a\n" "x" ">a\nMK1\n" "@a\nAC\n+\nA\n"]
    kind [:dna :rna :protein]
    :let [e (:error (sq/parse-text text kind))]
    :when e]
   (is (<= (count e) 22) e))))

(deftest fastq-records
 (testing "strict four-line records, only the sequence is kept"
  (is (= [["r1" "ACGT"] ["r2" "GGCC"]]
    (ids+seqs (sq/parse-text "@r1 first\nACGT\n+\nIIII\n@r2\nGGCC\n+r2\nIIII\n"
      :dna)))))
 (testing "an @ at the start of a quality line is no header, nor are + and the like"
  (is (= [["r1" "ACGT"] ["r2" "GGCC"]]
    (ids+seqs (sq/parse-text "@r1\nACGT\n+\n@III\n@r2\nGGCC\n+\n+@@@\n"
      :dna)))))
 (testing "CRLF, lower case, blank lines around"
  (is (= [["r1" "ACGU"]]
    (ids+seqs (sq/parse-text "\r\n@r1\r\nacgu\r\n+\r\nIIII\r\n\r\n\r\n"
      :rna))))))

(deftest fastq-errors
 (is (= "quality length differs"
   (:error (sq/parse-text "@r\nACGT\n+\nIII\n" :dna))))
 (is (= "quality length differs"
   (:error (sq/parse-text "@r\nACGT\n+\nIIIII\n" :dna))))
 (is (= "missing line" (:error (sq/parse-text "@r\nACGT\n+\n" :dna))))
 (is (= "missing line" (:error (sq/parse-text "@r\nACGT\n" :dna))))
 (is (= "missing line" (:error (sq/parse-text "@r\nACGT\n+\nIIII\n@s\nAC\n" :dna))))
 (is (= "bad FASTQ record" (:error (sq/parse-text "@r\nACGT\nIIII\n+\n" :dna))))
 (is (= "bad FASTQ record"
   (:error (sq/parse-text "@r\nAC\n+\nII\n\nGT\n+\nII\n" :dna))))
 (is (= "empty sequence"
   (:error (sq/parse-text "@r\n\n+\n\n@s\nAC\n+\nII\n" :dna))))
 (is (= "bad letter Q (DNA)" (:error (sq/parse-text "@r\nACQT\n+\nIIII\n" :dna)))))

(defn ^:private temp-file
 [fname text]
 (let [f (io/file (temp-root) fname)]
  (spit f text :encoding "UTF-8")
  f))

(deftest files
 (let [multi (temp-file "multi.fa" ">p1 one\nMKTAYIAK\nQRQ\n\n>p2\nGSHM*\n")
   bad (temp-file "bad.fasta" "ACGT\n")]
  (try (is (= [["p1" "MKTAYIAKQRQ"] ["p2" "GSHM*"]]
     (ids+seqs (sq/parse-file multi :protein))))
   (is (= {:error "wrong format"} (sq/parse-file bad :dna)))
   (is (= {:error "cannot read file"}
     (sq/parse-file (io/file (.getParentFile multi) "none.fa") :dna)))
   (finally (doseq [f [multi bad]]
     (io/delete-file f true)
     (io/delete-file (.getParentFile f) true))))))

(deftest file-extensions
 (doseq [n ["a.fasta" "a.fa" "a.fna" "a.faa" "a.fastq" "a.fq" "/x/y/A.FASTA"
    "B.Fq"]]
  (is (sq/fasta-file? n) n))
 (doseq [n ["a.pdb" "a.txt" "fasta" "a.fa.gz" "" "a.fq.bak"]]
  (is (not (sq/fasta-file? n)) n)))

(deftest summaries
 (testing "short sequences are whole, with the count"
  (is (= "ACG (3 nt)" (sq/summary :dna "ACG" 22)))
  (is (= "MKT (3 aa)" (sq/summary :protein "MKT" 22))))
 (testing "a long one shrinks head and tail and always keeps the count"
  (let [s (sq/summary :dna (apply str (repeat 8 "ACGT")) 22)]
   (is (= "ACGTACG…GTACGT (32 nt)" s))
   (is (<= (count s) 22)))
  (let [s (sq/summary :protein (apply str (repeat 317 "M")) 22)]
   (is (= "MMMMMM…MMMMMM (317 aa)" s))
   (is (= 22 (count s))))
  (let [s (sq/summary :protein (str "MKT" (apply str (repeat 311 "A")) "QLS") 22)]
   (is (str/ends-with? s " (317 aa)"))
   (is (<= (count s) 22))))
 (testing "a narrow width keeps the suffix and what fits of the head"
  (is (= "AC (24 nt)" (sq/summary :dna (apply str (repeat 12 "AC")) 10)))
  (is (= " (24 nt)" (sq/summary :dna (apply str (repeat 12 "AC")) 4))))
 (testing "placeholders are not counted"
  (is (= "MKT* (3 aa)" (sq/summary :protein "MKT*" 22)))))
