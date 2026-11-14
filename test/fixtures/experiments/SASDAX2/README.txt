SASBDB entry SASDAX2  (https://www.sasbdb.org/data/SASDAX2/)

Publication: Crystal versus solution structures of thiamine diphosphate-dependent
enzymes (Svergun DI, Petoukhov MV, Koch MH, Koenig S; J Biol Chem, 2000 Jan 7;
PMID 10617618; the SASBDB entry gives no DOI).
Files, all from SASBDB:
  experimental_data/SASDAX2.dat   intensities_files/SASDAX2.dat (q in nm^-1)
  SASDAX2_fit1.fit                fitting_files/SASDAX2_fit1.fit (CRYSOL, q in A^-1)
  SASDAX2_fit1_model1.pdb         pdb_file/SASDAX2_fit1_model1.PDB (the crystal model)
The fitting script test/fitting_tests/SASDAX2/ states the buffer and sample conditions
it takes from the entry; the paper was not consulted.

Edit of one file (2026-11-11): SASDAX2_fit1_model1.pdb as downloaded had three mail-header
lines pasted into its REMARK block ("Content-type: text/plain...", "Content-disposition:
inline...", "Content-transfer-encoding: 7bit" plus a blank line, after "REMARK 265"), which
pdb2pqr rejects ("No biomolecule heavy atoms found"). Those lines were removed (line 65 is
now a bare "REMARK 265"); no coordinate was changed.

q cut (round 9, 2026-11-13): the script fits q <= 0.3 A^-1 and leaves out the noise tail: S/N about 1-2 from 0.2; above the cut 24 of 145 points non-positive, mean I/sigma 0.9.
Every other entry without such a tail is fitted over its whole curve.
