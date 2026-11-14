SYN-6LYZ-rnaap24: SYNTHETIC test entry (no measurement, no fit)

Host structure: PDB 6LYZ, hen egg-white lysozyme (129 aa).
Source: https://files.rcsb.org/download/6LYZ.pdb (downloaded 2026-11-13, unmodified).
Cross-check: atom counts equal those of test/fixtures/molecules/6LYZ-TEST.* (the
download was used, not the checked-in copy).
What the loader sees: 1001 ATOM records and 101 HETATM waters (HOH, dropped by the loader); no altlocs, no hydrogens.
No file was edited; nothing was cleaned.

Buffer: poly-A / poly-U 24-mers, 1 mg/ml total (protein host in an RNA oligo duplex), plus 150 mM NaCl and nucleic-acid
counter-ions where DNA/RNA are present; pH 7.4, 25 C. INVENTED, not measured:
see test/synthetic_tests/SYN-6LYZ-rnaap24/SYN-6LYZ-rnaap24.jl for values and arithmetic.
Sequences and molar masses come from the RCSB polymer entities and chemical
components (data.rcsb.org), see the script header.

Outputs (written by the script next to itself): SYN-6LYZ-rnaap24.profile.tsv, SYN-6LYZ-rnaap24.solvent.txt.
