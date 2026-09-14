# PartialMolarVolumes

Partial molar volume (V0, cm3/mol) data for solutes and solvent, used to build prior on solute excluded volume for the Bayesian SH-coefficient fit.

## General assumptions

- At typical buffer  concentrations (~10-150 mM) a few cm3/mol of V0 error moves the electron density by a fraction of a percent. Exact protonation state, temperature correction, etc. are only worth  chasing for solutes pushed to molar concentration (ex: 6 M urea, 50% w/w glycerol), where V0 error propagates enough to bias the fit. Users must input custum arguments to make it work.
- **Additivity / dilute-limit assumption.** Solution volume is taken as `V(solution) ≈ V0(water) + Σ nᵢ·V0(soluteᵢ)` at infinite dilution. Young's rule / ideal-mixing hold that the rules for low concentrations, and assume zero interactions between solutes.
- **Units**: V0 in cm3/mol, at 298.15 K and ~0.1 MPa unless a source states otherwise. `uncertainty_cm3_per_mol` is the source's own reported standard error, not a subjective error bar; left blank where a source doesn't report one.

## Water.jl

Bulk water electron density is the baseline every solute V0 sits on top of (via the additivity assumption above).

- Pure water only; no dissolved-gas or isotopic (H2O vs D2O) correction.
- `Z_H2O = 10` (2 from H, 8 from O) assumes intact, un-ionized H2O

## NonProteins/

pH-dependent protonation has to be applied at read time.

### nonproteins.tsv

Columns: `common_name`, `iupac_name`, `formula`, `charge`, `v0_cm3_per_mol`, `uncertainty_cm3_per_mol`, `basis`, `doi`. IUPAC names have not been verified yet.

Caveats worth knowing before trusting specific rows:

- Many rows cite Krumgalz/Pogorelsky/Pitzer `10.1063/1.555981` or Millero `10.1021/cr60270a001` which are compilations. Where they disagree, one was picked arbitrarily.
- `KH2PO4`/`K2HPO4`/`K3PO4`/`Na3PO4`/`NaH2PO4`/`LiH2PO4`/`Na2HPO4` (DOI `10.1016/j.jct.2013.01.012`) were back-calculated from raw density data via Masson-equation extrapolation (`Vφ = V0 + Sv·√m`), since the source only reports density/sound velocity. `Na2HPO4` has high standard deviation (jackknife SE ≈ 8.4, more than half the value), so treat it as low-confidence.
- `trisodium citrate` has two independent, disagreeing sources: 57.1 (`10.1016/j.molliq.2004.07.014`) vs. Apelblat & Manzurola's 69.32 (`10.1016/0378-3812(90)85049-G`). Cross-checks (agreement with an independent `disodium hydrogen citrate` measurement, and Apelblat's dissociation-step volume changes) favor 69.32.

### nonproteins.json

`iupac_name -> [electron_count, v0_cm3_per_mol, uncertainty_cm3_per_mol]`. `electron_count` (sum of atomic numbers − charge). Where multiple source rows share one
`iupac_name`, `basis=measured` is taken over`derived`/`predicted`; ties are broken by lower `uncertainty_cm3_per_mol`; finally if nothing breaks tie they are picked arbitrarily.

### iupac_to_common.json / common_to_iupac.json

`iupac_to_common.json` is `iupac_name -> [common_name, ...]`.

## Proteins

### proteins.tsv

Columns: `Group`, `Name`, `Temperature_C`, `Uncertainty`, `V0`, `basis`, `doi`. `doi`/`basis` were added as per-row columns (previously one fixed source, `10.1039/9781782627043-00542`, for the whole file) to accommodate `Sec`/`Pyl` below, which are `derived` rather than `measured`.

**`Sec` (selenocysteine) and `Pyl` (pyrrolysine)**: neither has a published aqueous infinite-dilution V0 anywhere in the literature — both are constructed here via group additivity, at very different confidence levels. `doi` cites the source of the *input* values used (Lee et al. 2008, same as the rest of this file), not a paper reporting Sec/Pyl directly.

- **`Sec` = 34.2 ± 2.0** (25°C): `Cys` (29.7) + a Se-for-S substitution increment. That increment (≈2.6 cm³/mol) comes from the bare van der Waals sphere-volume difference between S (Bondi radius 1.80 Å) and Se (~1.90 Å, standard periodic-table value), widened to a central estimate of 4.5 with a large error bar since real substitutions typically show a somewhat bigger increment than the bare-sphere number (polarizability/hydration effects on top). Moderate confidence — single clean atom substitution, transparent method, but the increment itself isn't independently literature-verified for an *aqueous* PMV context (only the underlying atomic radii are).
- **`Pyl` = 128.2 ± 19.0** (25°C): built from `Lys` (70.1) plus an estimate of the added Nε-(4-methyl-3,4-dihydro-2H-pyrrole-2-carbonyl) group, using `Pro`'s real side-chain value (35.6) as the closest existing ring analog, plus a rough carbonyl contribution (~11, half of this file's own `–CONH–` value), plus a methyl-branch contribution (~16, from `-CH2-`), minus a small correction for the ring's extra unsaturation (~−3). The Pyl/Lys molecular-formula difference (+C6H7NO) is a solid, self-consistent check (both full formulas are standard facts); the volume decomposition on top of it is a stack of several rough proxies, not a real derivation — **treat this as a much lower-confidence scaffold than `Sec`**, closer to "least-implausible order of magnitude" than a defensible number. Revisit if a real Cabani-et-al.-style group-volume table or any direct Pyl measurement ever turns up.

**`A_RNA`/`C_RNA`/`U_RNA` (adenine, cytosine, uracil — free nucleobases, not nucleosides)**: real `measured` V0 at 25°C, pulled directly from two saved PDFs in this directory:
- Patel & Kishore, *J. Solution Chem.* 24, 25–38 (1995), DOI `10.1007/BF00973047`, Table IV: Cytosine 73.15±0.12, Uracil 71.94±0.17, Adenine 87.22±0.18 (also covers several nucleosides, not added here).
- Fucaloro et al., *J. Solution Chem.* 37, 1289–1304 (2008), DOI `10.1007/s10953-008-9302-2`, Table 2: Uracil 72.02±0.10, Adenine 88.59±0.22 (own independent measurement; also covers Thymine, not currently used anywhere in this project).
- The two papers cross-validate each other well (uracil and adenine both agree within combined uncertainty). Both rows kept per salt, following this project's general pattern of not picking a winner between independent sources.

**`G_RNA` (guanine) = 91.2 ± 7.0** (25°C, `derived`, low confidence): guanine has no published aqueous V0 anywhere — its solubility is so low (~4×10⁻⁵ M) that a 2018 *J. Phys. Chem. B* paper found its dissolution is obscured by nanoparticle formation rather than clean molecular solvation, so a direct densimetry measurement may not even be meaningful. Estimated as `Adenine + [ring-oxygen increment]`: guanine's molecular formula is exactly adenine's plus one oxygen (C5H5N5 → C5H5N5O, a solid fact), but that increment isn't cleanly isolable from any real comparison in this file (the closest, cytosine vs. uracil, swaps an NH2 for an O simultaneously, not a clean single-atom probe) — same confidence tier as `Pyl` above, a scaffold, not a derivation.

### ionization.tsv

Columns: `Group`, `Name`, `Reaction`, `Temperature_C`, `pKa`, `pKa_Uncertainty`, `dV` (cm³/mol), `dV_Uncertainty`, `dKS` (adiabatic compressibility change, ×10⁻⁴ cm³ mol⁻¹ bar⁻¹),
`dKS_Uncertainty`, `basis`, `doi`.

Source for all rows except `Sec`: Lee, Tikhomirova, Shalvardjian & Chalikian, *Biophys. Chem.*, 2008, 134, 185–199 (DOI `10.1016/j.bpc.2008.02.009`). `doi`/`basis` were added as per-row columns (rather than one fixed source for the whole file) specifically to accommodate `Sec`, which comes from elsewhere.

**`R-basic`'s `dV_Uncertainty` in `proteins.json`** (`0.1`) is a manually-inserted standard placeholder, not a value reported by Lee et al. — that paper gives Arg's `dV` at 25°C with no uncertainty at all (still blank in `ionization.tsv`/this file's own row). Treat it as a reasonable-looking filler rather than sourced data if it ever needs reconciling with `ionization.tsv`.

**`Sec` (selenocysteine)**, row `basis=derived` (mixed-provenance row — see below), `doi` = Huber & Criddle:
- `pKa` = 5.24, a real titration measurement (Huber & Criddle, *Arch. Biochem. Biophys.*, 1967, 122, 164–173, DOI `10.1016/0003-9861(67)90136-1`). A frequently-cited companion number, pKa=5.47 (Byun & Kang, *Biopolymers*, 2011, 95, 345–353, DOI `10.1002/bip.21581`), is a **computational** DFT/implicit-solvation prediction, not a measurement — deliberately not used here despite showing up in secondary sources as if it were experimental.
- `dV` = 4 ± 4 cm³/mol is **not from either of those papers** — no source reports a volume-of-ionization for the selenol at all. This is our own estimate: buffer-ionization ΔV° values for large, "soft" ionizing groups (MOPS/HEPES/Tris-type, sulfonate/amine) run ~5-7 cm³/mol, versus ~12 cm³/mol for Asp/Glu's compact, charge-dense carboxylate — bigger/softer/more polarizable groups electrostrict water less. Se⁻ is larger and more polarizable than any of those, so the central estimate sits below that 5-7 range; the ±4 uncertainty is wide enough to admit the true value could be near zero, since the sign itself isn't fully certain for an anion this soft. `dKS`/`dKS_Uncertainty` remain blank — no attempt made to estimate compressibility.
- The row's `basis`/`doi` describe the pKa; `dV` is a separate, later, self-derived addition the single per-row columns can't cleanly flag on their own — noted here instead.

**Pyrrolysine is absent from this file, not merely unfilled** — its side-chain nitrogen is part of a pyrroline ring fused to an amide linkage, not a standard ionizable group the way Lys's ε-amino is, and no reliable experimental pKa exists for it in the literature (only unvalidated computational predictions). Treated the same as every other non-titratable residue: absence here means "not corrected," per the general convention above.

**`proteins.tsv` now has `Sec`/`Pyl` V0 entries too** (see that section below) — both `derived`, at very different confidence levels: Sec via a clean single-atom Se/S substitution, Pyl via a much rougher stacked group-additivity scaffold.

**`A_RNA`/`C_RNA`/`G_RNA`/`U_RNA` (adenine, cytosine, guanine, uracil — the free nucleobases, not nucleosides)**, all `doi` = Krishnamurthy, *Acc. Chem. Res.* 2012, 45, 2035–2044 (DOI `10.1021/ar200262x`), all `basis=derived` (mixed-provenance rows, same reason as `Sec`):
- `pKa`: **4.1 (cytosine, N3 protonation) and 9.5 (guanine, N1 deprotonation) are real numbers taken directly from this paper's Figure 3/text.** Adenine (4.2) and uracil (9.5) are **not individually pinned to this source** — the paper only states canonical A/C fall in the 3.5–4.5 range and G/T(U) in 9–10 without giving Adenine and Uracil their own single digit in the text found; these are the standard consensus point values consistent with those stated ranges.
- `dV`: no source anywhere gives a volume-of-ionization for any of the four. `A_RNA`/`C_RNA` protonation (`Reaction=basic`) borrows `His`'s real, measured `dV=-1.4` by analogy — both are aromatic heterocyclic ring-nitrogen protonations, chemically comparable to His's imidazole. `G_RNA`/`U_RNA` deprotonation (`Reaction=acidic`, ring lactam N-H, not carboxyl-like) has no clean analog in this file; estimated at `dV=3±3`, same reduced-magnitude-vs-Asp/Glu reasoning used for Sec.
- Both PDFs (Patel & Kishore 1995 for the V0 values; the Krishnamurthy 2012 review for pKa) are saved in this directory.

- **`basic`** groups (His, Lys, Arg side chains; the `-NH2` N-terminus) are neutral at high pH and gain volume on protonation at low pH:

  ```
  V(pH) = V0 + dV / (1 + 10^(pH - pKa))
  ```
- **`acidic`** groups (Asp, Glu side chains; the `-COOH` C-terminus) are  neutral (protonated) at low pH and lose volume on deprotonation at high pH:

  ```LaTeX
  V(pH) = V0 - dV / (1 + 10^(pKa - pH))
  ```
