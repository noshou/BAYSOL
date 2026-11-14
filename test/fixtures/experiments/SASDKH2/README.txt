SASBDB entry SASDKH2  (https://www.sasbdb.org/data/SASDKH2/)

Publication: High Conformational Flexibility of the E2F1/DP1/DNA Complex.
DOI:         https://doi.org/10.1016/j.jmb.2021.167119

The files are the SASBDB downloads, unchanged:
  experimental_data/SASDKH2.dat   the curve (q in 1/A; columns q, I, error; SCATTER header)
  SASDKH2_fit1.fit                the CRYSOL fit (q in 1/A; columns q, Iexp, Ierr, Icalc)
  SASDKH2_fit1_model1.pdb         the GROMACS/PLUMED MD frame of "fit1": protein chains A, B and
                                  DNA chains C, D, with hydrogens, no water, CRYST1 box
                                  (https://www.sasbdb.org/media/pdb_file/SASDKH2_fit1_model1.pdb)

Nothing was cleaned. Paper read (2026-11-13 audit): Buffer C (50 mM Tris-Cl pH 8.0, 150 mM
NaCl, 2 mM DTT) of the in-line SEC-SAXS run confirms the SASBDB buffer; the temperature and
wavelength (SI Table S2, not available) are the SASBDB entry's.

Round 5 rescan (2026-11-13): verdict KEEP, see notes/new-entries/AUDIT5-A.md.

q cut (round 9, 2026-11-13): the script fits q <= 0.25 A^-1 and leaves out the noise tail: S/N about 1.5 at 0.2; above the cut 334 of 1065 points non-positive, mean I/sigma 0.5 (377 of 2451 in the whole curve).
Every other entry without such a tail is fitted over its whole curve.
