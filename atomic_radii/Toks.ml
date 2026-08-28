(* SPDX-License-Identifier: LGPL-2.1-or-later *)
(* token for an element *)
type tok =
    | Token_error of char
    | Elem of string
    | Sign of char
    | Charge of string
    | EOF
