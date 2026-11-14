SYN-1EHZ-ubq30: SYNTHETIC test entry (no measurement, no fit)

Host structure: PDB 1EHZ, yeast tRNA-Phe (76 nt, one chain).
Source: https://files.rcsb.org/download/1EHZ.pdb (downloaded 2026-11-13, unmodified).
Cross-check: atom counts equal those of test/fixtures/molecules/1EHZ-TEST.* (the
download was used, not the checked-in copy).
What the loader sees: 1329 ATOM records (A, C, G, U) and 492 HETATM records: 160 waters (dropped), 6 MG and 3 MN ions (kept as ligands, heavy atoms only), and 323 atoms of modified nucleotides (1MA 23, 2MG 24, 5MC 42, 5MU 21, 7MG 24, H2U 40, M2G 25, OMC 21, OMG 24, PSU 40, YYG 39 atoms) that the loader hydrogenates through their parent base; no altlocs, no hydrogens.
No file was edited; nothing was cleaned.

Buffer: ubiquitin crowder, 30 g/L (RNA host in a protein crowder), plus 150 mM NaCl and nucleic-acid
counter-ions where DNA/RNA are present; pH 7.4, 25 C. INVENTED, not measured:
see test/synthetic_tests/SYN-1EHZ-ubq30/SYN-1EHZ-ubq30.jl for values and arithmetic.
Sequences and molar masses come from the RCSB polymer entities and chemical
components (data.rcsb.org), see the script header.

Outputs (written by the script next to itself): SYN-1EHZ-ubq30.profile.tsv, SYN-1EHZ-ubq30.solvent.txt.
