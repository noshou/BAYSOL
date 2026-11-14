SYN-6LYZ-ubq-dna: SYNTHETIC test entry (no measurement, no fit)

Host structure: PDB 6LYZ, hen egg-white lysozyme (129 aa).
Source: https://files.rcsb.org/download/6LYZ.pdb (downloaded 2026-11-13, unmodified).
Cross-check: atom counts equal those of test/fixtures/molecules/6LYZ-TEST.* (the
download was used, not the checked-in copy).
What the loader sees: 1001 ATOM records and 101 HETATM waters (HOH, dropped by the loader); no altlocs, no hydrogens.
No file was edited; nothing was cleaned.

Buffer: ubiquitin 20 g/L + DNA 1 mg/ml (protein host, protein + DNA solutes), plus 150 mM NaCl and nucleic-acid
counter-ions where DNA/RNA are present; pH 7.4, 25 C. INVENTED, not measured:
see test/synthetic_tests/SYN-6LYZ-ubq-dna/SYN-6LYZ-ubq-dna.jl for values and arithmetic.
Sequences and molar masses come from the RCSB polymer entities and chemical
components (data.rcsb.org), see the script header.

Outputs (written by the script next to itself): SYN-6LYZ-ubq-dna.profile.tsv, SYN-6LYZ-ubq-dna.solvent.txt.
