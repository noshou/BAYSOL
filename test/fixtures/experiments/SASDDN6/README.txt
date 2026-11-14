SASBDB entry SASDDN6  (https://www.sasbdb.org/data/SASDDN6/)

Human Hsp70 (HSPA1A T204A) antiparallel dimer (pre-incubated with ATP, dimer separated by SEC),
in-house SAXS (CEITEC BioSAXS-1000, 277 K, Cu Ka 1.54 A, 0.48 m), 50 mM HEPES, 150 mM
potassium acetate, 2 mM MgCl2, pH 7.5 (SASBDB buffer field).
Publication: Trcka F et al., Mol Cell Proteomics 2019, DOI 10.1074/mcp.RA118.001044. The paper
(PDF zjw320) was consulted: it confirms 277 K, 1.54 A, 0.48 m, CRYSOL 2.8.3 chi2 1.1 for this
curve, but names the SAXS buffer only as "size exclusion buffer" (analytical SEC in the paper:
25 mM HEPES, 150 mM KAc, 2 mM MgCl2); the SASBDB composition is used, no free ATP.
Files:
  experimental_data/SASDDN6.dat    SASBDB intensities file (q in A^-1)
  SASDDN6_fit1.fit                 SASBDB fitting file (CRYSOL, q in A^-1; chi2 1.150)
  SASDDN6_fit1_model1.pdb          SASBDB model (MODELLER homology model, two ATP; no PDB id)
No file was modified.

q cut (round 9, 2026-11-13): the script fits q <= 0.3 A^-1 and leaves out the noise tail: S/N about 1 beyond 0.2; above the cut 38 of 231 points non-positive, mean I/sigma 0.9 (48 of 430 in the whole curve).
Every other entry without such a tail is fitted over its whole curve.
