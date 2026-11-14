SASBDB entry SASDV92  (https://www.sasbdb.org/data/SASDV92/)

Human hemoglobin (HbA, Sigma-Aldrich), 5 mg/ml, in 100 mM sodium phosphate buffer pH 7.0
with 10 % (w/v) PEG 600. Paper: Baranova I, Angelova A, Stransky J, Andreasson J,
Angelov B, J Phys Chem B (2024), DOI 10.1021/acs.jpcb.4c03003.
Files:
  experimental_data/SASDV92.dat   intensities_files/SASDV92.dat from SASBDB (q in nm^-1,
                               intensity 1/cm; buffer-subtracted, header kept)
  SASDV92_3ODQ.pdb                RCSB 3ODQ (human methemoglobin, 3.10 A), downloaded from
                               https://files.rcsb.org/download/3ODQ.pdb. The entry itself
                               has NO model, NO fit and no PDB link; 3ODQ is the model of
                               the PEG-free control SASDV62 (CRYSOL fit2, chi2 1.098), whose
                               own SASDV62_fit2_model1.pdb has identical ATOM/HETATM records.
There is no depositor fit, hence no .fit reference curve. The fitting script
test/fitting_tests/SASDV92/ states the conditions it takes from the entry and its assumptions.
Paper (PMC11440596) read on 2026-11-13: Table 1 row and methods are quoted in the script header.

Fit range (2026-11-13): the script cuts at q = 0.3 1/A (flat noise floor: above it 174 points, median I/sigma 0.11, 48 % I <= 0).
