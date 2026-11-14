SYN-1UBQ-lyz20: SYNTHETIC test entry (no measurement, no fit)

Host structure: PDB 1UBQ, ubiquitin (76 aa).
Source: https://files.rcsb.org/download/1UBQ.pdb (downloaded 2026-11-13, unmodified).
Cross-check: atom counts equal those of test/fixtures/molecules/1UBQ-TEST.* (the
download was used, not the checked-in copy).
What the loader sees: 602 ATOM records and 58 HETATM waters (HOH, dropped by the loader); no altlocs, no hydrogens.
No file was edited; nothing was cleaned.

Buffer: lysozyme crowder, 20 g/L (protein host in a protein crowder), plus 150 mM NaCl and nucleic-acid
counter-ions where DNA/RNA are present; pH 7.4, 25 C. INVENTED, not measured:
see test/synthetic_tests/SYN-1UBQ-lyz20/SYN-1UBQ-lyz20.jl for values and arithmetic.
Sequences and molar masses come from the RCSB polymer entities and chemical
components (data.rcsb.org), see the script header.

Outputs (written by the script next to itself): SYN-1UBQ-lyz20.profile.tsv, SYN-1UBQ-lyz20.solvent.txt.
