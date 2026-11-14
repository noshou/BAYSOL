SYN-1CRN-dna-rna: SYNTHETIC test entry (no measurement, no fit)

Host structure: PDB 1CRN, crambin (46 aa).
Source: https://files.rcsb.org/download/1CRN.pdb (downloaded 2026-11-13, unmodified).
Cross-check: atom counts equal those of test/fixtures/molecules/1CRN-TEST.* (the
download was used, not the checked-in copy).
What the loader sees: 327 ATOM records, no HETATM, no altlocs, no hydrogens; plain protein.
No file was edited; nothing was cleaned.

Buffer: DNA 1 mg/ml + tRNA 2 mg/ml (protein host, DNA and RNA solutes), plus 150 mM NaCl and nucleic-acid
counter-ions where DNA/RNA are present; pH 7.4, 25 C. INVENTED, not measured:
see test/synthetic_tests/SYN-1CRN-dna-rna/SYN-1CRN-dna-rna.jl for values and arithmetic.
Sequences and molar masses come from the RCSB polymer entities and chemical
components (data.rcsb.org), see the script header.

Outputs (written by the script next to itself): SYN-1CRN-dna-rna.profile.tsv, SYN-1CRN-dna-rna.solvent.txt.
