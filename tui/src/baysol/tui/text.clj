;; SPDX-License-Identifier: LGPL-3.0-or-later

(ns baysol.tui.text
 "Small pure helpers the screens share: blank padding, which keys type a character,
 keeping a table cursor on its rows, how numbers are shown and read, and how names are
 compared."
 (:require [clojure.string :as str])
 (:import (com.googlecode.lanterna TerminalTextUtils)
  (com.googlecode.lanterna.input KeyType)))

(set! *warn-on-reflection* true)

(defn spaces
 "A string of `n` spaces (empty for `n` of 0 or less).

 # Returns
 A string.

 # Exceptions
 None."
 [n]
 (apply str (repeat (max 0 n) \space)))

;; --- display width: how many terminal cells a text takes

(defn cp-width
 "The number of terminal cells the code point `cp` takes: 0 for a control character, a
 combining mark, an enclosing mark, a format character (zero-width joiner and space,
 variation selectors) and an emoji skin-tone modifier; 2 for an East Asian wide or
 fullwidth character and for an emoji (Lanterna's own `TerminalTextUtils` table); 1 for
 the rest.

 # Returns
 An integer, 0 to 2.

 # Exceptions
 None."
 [cp]
 (let [cp (int cp)]
  (cond (or (< cp 32) (<= 127 cp 159)) 0
   (<= 0x1F3FB cp 0x1F3FF) 0
   (contains? #{Character/NON_SPACING_MARK Character/ENCLOSING_MARK
     Character/FORMAT}
    (Character/getType cp))
   0
   :else (long (TerminalTextUtils/getColumnWidth (String. (Character/toChars
       cp)))))))

(defn display-width
 "The number of terminal cells the text `s` takes (see `cp-width`; `nil` is 0). For
 plain text it is the number of characters.

 # Returns
 An integer.

 # Exceptions
 None."
 [s]
 (let [^String s (str s)]
  (loop [i 0
    w 0]
   (if (< i (.length s))
    (let [cp (.codePointAt s i)]
     (recur (+ i (Character/charCount cp)) (+ w (long (cp-width cp)))))
    w))))

(defn take-width
 "The longest start of the text `s` that takes at most `n` cells: a wide character that
 would cross the edge is left out (the caller pads the gap with a space).

 # Returns
 A string.

 # Exceptions
 None."
 [s n]
 (let [^String s (str s)]
  (loop [i 0
    w 0]
   (if (< i (.length s))
    (let [cp (.codePointAt s i)
      w2 (+ w (long (cp-width cp)))]
     (if (> w2 n) (subs s 0 i) (recur (+ i (Character/charCount cp)) w2)))
    s))))

(defn take-last-width
 "The longest end of the text `s` that takes at most `n` cells (a wide character that would
 cross the edge is left out).

 # Returns
 A string.

 # Exceptions
 None."
 [s n]
 (let [^String s (str s)]
  (loop [i (.length s)
    w 0]
   (if (pos? i)
    (let [cp (.codePointBefore s i)
      w2 (+ w (long (cp-width cp)))]
     (if (> w2 n) (subs s i) (recur (- i (Character/charCount cp)) w2)))
    s))))

(defn pad-width
 "The text `s` followed by spaces up to `n` cells (cut with `take-width` when longer, so
 the result always takes exactly `n` cells).

 # Returns
 A string.

 # Exceptions
 None."
 [s n]
 (let [cut (take-width s n)]
  (str cut (spaces (- n (display-width cut))))))

(defn splice-width
 "The line `line` with the cells from column `from` up to `to` (display columns) replaced
 by the text `text` (which should take `to` less `from` cells): a line shorter than `from`
 is padded with spaces first, and a wide character cut in two by an edge leaves a space
 for the half that stays. Unlike `subs`, it is right for lines that hold wide characters.

 # Returns
 A string.

 # Exceptions
 None."
 [line from to text]
 (let [^String line (str line)
   tail (loop [i 0
     col 0
     out (StringBuilder.)]
    (if (< i (.length line))
     (let [cp (.codePointAt line i)
       c1 (+ col (long (cp-width cp)))
       step (Character/charCount cp)]
      (cond (<= c1 to) nil
       (>= col to) (.appendCodePoint out cp)
       :else (.append out ^String (spaces (- c1 to))))
      (recur (+ i step) c1 out))
     (str out)))]
  (str (pad-width line from) text tail)))

(defn printable?
 "Whether the raw input `input` (see `state/key->raw`) is a character to type: a
 character that is not a control character or DEL.

 # Returns
 A boolean.

 # Exceptions
 None."
 [input]
 (and (char? input) (>= (int input) 32) (not= (int input) 127)))

(defn edits?
 "Whether the raw input `input` changes the text `text` typed with at most `max-len`
 characters: Backspace always, a printable character while the text is shorter than
 `max-len`.

 # Returns
 A boolean.

 # Exceptions
 None."
 [input text max-len]
 (boolean (or (= input KeyType/Backspace)
   (and (printable? input) (< (count text) max-len)))))

(defn at-cap?
 "Whether the raw input `input` is a character that `typed` refuses because the text
 `text` already has `max-len` characters: the cap that must not be silent (the screen
 tells it with `too-long`).

 # Returns
 A boolean.

 # Exceptions
 None."
 [input text max-len]
 (boolean (and (printable? input) (>= (count text) max-len))))

(defn too-long
 "The note that tells a cap was reached when typing a `what` (\"name\", \"text\"): `name too
 long (40 at most)`. The one place the wording lives.

 # Returns
 A string.

 # Exceptions
 None."
 [what max-len]
 (str what " too long (" max-len " at most)"))

(defn typed
 "The text `text` after the raw input `input` was typed into it, with at most `max-len`
 characters: a printable character is added, Backspace removes the last character, any
 other input leaves it.

 # Returns
 A string.

 # Exceptions
 None."
 [text input max-len]
 (cond (= input KeyType/Backspace) (subs text 0 (max 0 (dec (count text))))
  (edits? input text max-len) (str text input)
  :else text))

(defn cycle-index
 "The index `index` moved one place on a list of `n` entries, forward (`forward?`) or
 back, wrapping at both ends.

 # Returns
 An integer.

 # Exceptions
 None, for `n` above 0."
 [index n forward?]
 (mod ((if forward? inc dec) index) n))

(defn clamp-cursor
 "The row index `cursor` held within the rows of the table state `s` (`{:rows [...]}`):
 0 at the least, the last row at the most.

 # Returns
 An integer.

 # Exceptions
 None."
 [cursor s]
 (max 0 (min cursor (dec (count (:rows s))))))

(defn format-number
 "`x` as plain decimal text with no exponent and no trailing zeros (200.0 gives \"200\",
 1.0E-5 gives \"0.00001\"); \"\" for nil.

 # Returns
 A string.

 # Exceptions
 None."
 [x]
 (if x
  (-> (BigDecimal. (str x))
   .stripTrailingZeros
   .toPlainString)
  ""))

(defn number-text
 "The finite number the text `t` is (an optional sign, digits with an optional point, an
 optional exponent; the text is not trimmed), or nil.

 # Returns
 A double or nil.

 # Exceptions
 None."
 [t]
 (let [x (when (re-matches #"[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?" t)
    (Double/parseDouble t))]
  (when-not (or (nil? x) (Double/isInfinite x)) x)))

(defn fold
 "The text `s` the way names are compared: trimmed and lower-cased (`nil` is \"\").

 # Returns
 A string.

 # Exceptions
 None."
 [s]
 (str/lower-case (str/trim (str s))))
