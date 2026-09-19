# PartialMolarVolumes

Partial molar volume (V0, cm3/mol) data for solutes and solvent, used to build prior on solute excluded volume for the Bayesian SH-coefficient fit.

## General assumptions

- At typical buffer  concentrations (~10-150 mM) a few cm3/mol of V0 error moves the electron density by a fraction of a percent. Exact protonation state, temperature correction, etc. are only worth  chasing for solutes pushed to molar concentration (ex: 6 M urea, 50% w/w glycerol), where V0 error propagates enough to bias the fit. Users must input custum arguments to make it work.
- **Additivity / dilute-limit assumption.** Solution volume is taken as `V(solution) ≈ V0(water) + Σ nᵢ·V0(soluteᵢ)` at infinite dilution. Young's rule / ideal-mixing hold that the rules for low concentrations, and assume zero interactions between solutes.
- **Units**: V0 in cm3/mol, at 298.15 K and ~0.1 MPa unless a source states otherwise. `uncertainty_cm3_per_mol` is the source's own reported standard error, not a subjective error bar; left blank where a source doesn't report one.

## NonBiological/

pH-dependent protonation has to be applied at read time.

### nonbiological.tsv

Columns: `common_name`, `iupac_name`, `formula`, `charge`, `v0_cm3_per_mol`, `uncertainty_cm3_per_mol`, `basis`, `doi`. IUPAC names have not been verified yet.

Caveats worth knowing before trusting specific rows:

- Many rows cite Krumgalz/Pogorelsky/Pitzer `10.1063/1.555981` or Millero `10.1021/cr60270a001` which are compilations. Where they disagree, one was picked arbitrarily.
- `KH2PO4`/`K2HPO4`/`K3PO4`/`Na3PO4`/`NaH2PO4`/`LiH2PO4`/`Na2HPO4` (DOI `10.1016/j.jct.2013.01.012`) were back-calculated from raw density data via Masson-equation extrapolation (`Vφ = V0 + Sv·√m`), since the source only reports density/sound velocity. `Na2HPO4` has high standard deviation (jackknife SE ≈ 8.4, more than half the value), so treat it as low-confidence.
- `trisodium citrate` has two independent, disagreeing sources: 57.1 (`10.1016/j.molliq.2004.07.014`) vs. Apelblat & Manzurola's 69.32 (`10.1016/0378-3812(90)85049-G`). Cross-checks (agreement with an independent `disodium hydrogen citrate` measurement, and Apelblat's dissociation-step volume changes) favor 69.32.
- All rows added for the RNA/DNA/nucleotide literature pass (nucleobases through guanine, below) were briefly written with the wrong 7-column schema (Protein's, missing `formula`/`charge`) before being caught by a column-count audit and rewritten correctly — mentioned here only so a future `git blame` oddity on this range doesn't look mysterious.

### nonbiological.json

`iupac_name -> [electron_count, v0_cm3_per_mol, uncertainty_cm3_per_mol]`. `electron_count` (sum of atomic numbers − charge). Where multiple source rows share one `iupac_name`, `basis=measured` is taken over`derived`/`predicted`; ties are broken by lower `uncertainty_cm3_per_mol`; finally if nothing breaks tie they are picked arbitrarily.

### iupac_to_common.json / common_to_iupac.json

`iupac_to_common.json` is `iupac_name -> [common_name, ...]`.

## Protein

### Protein.tsv

Columns: `Group`, `Name`, `Temperature_C`, `Uncertainty`, `V0`, `basis`, `doi`. `doi`/`basis` were added as per-row columns (previously one fixed source, `10.1039/9781782627043-00542`, for the whole file) to accommodate `Sec`/`Pyl` below, which are `derived` rather than `measured`.

### ionization.tsv

Columns: `Group`, `Name`, `Reaction`, `Temperature_C`, `pKa`, `pKa_Uncertainty`, `dV` (cm³/mol), `dV_Uncertainty`, `dKS` (adiabatic compressibility change, ×10⁻⁴ cm³ mol⁻¹ bar⁻¹), `dKS_Uncertainty`, `basis`, `doi`.

Source for all rows except `Sec`: Lee, Tikhomirova, Shalvardjian & Chalikian, *Biophys. Chem.*, 2008, 134, 185–199 (DOI `10.1016/j.bpc.2008.02.009`). `doi`/`basis` were added as per-row columns (rather than one fixed source for the whole file) specifically to accommodate `Sec`, which comes from elsewhere.

**`R-basic`'s `dV_Uncertainty` in `Protein.json`** (`0.1`) is a manually-inserted standard placeholder, not a value reported by Lee et al. since they left it blank.

**`Sec` (selenocysteine)**, row `basis=derived` (mixed-provenance row), `doi` = Huber & Criddle:

- `pKa` = 5.24, a real titration measurement (Huber & Criddle, *Arch. Biochem. Biophys.*, 1967, 122, 164–173, DOI `10.1016/0003-9861(67)90136-1`). A frequently-cited companion number, pKa=5.47 (Byun & Kang, *Biopolymers*, 2011, 95, 345–353, DOI `10.1002/bip.21581`), is a **computational** DFT/implicit-solvation prediction, not a measurement.
- `dV` = 4 ± 4 cm³/mol is **not from either of those papers**  and is our own estimate: buffer-ionization ΔV° values for large, "soft" ionizing groups (MOPS/HEPES/Tris-type, sulfonate/amine) run ~5-7 cm³/mol, versus ~12 cm³/mol for Asp/Glu's compact, charge-dense carboxylate. Se⁻ is larger and more polarizable than any of those, so the central estimate sits below that 5-7 range; the ±4 uncertainty is wide enough to admit the true value could be near zero, since the sign itself isn't fully certain for an anion this soft.

**`basic`** groups (His, Lys, Arg side chains; the `-NH2` N-terminus) are neutral at high pH and gain volume on protonation at low pH:

```
V(pH) = V0 + dV / (1 + 10^(pH - pKa))
```

**`acidic`** groups (Asp, Glu side chains; the `-COOH` C-terminus) are  neutral (protonated) at low pH and lose volume on deprotonation at high pH:

```LaTeX
V(pH) = V0 - dV / (1 + 10^(pKa - pH))
```

## RNA / DNA

`V0(residue) = V0(free nucleoside) + V0(phosphate group increment)`. The phosphate increment (17.7 cm³/mol) is estimated from the *only* base with both a measured free-nucleoside and free-nucleotide value in one internally-consistent source (Kishore & Ahluwalia 1990, `10.1007/BF00650644`): AMP·Na (189.1) − adenosine (171.4) = 17.7 cm³/mol. (Kishore 1990's own adenosine value is itself a secondhand reproduction of Kishore, Bhat & Ahluwalia, *Biophys. Chem.* 33 (1989) 227–236. The AMP/adenosine pair is the basis for the whole per-letter table  extrapolation  for the phosphate-group increments,  applied uniformly to G/C/U/T's nucleoside values under a base-independenceassumption.

### Ionization

- `ionization.tsv` (duplicated in both `RNA/` and `DNA/` per the phosphate chemistry being shared) has pKa values for adenine/adenosine/guanosine ring protonation-deprotonation equilibria from Christensen, Rytting & Izatt  1970 (`10.1021/bi00827a012` .
- `ionization.json` is populated using the same single physical anchor.
- **ΔV = 2.85 cm³/mol for all eight letters**; Krausz's AMP-only`.
- **pKa is per-base and real**.
- adenine/adenosine/guanosine ring  ionizations are not covered. (pKa exists, from Christensen/Alberty/Lowe, but no ΔV for any of them.
- Phosphate pKa2/ΔV: Krausz, Fitzig & Gabbay, *J. Am. Chem. Soc.* 1972, 94(26), 9194–9197 (dilatometry, 30°C, 0.1 M KCl) reports AMP's phosphate-group deprotonation at pKa≈6.0 with  ΔV=−2.85 mL/mol.
