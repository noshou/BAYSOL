(* SPDX-License-Identifier: LGPL-3.0-or-later *)
(* token for an element *)
type tok =
    | Token_error of char
    | Elem of string
    | Sign of char
    | Charge of string
    | EOF
