SASBDB entry SASDVB2  (https://www.sasbdb.org/data/SASDVB2/)

Publication: Hemoglobin-PEG Interactions Probed by Small-Angle X-ray Scattering:
Insights for Crystallization and Diagnostics Applications (Baranova I, Angelova A,
Stransky J, Andreasson J, Angelov B; J Phys Chem B, 2024 Sep 9; DOI 10.1021/acs.jpcb.4c03003).
Files:
  experimental_data/SASDVB2.dat   SASBDB intensities_files/SASDVB2.dat (q in nm^-1)
  SASDVB2_3ODQ.pdb                RCSB https://files.rcsb.org/download/3ODQ.pdb, unchanged
                                  (human methemoglobin crystal structure, 3.1 A, chains A-D,
                                  4 HEM; the model of the PEG-free control SASDV62)
The entry has NO deposited atomic model and NO fit (SASBDB "fits": empty), so the
fixture has no reference curve. The fitting script test/fitting_tests/SASDVB2/ states the
conditions it takes from the entry and every assumption it makes.
NOTE: the metadata of SASDVB2 names 5 % PEG2000 in the buffer, but the data file's own
header ("NaP_Hb_2.001", parents 11_3_NaP_3 and 12_Hb_2.001_NaP_Hb_2.001) and the sample
name ("1 week after SEC") describe a PEG-free sample; see the script header.
Paper (PMC11440596) read on 2026-11-13: Table 1 row and methods are quoted in the script header.
The paper (Table 1, "Hb after 1 week": I(0) 0.1200, Rg 2.40 nm, Dmax 6.8 nm) confirms that
this sample has NO PEG; the SASBDB buffer field (5 % PEG2000) is a copy error. The script
uses a PEG-free buffer.

Fit range (2026-11-13): the script cuts at q = 0.15 1/A (flat noise floor: above it 434 points, median I/sigma 0.16, 45 % I <= 0).
