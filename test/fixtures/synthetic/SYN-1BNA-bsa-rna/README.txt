SYN-1BNA-bsa-rna: SYNTHETIC test entry (no measurement, no fit)

Host structure: PDB 1BNA, the Dickerson-Drew dodecamer CGCGAATTCGCG (two chains A, B).
Source: https://files.rcsb.org/download/1BNA.pdb (downloaded 2026-11-13, unmodified).
Cross-check: atom counts equal those of test/fixtures/molecules/1BNA-TEST.* (the
download was used, not the checked-in copy).
What the loader sees: 486 ATOM records (residues DA, DC, DG, DT) and 80 HETATM waters (dropped); no altlocs, no hydrogens.
No file was edited; nothing was cleaned.

Buffer: BSA 50 g/L + tRNA 1 mg/ml (DNA host, protein + RNA solutes), plus 150 mM NaCl and nucleic-acid
counter-ions where DNA/RNA are present; pH 7.4, 25 C. INVENTED, not measured:
see test/synthetic_tests/SYN-1BNA-bsa-rna/SYN-1BNA-bsa-rna.jl for values and arithmetic.
Sequences and molar masses come from the RCSB polymer entities and chemical
components (data.rcsb.org), see the script header.

Outputs (written by the script next to itself): SYN-1BNA-bsa-rna.profile.tsv, SYN-1BNA-bsa-rna.solvent.txt.
