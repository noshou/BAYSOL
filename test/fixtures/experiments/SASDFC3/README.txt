SASBDB entry SASDFC3  (https://www.sasbdb.org/data/SASDFC3/)

ATP citrate lyase tetramer
Publication DOI: 10.1038/s41586-019-1095-5
The publisher's PDF is not kept in this folder. The paper was consulted only for SASDRR8
(Europe PMC); the others were unreachable, so their buffer, temperature and wavelength are
the SASBDB entry's (see the header of test/fitting_tests/SASDFC3/SASDFC3_fit1.jl).

Files: SASDFC3_fit1_model1.pdb (SASBDB's model, unmodified), SASDFC3_fit1.fit (depositor fit),
experimental_data/SASDFC3.dat. Reference: FoXS 5.473 (header Chi^2 5.47305 = chi2).
Conditions: 20 °C, 0.124 nm (SASBDB).
Model: 34656 heavy atoms, no HETATM (CoA and citrate in the sample, not in the model).

q cut (round 9, 2026-11-13): the script fits q <= 0.47 A^-1 and leaves out the noise tail: I/sigma near 3 up to 0.45 then falls; above the cut 17 of 132 points non-positive, mean I/sigma 1.3 (raised from 0.3 in round 9).
Every other entry without such a tail is fitted over its whole curve.
