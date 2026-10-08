#!/usr/bin/env tclsh
# SPDX-License-Identifier: LGPL-2.1-or-later

# Extract data from xraydb.sqlite into one compact db.
#
#     tclsh test/utils/extract_formfactor.tcl xraydb.sqlite src/Scattering/form_factors.sqlite3
#
# Source: xraydb 4.5.8's xraydb.sqlite. Its LICENSE places xraydb.sqlite and data_sources/ in the
# public domain via CC0 1.0.
#     - Waasmaier & Kirfel (1995) Acta Cryst A51, 416   -> f0 Gaussian coefficients
#     - Chantler FFAST (NIST, fine grid)                -> f1/f2 anomalous terms
# Energy/f1/f2 are stored as little-endian Float64 BLOBs.
#
# Offline script, not runtime code. Needs Tcl 9 and its `sqlite3` package (Fedora: sqlite-tcl).
#
# The output was checked against the bundled form_factors.sqlite3: the same schema text, and every row
# equal cell for cell (floats compared exactly, not through a text dump).

source [file join [file dirname [info script]] common.tcl]
set SCRIPT [info script]

namespace eval formfactor {
    # --- helpers ----------------------------------------------------------------------------------------

    # The numbers of a JSON array of plain numbers ("[1, 2.5, 3e-4]") as a list of doubles. Anything else
    # in it is an error. `double()` converts each with Tcl's correctly rounded parser; the value is then
    # bound as a real, so no digits are lost on the way into SQLite.
    proc numbers {json what} {
        set out {}
        foreach tok [split [string trim $json "\[\] \n\t"] ,] {
            set tok [string trim $tok]
            if {![string is double -strict $tok]} { error "$what: '$tok' is not a number" }
            lappend out [expr {double($tok)}]
        }
        return $out
    }

    # A list of doubles as a little-endian Float64 blob (bound to SQLite as a BLOB).
    proc blob {xs} { binary format q* $xs }


    # The schema, written out verbatim (not indented or reformatted), because the DDL text is stored in
    # sqlite_master and the bundled database has this exact text.
    variable SCHEMA {
CREATE TABLE waasmaier (
    ion     TEXT PRIMARY KEY,
    element TEXT NOT NULL,
    z       INTEGER NOT NULL,
    c       REAL NOT NULL,
    a1 REAL NOT NULL, a2 REAL NOT NULL, a3 REAL NOT NULL, a4 REAL NOT NULL, a5 REAL NOT NULL,
    b1 REAL NOT NULL, b2 REAL NOT NULL, b3 REAL NOT NULL, b4 REAL NOT NULL, b5 REAL NOT NULL
);
CREATE INDEX idx_waasmaier_element ON waasmaier(element);
CREATE TABLE chantler (
    element TEXT PRIMARY KEY,
    z       INTEGER NOT NULL,
    npts    INTEGER NOT NULL,
    emin    REAL NOT NULL,
    emax    REAL NOT NULL,
    energy  BLOB NOT NULL,
    f1      BLOB NOT NULL,
    f2      BLOB NOT NULL
);
CREATE TABLE provenance (key TEXT PRIMARY KEY, value TEXT NOT NULL);
}

    # Entry point: builds the database in a temporary file next to $dst and renames it over $dst only when
    # it is complete, so a failure midway leaves any existing $dst untouched and no partial file behind.
    proc run {argv} {
        package require sqlite3
        if {"--help" in $argv || "-h" in $argv} { ::usage $::SCRIPT; return }
        lassign $argv src dst
        if {$dst eq ""} { puts stderr "usage: extract_formfactor.tcl xraydb.sqlite form_factors.sqlite3"; exit 2 }
        if {![file isfile $src]} { puts stderr "no such file: $src"; exit 1 }
        set part $dst.part
        file delete $part
        try {
            build $src $part
            file rename -force $part $dst
        } finally {
            catch {srcdb close}
            catch {dstdb close}
            file delete $part
        }
        puts "size: [file size $dst] bytes"
    }

    # Reads the source database $src and writes the compact database $dst (which must not exist).
    proc build {src dst} {
        variable SCHEMA
        sqlite3 srcdb $src -readonly 1
        sqlite3 dstdb $dst
        dstdb eval $SCHEMA

        set n_w 0
        set n_c 0
        set tot 0

        dstdb eval BEGIN

        # --- Waasmaier-Kirfel f0 coefficients ---------------------------------------------------------------
        # One row per ion: offset c, five Gaussian amplitudes a1..a5 and five exponents b1..b5.
        # The source keeps the two five-element lists as JSON text.

        srcdb eval {SELECT atomic_number, element, ion, offset, scale, exponents FROM Waasmaier} row {
            lassign [list $row(atomic_number) $row(element) $row(ion) $row(offset)] z element ion offset
            set a [numbers $row(scale) "Waasmaier $ion scale"]
            set b [numbers $row(exponents) "Waasmaier $ion exponents"]
            if {[llength $a] != 5 || [llength $b] != 5} {
                error "Waasmaier $ion: expected 5 amplitudes and 5 exponents, got [llength $a] and [llength $b]"
            }
            lassign $a a1 a2 a3 a4 a5
            lassign $b b1 b2 b3 b4 b5
            set ion [string tolower $ion]
            set element [string tolower $element]
            dstdb eval {INSERT INTO waasmaier VALUES ($ion, $element, $z, $offset, $a1, $a2, $a3, $a4, $a5, $b1, $b2, $b3, $b4, $b5)}
            incr n_w
        }

        # --- Chantler FFAST anomalous terms -----------------------------------------------------------------
        # One row per element: the energy grid and f1, f2 on it, packed as Float64 blobs.
        # A missing atomic number is an error (LEFT JOIN, then checked) rather than a silently dropped element.

        srcdb eval {SELECT c.element AS element, c.energy AS energy, c.f1 AS f1, c.f2 AS f2, e.atomic_number AS z
                FROM Chantler c LEFT JOIN elements e ON e.element = c.element} row {
            set el $row(element)
            if {$row(z) eq ""} { error "Chantler $el has no atomic number in the elements table" }
            set e  [numbers $row(energy) "Chantler $el energy"]
            set y1 [numbers $row(f1) "Chantler $el f1"]
            set y2 [numbers $row(f2) "Chantler $el f2"]
            if {[llength $e] != [llength $y1] || [llength $e] != [llength $y2]} {
                error "Chantler $el: grid lengths differ ([llength $e], [llength $y1], [llength $y2])"
            }

            # Cs has duplicate grid energies upstream, which makes the s=0 spline throw. Drop them, keeping
            # the first occurrence, so the grid is strictly increasing for every element. A point is kept only
            # if it is above the last point *kept* (the original compared with the previous raw point, which
            # could keep a point below an earlier one if the grid ever dipped; the data has no such case).
            set keep {0}
            set last [lindex $e 0]
            for {set i 1} {$i < [llength $e]} {incr i} {
                if {[lindex $e $i] > $last} { lappend keep $i; set last [lindex $e $i] }
            }
            if {[llength $keep] != [llength $e]} {
                puts "  deduped $el: [llength $e] -> [llength $keep] points"
                foreach var {e y1 y2} {
                    set picked {}
                    foreach i $keep { lappend picked [lindex [set $var] $i] }
                    set $var $picked
                }
            }

            set element [string tolower $el]
            set z $row(z)
            set npts [llength $e]
            set emin [lindex $e 0]
            set emax [lindex $e end]
            set energy [blob $e]
            set f1 [blob $y1]
            set f2 [blob $y2]
            dstdb eval {INSERT INTO chantler VALUES ($element, $z, $npts, $emin, $emax, $energy, $f1, $f2)}
            incr n_c
            incr tot $npts
        }

        # --- provenance -------------------------------------------------------------------------------------
        # The f0_form text is plain ASCII (`<=`), as in the bundled database; the earlier script wrote `≤`,
        # so regenerating would have changed that row.

        foreach {key value} {
            f0_source        {Waasmaier & Kirfel (1995) Acta Cryst A51, 416-431; doi:10.1107/S0108767394013292}
            f0_form          {f0(s) = c + sum_{i=1..5} a_i*exp(-b_i*s^2), s = q/(4*pi) [1/Ang], valid 0 <= s <= 6}
            anomalous_source {Chantler FFAST (NIST), fine grid; J. Phys. Chem. Ref. Data 24 71 (1995), 29 597 (2000)}
            anomalous_form   {f1 stored as f1_FFAST - Z + f_rel(3/5 CL) + f_NT (xraydb convention); f = f0 + f1 + i*f2}
            extracted_from   {xraydb 4.5.8 xraydb.sqlite}
            license          {CC0 1.0 - xraydb LICENSE dedicates xraydb.sqlite and data_sources/ to the public domain}
        } {
            dstdb eval {INSERT INTO provenance VALUES ($key, $value)}
        }

        # --- write ------------------------------------------------------------------------------------------
        # VACUUM packs the file; it cannot run inside the transaction, hence the COMMIT first.

        dstdb eval COMMIT
        dstdb eval VACUUM
        dstdb close
        srcdb close

        puts [format "waasmaier: %d species, chantler: %d elements / %d grid points" $n_w $n_c $tot]
    }
}

# Run only when executed as a script, so the procs can be sourced for testing.
if {[info exists argv0] && [file normalize $argv0] eq [file normalize [info script]]} {
    main formfactor::run $argv
}
