SASBDB entry SASDLP4  (https://www.sasbdb.org/data/SASDLP4/)

Publication: Protein quaternary structures in solution are a mixture of multiple forms
DOI:         https://doi.org/10.1039/d2sc02794a

The publisher's PDF used to be kept in this folder. It was removed from the repository
(size, and the publisher's redistribution terms): fetch it from the DOI above. The
fitting script test/fitting_tests/SASDLP4/ cites the sections and tables it takes the
buffer and sample conditions from.

q cut (round 9, 2026-11-13): the script fits q <= 0.7 A^-1 and leaves out the noise tail: I/sigma above 2 up to about 0.67 then noise; above the cut 21 of 116 points non-positive, mean I/sigma 1.0 (raised from 0.3 in round 9).
Every other entry without such a tail is fitted over its whole curve.
