SASBDB entry SASDL27  (https://www.sasbdb.org/data/SASDL27/)

Publication: Fine-tuning of intrinsic N-Oct-3 POU domain allostery by regulatory DNA targets.
DOI:         https://doi.org/10.1093/nar/gkm453   (open access, PMC1935007)

The files are the SASBDB downloads, unchanged:
  experimental_data/SASDL27.dat   the curve (q in 1/A; columns q, I, error; CRLF, 3 header lines, 8 trailer lines)
  SASDL27_fit1.fit                the CRYSOL fit (q in 1/A; columns q, Iexp, Ierr, Icalc)
  SASDL27_fit1_model1.pdb         the atomic model of "fit1" (protein + 24-bp rat CRH DNA, with hydrogens, legacy
                                  DNA names G C A T and O5*, no chain ids)
                                  (https://www.sasbdb.org/media/pdb_file/SASDL27_fit1_model1.pdb)

Nothing was cleaned. The paper's SAXS methods give the buffer (50 mM Tris pH 7.5, 0.4 M NaCl,
2% glycerol, 2 mM DTT) and the temperature (12 C), the same as the SASBDB entry.

Round 5 decision (owner, 2026-11-13): the paper and SASBDB both say a bare "2% glycerol"; it is taken as v/v. Buffer, T and chi2 otherwise confirmed against Alazard 2007 (gkm453). KEEP.

q cut (round 9, 2026-11-13): the script fits q <= 0.3 A^-1 and leaves out the noise tail: S/N about 2 at 0.2; above the cut 10 of 63 points non-positive, mean I/sigma 0.7.
Every other entry without such a tail is fitted over its whole curve.
