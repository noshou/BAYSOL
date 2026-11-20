# New protein entries B (SASDN.. to SASDZ..), added 2026-11-18

Seven entries wired, none run (inputs only: no fit, smoke run or benchmark was started). Each has a
script `test/fitting_tests/<ID>/<ID>.jl` and fixtures in `test/fixtures/experiments/<ID>/`
(`experimental_data/<ID>.dat`, the model, the CRYSOL `.fit`, `README.txt`). Shared files (README tables,
`common.jl`, `dev/`) were not touched; the `.7z` archives of the new entries are not made (`bysl fixtures
pack` does that). All scripts were parse-checked with `Meta.parseall` (no errors, lines at most 92 columns).

Each entry has ONE structure (a single atomic model), a downloadable CRYSOL `.fit` whose header chi2 was
recomputed from its columns, and a buffer read from the open-access paper (DOI in each script header;
SASBDB agreed in every case). Q cuts only where the README rule holds (SASDNK8 0.25, SASDPV7 0.36, SASDVR6
0.26 Å⁻¹; numbers in the script headers).

## README-table rows (format of "Replacement entries")

| Entry | System | Notes | refChi2 (depositor's χ²) |
|---|---|---|---|
| SASDN75 | SCO3201 TetR/AcrR-like regulator (S. coelicolor), homodimer, 5EFY chains C+D (2574 heavy atoms), in 20 mM Tris, 400 mM NaCl, 50 mM imidazole, 1 mM DTT, pH 8.5, 20 °C | protein; ESRF BM29; FEBS J 2022 DOI 10.1111/febs.16606 (paper read: buffer as SASBDB); Tris and imidazole share the HCl counter-ion (10.0 mM chloride, I about 0.41 M); whole curve to 0.497 Å⁻¹ (README q-cut rule not met); header and recomputed χ² agree | CRYSOL 1.171 |
| SASDNF7 | human CK2α, apo (PDB 3Q04, 328 residues, 3058 records) in 25 mM Tris, 500 mM NaCl, pH 8.5, 20 °C | protein; ESRF BM29; Front Mol Biosci 2022 DOI 10.3389/fmolb.2022.906390 (paper read: buffer as SASBDB); Tris-HCl chloride counter-ion; the model carries 3 SO4, 1 EDO and altlocs; CRYSOL fit1 overlay (fit2 DAMMIF not used) | CRYSOL 1.29 |
| SASDNK8 | NSD3 C-terminal construct (MDFF-refined RaptorX model, 2806 heavy atoms, no Zn) in 0.5 M NaCl, 20 mM Tris-HCl, 5 mM DTT, pH 8.5, 20 °C | protein; Diamond B21 SEC-SAXS; Front Mol Biosci 2024 DOI 10.3389/fmolb.2024.1191246 (paper read: buffer as SASBDB); Tris-HCl chloride counter-ion; MDFF model fitted to this curve; q cut 0.25 Å⁻¹ (README rule); CRYSOL fit1 overlay (fit2 DAMMIN not used) | CRYSOL 1.228 |
| SASDNL8 | NSD3 PWWP2-SET construct (MDFF-refined RaptorX model, 3033 heavy atoms, no Zn) in 0.5 M NaCl, 20 mM Tris-HCl, 5 mM DTT, pH 8.5, 20 °C | protein; Diamond B21 SEC-SAXS; same paper and buffer as SASDNK8 (DOI 10.3389/fmolb.2024.1191246); Tris-HCl chloride counter-ion; MDFF model fitted to this curve; whole curve to 0.232 Å⁻¹; CRYSOL fit1 overlay (fit2 DAMMIN not used) | CRYSOL 1.066 |
| SASDNP5 | human TEX12 coiled-coil tetramer (PDB 6HK8, 2444 records) in 20 mM Tris, 150 mM KCl, pH 8.0, 25 °C (assumed) | protein; Diamond B21 SEC-SAXS; Commun Biol 2022 DOI 10.1038/s42003-022-03886-9 (paper read: buffer as SASBDB); Tris-HCl chloride counter-ion; temperature not stated, 25 °C default; 12.4 keV from the paper; model has altlocs, partial hydrogens and reused chain ids; CRYSOL fit2 overlay (fit1 DAMMIF not used), depositor χ² 1.535 | CRYSOL 1.535 |
| SASDPV7 | SmTetX flavin monooxygenase (M154I/A283T, preliminary model of 8AQ8 with FAD, 2665 records) in 25 mM Bis-Tris, 150 mM NaCl, pH 6.5, 4 °C | protein; in-house Anton Paar SAXSpoint 2.0; Acta Cryst F 2023 DOI 10.1107/S2053230X23005381 (paper read: buffer as SASBDB); Bis-Tris-HCl chloride counter-ion; 4 °C; q cut 0.36 Å⁻¹ (README rule); depositor fit only to 0.150 Å⁻¹, so refChi2 is not like for like; CRYSOL fit1 overlay (fit2 DAMMIF not used) | CRYSOL 1.05 |
| SASDVR6 | human VPS26C (AlphaFold model, 297 residues, 2319 heavy atoms) in 50 mM Tris, 150 mM NaCl, 1 mM TCEP, pH 7.5, 25 °C | protein; Diamond B21 SEC-SAXS; EMBO Rep 2024 DOI 10.1038/s44319-024-00340-1 (paper read: buffer as SASBDB); Tris-HCl chloride counter-ion (42.9 mM); AlphaFold model; q cut 0.26 Å⁻¹ (README rule), refChi2 over the whole curve; CRYSOL fit1 overlay (3-column .fit; fit2 DAMMIN not used) | CRYSOL 1.152 |

## Open points

- Amine buffers: every entry is a Tris or Bis-Tris buffer titrated with HCl, so each has a computed
  chloride row (Davies method of `notes/buffer-templates.md`, as in SASDCM5/SASDA58). Chloride (mM): N75
  10.02 (Tris + imidazole jointly, I about 0.41 M), NF7 9.55, NK8 and NL8 7.64, NP5 13.10, PV7 14.73,
  VR6 42.92. The pH is taken as set at 22 °C with no shift to the measuring temperature (4 °C for PV7).
  The Bis-Tris and imidazole constants of `buffer_templates.json` are marked `verified: false` there (no
  independent pK within tolerance), so SASDPV7 and SASDN75 lean on those.
- SASDNP5: temperature stated neither in SASBDB nor in the paper text read; 25 °C is the flagged default.
  The energy is the paper's 12.4 keV (SASBDB's wavelength 0.095 nm would be 13.05 keV). The model (PDB 6HK8)
  reuses chain ids A, B, A, B in four TER blocks (the loader relabels), has 66 atoms with alternate
  locations and 236 hydrogens on 11 C-terminal residues only; how pdb2pqr treats those partial hydrogens
  has not been checked. High depositor χ² (1.535).
- SASDNF7: the model carries 3 SO4 and 1 EDO that the loader keeps as known ligands but that are not in
  the SAXS buffer; 13 atoms with altloc B and ANISOU lines.
- SASDNK8, SASDNL8: the models are RaptorX models refined by MDFF against these very curves (the depositor
  χ² is a goodness of an adapted model) and lack the zinc ions. SASDNL8's depositor fit starts at 0.0119
  Å⁻¹ while the data start at 0.0026 Å⁻¹.
- SASDPV7: the depositor fit ends at 0.1503 Å⁻¹ (242 rows, recomputed χ² 1.058 against the header 1.050)
  while the script fits to 0.36 Å⁻¹, so the refChi2 is not like for like; the model is a preliminary
  REFMAC model of 8AQ8 (FAD and one Cl⁻ as HETATM, kept by the loader).
- SASDVR6: AlphaFold model; the `.fit` has three columns (q, I_exp, I_fit), so the reference curve is
  column 3; the refChi2 covers the whole curve (over q ≤ 0.26 Å⁻¹ the same fit has χ² 1.202).
- Wavelengths of all seven come from SASBDB (`xray_energy` null; the `wavelength` field is in nm), except
  SASDNP5. Data labelled "1/A" (NK8, NL8, NP5, VR6) are in Å⁻¹ already; N75, NF7 and PV7 are in nm⁻¹ and
  converted.
- The script header states the paper was read for the buffer; the DOI is given in each header. Nothing
  was run, so the LOG and the Results table have no rows for these entries yet.

## Skipped (checked and not wired)

| Entry | Reason |
|---|---|
| SASDNV2 | paper not open access, buffer cannot be verified |
| SASDR25 | buffer not found in the paper |
| SASDT82, SASDWG9, SASDVQ9, SASDWP9 | papers not open access |
| SASDSU8 | SAXS buffer not found |
| SASDTX8 | paper and SASBDB buffers conflict |
| SASDRQ8 | the paper is about mRNA nanoparticles, not a protein structure |
| SASDPK6, SASDS36 | SASBDB chi2 inconsistent with the `.fit` columns |
| SASDSN7 | MD frame without chain ids |
| SASDN85 | 396 kDa, above the heavy-atom budget |
| SASDPB9 | derived model, not the deposited structure |
| SASDU79, SASDVH7, SASDQ97 | noisy tail or high χ² without a usable q cut |
| CRYSON/SANS entries and MultiFoXS/BILBOMD/EOM/SASREF entries | multi-structure or neutron, outside the rules |
