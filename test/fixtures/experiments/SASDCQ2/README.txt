SASBDB entry SASDCQ2  (https://www.sasbdb.org/data/SASDCQ2/)

Publication: 2017 publication guidelines for structural modelling of small-angle scattering data from biomolecules in solution: an update
DOI:         https://doi.org/10.1107/S2059798317011597

The publisher's PDF used to be kept in this folder. It was removed from the repository
(size, and the publisher's redistribution terms): fetch it from the DOI above. The
fitting script test/fitting_tests/SASDCQ2/ cites the sections and tables it takes the
buffer and sample conditions from.

q cut (round 9, 2026-11-13): the script fits q <= 0.3 A^-1 and leaves out the noise tail: the .dat ends with two identical rows (q 0.3104110062, same I and sigma) and one non-positive point at 0.3065; only 15 points lie above the cut, mean I/sigma 1.8.
Every other entry without such a tail is fitted over its whole curve.
