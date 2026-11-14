SASBDB entry SASDA58  (https://www.sasbdb.org/data/SASDA58/)

pUL26N, the protease domain of the Pseudorabies virus assemblin (dimer, 45 kDa), 9.83 mg/ml in
50 mM Tris/HCl pH 7.5, 0.5 M NaCl, 0.25 M imidazole, 5 % glycerol, 50 mM urea, 0.2 M MgCl2
(SASBDB buffer fields), 10 C; EMBL P12, PETRA III.
Publication: Zuhlsdorf M, Werten S, Klupp BG, Palm GJ, Mettenleiter TC, Hinrichs W,
"Dimerization-Induced Allosteric Changes of the Oxyanion-Hole Loop Activate the Pseudorabies
Virus Assemblin pUL26N, a Herpesvirus Serine Protease", PLoS Pathog 2015,
DOI 10.1371/journal.ppat.1005045. Paper read in full (2026-11-13 audit): wavelength 1.24 A,
sample temperature 283 K, base buffer 0.5 M NaCl, 50 mM Tris pH 7.5, 0.25 M imidazole, 5 %
glycerol, 50 mM urea; a second series adds 0.2 M MgCl2, and this 10 mg/ml dimer curve is that
one (the paper's ab initio model is 10 mg/ml with MgCl2), as in the SASBDB buffer fields.
Files, all from SASBDB (https://www.sasbdb.org/rest-api/entry/summary/SASDA58/):
  experimental_data/SASDA58.dat    media/intensities_files/SASDA58.dat (q in nm^-1)
  SASDA58_fit1.fit                 media/fitting_files/SASDA58_fit1.fit (CRYSOL layout, q in A^-1)
  SASDA58_fit1_model1.pdb          media/pdb_file/SASDA58_fit1_model1.pdb (atomic, SASBDB states
                                   it is identical to PDB 4V07; dimer, no hydrogens)
SASDA58 has two fits: fit1 is the atomic model (chi2 1.288; used) and fit2 is DAMMIN (chi2
1.196; not used).

Round 5 rescan (2026-11-13): verdict KEEP, see notes/new-entries/AUDIT5-A.md.

q cut (round 9, 2026-11-13): the script fits q <= 0.17 A^-1 and leaves out the noise tail: S/N falls to about 1 beyond 0.175; 350 of 1661 points are non-positive, the first at 0.175; above the cut 1040 points, mean I/sigma 0.45.
Every other entry without such a tail is fitted over its whole curve.
