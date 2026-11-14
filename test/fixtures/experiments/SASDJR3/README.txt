SASBDB entry SASDJR3  (https://www.sasbdb.org/data/SASDJR3/)

Nucleotide-binding domain SaNsrF (Streptococcus agalactiae), in-house SAXS, 100 mM HEPES,
150 mM NaCl, 10 % glycerol, pH 8, 15 C.
Publication: Furtmann F et al., Sci Rep 2020, DOI 10.1038/s41598-020-72237-7 (read via
Europe PMC PMC7494861 and the PDF in sources/, 2026-11-13: it names no SAXS buffer, so the
SASBDB one, the only statement of it, is used).
Files:
  experimental_data/SASDJR3.dat    SASBDB intensities file (q in nm^-1, absolute scale)
  SASDJR3_fit2.fit                 SASBDB fitting file (CRYSOL, q in A^-1; chi2 1.156)
  SASDJR3_fit2_model1.pdb          SASBDB model (TopModel homology model), ORIGINAL
  SASDJR3_fit2_model1_HIS.pdb      CLEANED COPY used by the fit: residue name HIE -> HIS in
                                   102 atom records (columns 18-20), nothing else changed.
                                   components.tsv knows HIE as an unrelated drug-like
                                   component, so the loader would not read it as histidine.
SASDJR3 has two fits: fit1 is GASBOR (chi2 0.97; not used), fit2 is CRYSOL (used).

q cut (round 9, 2026-11-13): the script fits q <= 0.3 A^-1 and leaves out the noise tail: S/N about 1-2 beyond 0.14; above the cut 39 of 202 points non-positive, mean I/sigma 1.0 (80 of 682 in the whole curve).
Every other entry without such a tail is fitted over its whole curve.
