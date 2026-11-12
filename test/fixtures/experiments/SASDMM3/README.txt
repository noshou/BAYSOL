SASBDB entry SASDMM3  (https://www.sasbdb.org/data/SASDMM3/)

Publication: A monomeric mycobacteriophage immunity repressor utilizes two domains to
             recognize an asymmetric DNA sequence.
DOI:         https://doi.org/10.1038/s41467-022-31678-6

The publisher's PDF is not kept in this folder (size, and the publisher's redistribution
terms): fetch it from the DOI above. The fitting script test/fitting_tests/SASDMM3/ cites
the entry's metadata (SASBDB REST summary) for the buffer and the sample conditions.

Files (downloaded 2026-11-11; SASBDB URLs in brackets)
  experimental_data/SASDMM3.dat     media/intensities_files/SASDMM3.dat (q in 1/A, 0.0103-0.3002;
                                    columns q, I, sigma, no header, 521 points)
  SASDMM3_fit1_model1.pdb           media/pdb_file/SASDMM3_fit1_model1.pdb, BILBOMD, atomic:
                                    the 13-bp DNA ONLY (chains B and C, 824 atoms, 291 H)
  SASDMM3_fit1_model2.pdb           media/pdb_file/SASDMM3_fit1_model2.pdb, BILBOMD, atomic:
                                    the repressor ONLY (chain A, 203 residues, 2863 atoms,
                                    1198 H; carries the N-terminal His-tag MGSSHHHHHHSSGLVPRGSH)
  SASDMM3_fit1.fit                  media/fitting_files/SASDMM3_fit1.fit (FoXS, chi^2 1.179614, q in
                                    1/A; columns q, I_exp, sigma, I_fit; I_fit already scaled to the
                                    data, c = 3.17e-6). The ONE change to the downloaded bytes:
                                    the data rows were separated by lone CR characters (old
                                    Macintosh line ends), which Julia's `eachline` does not split,
                                    so they were turned into LF. No value was touched.

The deposited description says the data are best described as a mixture of 64 % free DNA and
36 % free protein (no complex). Model 1 is the DNA, model 2 the protein; the FoXS curve is the
fit of that mixture (SASBDB gives no per-model curves).
