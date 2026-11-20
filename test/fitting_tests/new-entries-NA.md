# New nucleic-acid fitting-test entries (wired 2026-11-18, NOT RUN)

17 entries wired (11 RNA, 4 DNA G-quadruplex, 2 protein-DNA); about 40 candidates were screened
and the rest skipped (below). Nothing was run: each script was only parse-checked
(`Meta.parseall`). Every entry has `test/fixtures/experiments/<ID>/` (data, .fit, model,
README.txt; cleaned model copies sit next to the untouched original) and a script
`test/fitting_tests/<ID>/<ID>.jl` (SASDJX2: `SASDJX2_fit3.jl`, run name `res_fit3`). Each
script header says what was read in the paper, which values are SASBDB-only, and what is
flagged. The fixtures still need packing as `.7z` by the owner, if that is the convention.

## README rows

| Entry | System | Notes | refChi2 (depositor's χ²) |
|---|---|---|---|
| SASDKU3 | VS ribozyme II-III-VI junction J236 (RNA) | RNA alone; MES/KCl/5 mM Mg²⁺, 20 °C; cleaned model (RG5/RG3 -> G); data to 0.97 Å⁻¹, depositor fit to 0.30, whole curve fitted | CRYSOL 1.967 |
| SASDKV3 | VS ribozyme III-IV-V junction J345 (RNA) | as KU3 (RG5/RG3 -> G) | CRYSOL 0.834 |
| SASDKW3 | VS ribozyme stem-loop VI (RNA) | as KU3 (RG5/RC3 -> G/C) | CRYSOL 2.682 |
| SASDX54 | pre-miR-20a, 60 nt (RNA) | K-phosphate/NaCl/1 mM Mg²⁺, 22 °C (paper); FoXS fit, column 3; cleaned model (G5/C3) | FoXS 0.879 |
| SASDPL6 | SARS-CoV-2 5'-UTR SL2+3 (RNA) | K-phosphate pH 6.5/150 mM KCl/TCEP, 20 °C; q cut 0.70 Å⁻¹ | CRYSOL 1.189 |
| SASDPM6 | SARS-CoV-2 5'-UTR SL4 (RNA) | as PL6; SASBDB lists 1.61, the .fit gives 0.991 | CRYSOL 0.991 |
| SASDPP6 | SARS-CoV-2 5'-UTR Ext (RNA) | as PL6; SASBDB lists 1.412, the .fit gives 1.280 | CRYSOL 1.280 |
| SASDVX4 | ST9a xrRNA, 59 nt, 10 mM MgCl2 (RNA) | Tris/NaCl/DTT, 20 °C and 0.82 Å SASBDB-only; data to 1.9 Å⁻¹ | CRYSOL 5.915 |
| SASDVY4 | ST9a xrRNA, 59 nt, no Mg²⁺ (RNA) | as VX4 | CRYSOL 11.624 |
| SASDVC3 | SARS-CoV-2 5'-UTR SL5b (RNA) | K-phosphate pH 6.2/50 mM KCl, 20 °C (SASBDB only) | CRYSOL 4.742 |
| SASDVY2 | SARS-CoV-2 5'-UTR SL5a (RNA) | as VC3; q cut 0.70 Å⁻¹ | CRYSOL 2.111 |
| SASDMG6 | G-quadruplex DNA 5CMX (DNA) | BPEK K-phosphate/185 mM KCl/EDTA; buffer partly SASBDB | CRYSOL 1.854 |
| SASDME6 | G-quadruplex DNA 6NEB (DNA) | as MG6; HETATM nucleotides converted to ATOM | CRYSOL 3.04 |
| SASDMJ6 | G-quadruplex DNA cMyc-8 (DNA) | as MG6; cleaned model (DG5/DG3 -> DG, K+ -> K), unverified | CRYSOL 1.620 |
| SASDMK6 | G-quadruplex DNA cKit-8 (DNA) | as MJ6 | CRYSOL 1.187 |
| SASDML3 | TipsytheTRex repressor + 24-bp DNA | Tris/0.5 M NaCl, 20 °C (paper); FoXS on a BILBOMD model; HSD -> HIS | FoXS 1.624 |
| SASDJX2 fit3 | EcoKMcrA dimer + hemimethylated 12-bp DNA | Tris/200 mM KCl/EDTA/azide/DTT; 20 °C SASBDB-only | CRYSOL 1.513 |

## Open points

- Nothing was run. Every script is unchecked beyond parsing; hydrogenation of the cleaned
  models (K ion, legacy GUA/CYT/URI/ADE names in VC3/VY2, `ATOM`-written ions) is untested.
- SASDVX4/VY4: the curve reaches 1.9 Å⁻¹ with usable data throughout (no cut by the
  README rule), so the whole range is fitted; the forward model will need a high band limit
  (cost risk). A cut at the depositor's 1.48 Å⁻¹ would need a decision.
- SASDPM6/PP6: SASBDB's listed χ² (1.61, 1.412) disagrees with the .fit headers
  (0.991, 1.280); the .fit-consistent values are used.
- G-quadruplex entries (MG6, ME6, MJ6, MK6): the paper gives no phosphate concentration
  or temperature. The 8 mM total phosphate and 22 °C are SASBDB's; the paper says potassium
  phosphate where SASBDB writes Na salts, and SASBDB's 6:2 ratio does not match pH 7.2, so
  the species are computed from the pH with K⁺ (flagged). MJ6/MK6 cleaned models rename
  DG5/DG3/K+ and are unverified against the hydrogenator.
- SASDML3: the header says 705 points (χ² 1.624) but the .fit has 520 rows, which
  recompute to 1.661. The data reach 0.403 Å⁻¹; the depositor's fit ends at 0.30.
- SASBDB-only values: temperature of VX4, VY4, VC3, VY2, JX2, G4 set; wavelengths of
  KU3-KW3, VX4/VY4, VC3, VY2, JX2, G4 set. TCEP (PL6/PM6/PP6; paper says "TCEP or DTT"),
  BME (X54; omitted), EDTA (as `H2EDTA`, K⁺ counter-ions omitted) and azide are
  approximations or SASBDB-only.
- The Mg²⁺ of the VS and ST9a buffers is a plain solute; binding to the RNA is not modelled.
- pH is assumed set at 22 ± 3 °C for every buffer (the sources do not say).

## Skipped (with reasons)

- SASDAH5 (Hfq-DsrA): the paper states 50 mM bicine pH 8.8, 100 mM NaCl, 250 mM KCl at
  35 °C, contradicting SASBDB (Tris); bicine has no pK entry; the model has dummy residues.
- SASDH44, SASDH54, SASDP24, SASDPZ3 (XPA/RPA-DNA): CYF/ZN2/UNK residue naming; the SAXS
  buffer was not confirmed in the paper; PZ3 not fetched.
- SASDXV3: HIE/CY1 residues and 4 °C.
- SASDLS7: the paper does not cover LS7 (it names MK3, ML3, MM3); HSD naming.
- SASDFV5, SASDFP5, SASDFQ5, SASDFW5 (HU-DNA): Bis-Tris pK/ΔH not in the table.
- SASDM36, SASDMN6: larger multi-G4 entries, dropped to limit count.
- No open-access paper found to take the buffer from: SASDNJ7, SASDUS8, SASDUT8, SASDMY4,
  SASDAB7, SASDAC7, SASDA88, SASDAV7.
- No nucleosome, tRNA or riboswitch entry passed the structural filter, hence 17, not 25.
