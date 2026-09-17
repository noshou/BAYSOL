# ResidueNetCharge

Per-ionizable-atom net fractional charge at physiological pH (7.4), for a screened-Coulomb electrostatic hydration-shell.

## Source

Grimsley, Scholtz & Pace, "A summary of the measured pK values of the ionizable groups in folded proteins," *Protein Science* 18(1):247-251 (2009),  DOI `10.1002/pro.19`  Charges are Henderson-Hasselbalch calculation from those pKa at pH 7.4, `frac_ionized = 1 / (1 + 10^(±(pKa - pH)))`. 

## residue_net_charge.tsv

Columns: `resname`, `atomname`, `charge`, `pKa`, `basis`, `doi`.

One row per charged atom (11 rows): Asp `OD1`/`OD2`, Glu `OE1`/`OE2`, Cys `SG`, His `ND1`/`NE2`, Lys `NZ`, Arg `NH1`/`NH2`/`NE`. Tyr is deliberately omitted  since its net charge at pH 7.4 is ~0 and contributes nothing. Carboxylate (Asp/Glu) and terminal-amine (Lys) charges are straightforward:  the ionizable group's fractional charge is split evenly over its two chemically-equivalent oxygens (Asp/Glu), or lives on the single nitrogen (Lys).

## Two approximations

- **His and Arg: charge split evenly across resonance-delocalized nitrogens.** The truly protonated forms (imidazolium for His, guanidinium for Arg) are delocalized cations. Splitting the ionized fraction evenly across the ring's two
  nitrogens (His `ND1`/`NE2`) or the guanidinium's three nitrogens (Arg NH1`/`NH2`/`NE`) is a simplification for a per-atom screened-Coulomb model.

## Arg's pKa is not from Grimsley/Scholtz/Pace

Grimsley/Scholtz/Pace 2009 tabulates measured *folded-protein* pKa values for
Asp, Glu, His, Cys, Tyr, and Lys only; Arg's guanidinium group essentially
never titrates in the pH range accessible to those measurements, so it isn't
in that table (and isn't in Thurlkill/Grimsley/Scholtz/Pace 2006, `10.1110/ps.051840806`,
the companion alanine-pentapeptide model-compound paper, for the same reason).
Arg's pKa here (13.8) instead comes from Fitch, Platzer, Okon, Garcia-Moreno &
McIntosh, "Arginine: Its pKa value revisited," *Protein Science* 24(5):752-761
(2015), DOI `10.1002/pro.2647`, which used potentiometry and NMR to directly
measure the free-amino-acid guanidinium pKa as 13.8 ± 0.1 — "substantially
higher than that of ~12 often used in structure-based electrostatics
calculations and cited in biochemistry textbooks" (their words). At pH 7.4
this barely moves the ionized fraction relative to the old ~12.5 figure
(both round to a fully-protonated 1.00 split three ways to 0.33/atom), but
13.8 is the actual measured value rather than an inherited textbook number.

## residue_net_charge.json

Residues/atoms with no entry are uncharged (or not an ionizable atom this table tracks) and should resolve to `nothing`.
