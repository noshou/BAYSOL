# BulkElectronDensity

The bulk electron density `ρₑ` of the **buffer**, with its standard uncertainty. The measured macromolecule is never a solute here: buffer subtraction has removed it, and listing it would double count. The module owns the buffer solute types and has one exit point.

## Public API

- `Solute` (abstract) with `NonBiological`, `Polymer`, `Protein`, `DNA`, `RNA`, each carrying `molarity`, `molarity_uncertainty` and an `arg` (a name, a chain description or a sequence). Protein, DNA and RNA solutes are buffer components (a carrier protein, a nuclease), not the measured species.
- `DEFAULT_TEMPERATURE_C` (25 °C) and `ρₑ(pH, σ_pH, solutes; t = DEFAULT_TEMPERATURE_C) -> (ρₑ, σρₑ)` in e·Å⁻³. `Inference.ρₑ_prior` wraps the result in a LogNormal; nothing else of the module is used outside it.

Everything below (the `ϕ°` backends, their tables, the water density `_ρₑ_w`) is internal.

## The Model

### Water and the Kell Density

`CalcDensity.jl` takes the mass density of pure water at 1 atm from Kell (1975), `0 ≤ t ≤ 150 °C` (else `DomainError`):

```math
\rho(t)=\frac{a_0+a_1t+\dots+a_5t^5}{1+bt}\ \mathrm{kg\,m^{-3}},\qquad
\rho_w(t)=\frac{N_A\,Z_{H_2O}}{10^{27}\,v},\quad v=\frac{M_{H_2O}}{\rho}\ \mathrm{L\,mol^{-1}}
```

with `Z_H2O = 10` and `10²⁷ Å³` per litre; `σ_w = ρ_w σ_ρ/ρ` with `σ_ρ = 0.02 kg m⁻³` (≈ 20 ppm). At 25 °C: ρ = 997.045 kg m⁻³, `ρ_w = 0.333292 e·Å⁻³`; water moves by 0.12 % between 25 and 20 °C and 0.29 % at 4 °C, as much as a salt. Memoised per temperature (rounded to 10⁻³ °C).

### Linear Mixing and its Uncertainty

The central assumption is additivity at the dilute limit, `V_solution ≈ V_water + Σ nⱼ ϕ°ⱼ` (the error is the excess volume of mixing, of order 1 cm³ mol⁻¹ at ~0.1 M; at molar concentrations such as 6 M urea or 50 % glycerol it can fail by more and users must supply their own values). In one litre the solutes contribute `N_A Cⱼ Zⱼ` electrons and displace `Σ Cⱼ ϕ°ⱼ/10³` of the water volume:

```math
\rho_e=\rho_w(t)+\sum_j C_j k_j,\qquad k_j=\frac{N_AZ_j}{10^{27}}-\rho_w(t)\frac{\phi^\circ_j}{10^{3}}
```

(`C` in mol L⁻¹, `ϕ°` in cm³ mol⁻¹; the first term of `kⱼ` is what the solute would add if it displaced nothing, the second the electrons removed with the water.) A solute with `Z/ϕ° = 0.553` is electron-density matched to water; NaCl has 1.7, glycerol 0.70, urea 0.72. The model is linear in the molarities, so the delta-method uncertainty is exact to first order for independent inputs:

```math
\sigma_{\rho_e}^2=\Big(1-\sum_j\frac{C_j\phi^\circ_j}{10^3}\Big)^2\sigma_w^2+\sum_jk_j^2\sigma_{C_j}^2+\sum_j\Big(\frac{C_j\rho_w}{10^3}\Big)^2\big(\sigma_{\phi_j}^2+\sigma_{\phi,T,j}^2\big)
```

At buffer concentrations the recipe term (pipetting error) dominates; for a 6 M solute the table term does. Magnitudes at 25 °C: 150 mM NaCl +0.51 %, + 20 mM Tris +0.57 %, 5 % v/v glycerol (0.6846 M) +1.84 %, 6 M urea +8.15 %; an error of 2 cm³ mol⁻¹ in `ϕ°` of 6 M urea moves `ρₑ` by 1.1 %, the same error for a 20 mM buffer by ~10⁻⁴ of that: be careful with molar solutes, do not agonise over millimolar ones. Inputs are validated (`DomainError` for a non-positive molarity or a negative uncertainty, `ArgumentError` for an empty name or sequence).

**Temperature.** The tables are at 25 °C and ~0.1 MPa. The drift of `ϕ°` is not modelled but widened into the uncertainty with a bound on the fractional expansibility, `σ_{φ,T,j} = β|ϕ°ⱼ||t − 25 °C|`, `β = PMV_FRACTIONAL_EXPANSIBILITY = 3·10⁻³ K⁻¹` (derived from the multi-temperature sugar/urea/glycoluril/nucleobase series; some electrolytes exceed it, e.g. NaH2PO4 ≈ 5.3·10⁻³), added in quadrature to the tabulated `σ_φ`. A blank tabulated uncertainty is replaced at lookup by the **mean of every stated uncertainty** in `nonbiological.json` (a missing error bar is not zero; adding rows can shift it slightly).

**What is not claimed.** The recipe is assumed complete: missing acids, bases or counter-ions are not guessed, and our scripts say so (a `BUFFER_OMISSIONS` block and a warning; see the fitting-test README). Common errors (all volumes of one source shifted together) are not modelled. The prior is narrow because the inputs are good (a fraction of a percent); if the real buffer differs more, the data pull `ρₑ` away and the reported z-score shows it. Ion pairing (10 mM Mg²⁺ with ATP, EDTA or phosphate, Ca²⁺ with sulfate) is a known limitation: it needs a speciation step upstream, and no pair rows are stored.

### Proteins and Nucleic Acids

A buffer protein or nucleic acid has `ϕ° = Σ_r (ϕ_bb + ϕ_r(pH))` and `Z = Z_water + Σ_r (Z_bb + Z_r)`: a shared peptide-backbone unit (`BACKBONE_PMV = (37.4, 0.1)` cm³ mol⁻¹, `BACKBONE_ELECTRONS = 30`) plus a side-chain increment relative to glycine; one water's worth of electrons (10) is added once per chain; placeholders (`X`, `*`) are skipped, variances add. Ambiguity codes average their members (B = ½(D+N), J = ½(L+I), Z = ½(E+Q); the eleven IUPAC nucleotide codes), with variance `Σσᵢ²/N²`. An ionizable residue's volume follows its protonated (basic) or deprotonated (acidic) fraction, from the Henderson–Hasselbalch rule:

```math
V_{basic}=V_0+\Delta V\,f,\ \ f=\frac1{1+10^{\,pH-pK_a}};\qquad
V_{acidic}=V_0-\Delta V\,f,\ \ f=\frac1{1+10^{\,pK_a-pH}}
```

(basic: His, Lys, Arg, the amine terminus; acidic: Asp, Glu, the carboxyl terminus; `(pKa, ΔV)` from Lee et al. 2008, 10.1016/j.bpc.2008.02.009; a bare proton carries no electron, so `Z` is unchanged). With `σ_pH`:

```math
\sigma_V^2=\sigma_{V_0}^2+(f\,\sigma_{\Delta V})^2+\big(\Delta V\ln 10\,f(1-f)\,\sigma_{pH}\big)^2
```

largest at `pH = pKa` and falling like `10^{−|pH−pKa|}`. Results are memoised per `(sequence, pH, σ_pH)`.

For DNA/RNA, `ϕ°(residue) = ϕ°(nucleoside) + 17.7 cm³ mol⁻¹` (AMP·Na 189.1 minus adenosine 171.4, the only base with both measured in one consistent source, Kishore & Ahluwalia 1990, 10.1007/BF00650644, applied to all bases under a base-independence assumption), with one `ΔV = 2.85 cm³ mol⁻¹` for the phosphate deprotonation (Krausz, Fitzig & Gabbay 1972, AMP, `pKa ≈ 6.0`) and per-base `pKa`s (Christensen, Rytting & Izatt 1970, 10.1021/bi00827a012). Ring ionizations have a `pKa` but no `ΔV`. Nucleotides are taken as supplied: no pH-dependent protonation beyond this table.

## Data Layout

Each solute class keeps its code and data together:


| Folder           | Code                                                     | Data                                                                    |
| ------------------ | ---------------------------------------------------------- | ------------------------------------------------------------------------- |
| `NonBiological/` | `NonBiological.jl`: `ϕ°(name)`, alias resolution       | `nonbiological.{tsv,json}`, `nonbio_lookup.json`, `ion_scale_shift.tsv`  |
| `Nucleotide/`    | `Nucleotide.jl`: `ϕ°` of a DNA/RNA sequence            | `DNA/`, `RNA/`, each `dna`/`rna.{tsv,json}` and `ionization.{tsv,json}` |
| `Protein/`       | `Protein.jl`: `ϕ°(pH, seq)`                            | `protein.{tsv,json}`, `ionization.{tsv,json}`                           |
| `Polymers/`      | `Polymers.jl`: group-contribution families, fixed grades | `polymers.{tsv,json}`, `polymers_lookup.json`                           |

`BulkElectronDensity.jl` holds the solute types, the constants (`PMV_REFERENCE_TEMPERATURE_C`, `PMV_FRACTIONAL_EXPANSIBILITY`, `BACKBONE_*`), the water density and the generic `ϕ°`, and includes these in dependency order; `Titration.jl` the helpers `Protein.jl` and `Nucleotide.jl` share; `CalcDensity.jl` combines everything into `ρₑ`.

### NonBiological

The **TSV is the provenance, the JSON the selection.** `nonbiological.tsv` has every literature row (`common_name`, `iupac_name`, formula, charge, `v0_cm3_per_mol`, `uncertainty_cm3_per_mol`, `basis`, doi); `nonbiological.json` maps `iupac_name` (lowercase) to `[electron_count, v0, uncertainty]`, `electron_count = Σ Z − charge`. Values are 25 °C, aqueous, anhydrous basis (hydration water and counter-ions such as HCl are bulk solvent); uncertainties are the source's own standard error.

**Selection rule** (a unit test, `test_pmvtables.jl`, checks every JSON value equals one tied TSV row): rank by `basis`, drop `rejected`, take the lowest stated uncertainty (blank ranks last), ties keep the previous pick. Basis labels, best first:

- `measured`: reported by a source for this solute. `derived`: computed here from a paper's own density or apparent-molar-volume data (Masson `Vφ = V₀ + S_v√m` or a linear fit; uncertainty the fit's standard error, or the larger of it and the √m-vs-linear intercept difference).
- `predicted`: group-contribution or analogy. `estimated`: 3D-RISM (AmberTools, cSPC/E, KH closure), used only through *differences* between species of the same charge state anchored on a measured analogue, since absolute 3D-RISM volumes of anions are erratic (+13 to −22 cm³ mol⁻¹ against measurement); each charge state is corrected group by group with a model fitted to 72 measured solutes (leave-one-out RMS 3.5). Never label an estimate measured, and do not estimate what a paper reports.
- `obigt-unverified` (461 OBIGT species, lowest), `other-T` (valid, but another temperature), `unverified-T` (medium or temperature not recorded; values disagree with 25 °C water sources), `cited-unverified` (quoted from a source not read), `rejected` (known wrong, never selected; the reason is in the row history).

When no measurement exists, the fallback regression is `ϕ° = 1.466 V_vdW − 2.881(N_HBD + N_HBA) + 9.352` (`V_vdW` from an RDKit conformer in cm³ mol⁻¹, fitted to 50 measured neutral solutes; leave-one-out RMSE 3.3, slight underestimate at large size, so quote ±4 %). Never quote an uncertainty tighter than the validation error of the method that produced the number.

**Dissociation and the ion scale.** Strong electrolytes are stored as dissociated ions, weak acids and bases as individual protonation forms (molarities follow from the pH), no ion pairs (OBIGT's neutral NaCl, KCl, CaSO4 are pairs ≈ 11.7 cm³ mol⁻¹ above the dissociated salts and must not be mixed in). A single ion's volume is not measurable alone, so the tables use the **conventional scale `V(H⁺) = 0`**, each ion following from additivity of measured salt volumes. The absolute scale differs by `V_abs = V_conv + z·V_abs(H⁺)`, `V_abs(H⁺) = −5.41 cm³ mol⁻¹` at 25 °C, so a source on the absolute scale (TATB, Ph₄As⁺/BPh₄⁻, "single-ion", `V(H⁺) ≈ −5.4`) is converted by `V_conv = V_abs + 5.41 z` (cations up, anions down; 77 rows were converted, recorded in `ion_scale_shift.tsv` with evidence and confidence; nothing reads that file). **To check a new ion row:** `V(salt) − Σνᵢ V(ionᵢ)` should be within ≈ ±1; a residual of ±5.4 per charge flags the wrong scale (Na⁺ −1.21 + Cl⁻ 17.83 = 16.62 against 16.61 for NaCl). Never add an absolute-scale ion without the shift.

**Names.** Every common, trade, older or abbreviated name is an alias of one **preferred IUPAC name**, non-stereospecific (no R/S, E/Z, D/L, cis/trans, α/β unless the isomers' volumes differ by more than 1 cm³ mol⁻¹ with grade A/B evidence on both sides; maleate/fumarate and distinct diastereomers such as hexitols stay separate), in the flat `nonbio_lookup.json` (lowercase alias → target; one block per target, the self-mapping first, aliases sorted). The resolver decides (OPSIN, PubChem, RDKit); names no tool parses (NAD family, polymers, many sugars) stay and are marked unverified. Every alias met anywhere must be added there, **never as its own JSON key**; `ϕ°(name)` lowercases and resolves through the lookup first. An unknown name raises `ArgumentError("unknown solute")`.

**Adding a solute.** (1) Find a value: a measured 25 °C `V₀` (subtract `n·18.07` for an n-hydrate), else estimate and validate on molecules whose answer you know. (2) Pick the IUPAC name, a `common_name` and the aliases people write; check for collisions. (3) Add the TSV row. (4) Add the JSON entry with a lowercase key and `electron_count`. (5) Add the aliases to `nonbio_lookup.json`. (6) Check that every JSON value equals a non-rejected tied TSV row, keys are lowercase and alias targets exist; then add the solute to the fixture's `SOLUTES`. Changing a fixture's `SOLUTES` changes its `ρₑ` prior, so its stored run log, workbook and figures are stale until it is re-run.

**Open data doubts** (history of every pick is in git and `~/pmv_work`): PMSF (127.2 ± 5.0) is our own geometric estimate, never a measurement; every aliphatic thiol (including 2-mercaptoethanol and the Schulte & Rogers series) rests on one unverified assumption (the cysteine−serine difference 12.87 as the SH−OH increment); nitrite and thiocyanate are still flagged; spermidine/spermine are probably on the absolute scale (unshifted); the GTP (290 ± 22) and GDPNP (288.8 ± 22) rows disagree by 60–70 with the ATP-based chain; 3D-RISM cations of guanidinium/amidinium groups come out above their neutral forms and were not added; tetrabutylammonium iodide 312.4 vs 298.65, calcium diacetate 72.32 vs 56.74/62.79 and compiled ion volumes of Krumgalz vs Millero remain unresolved (Millero's nitrate, perchlorate, thiocyanate, carbonate, sulfate and Cd/Co/Ni/Zn/Pb offsets are not multiples of 5.41 z, so they are old-data disagreement, not scale). A consistent single-source policy for ions matters more than any single pick. Tris convention: "Tris-HCl" is Tris plus HCl as separate solutes; chelates (NTA, DTPA complexes) are stored as fixed species, so a buffer must name the one it contains.

### Protein

`protein.tsv` (Group, Name, `Temperature_C`, Uncertainty, V0, basis, doi) and `ionization.tsv` (Group, Name, Reaction, `Temperature_C`, pKa, `pKa_Uncertainty`, dV, `dV_Uncertainty`, dKS, `dKS_Uncertainty`, basis, doi); source Lee et al. 2008 for all rows except Sec. R-basic's `dV_Uncertainty` (0.1) is a placeholder, not reported by Lee et al. **Sec** (selenocysteine, basis `derived`): `pKa = 5.24` (Huber & Criddle 1967, 10.1016/0003-9861(67)90136-1, a titration; 5.47 from Byun & Kang 2011 is a DFT prediction) and `dV = 4 ± 4` our own estimate by analogy with large soft ionizing groups (MOPS/HEPES/Tris-type ~5–7 cm³ mol⁻¹, against ~12 for Asp/Glu).

### Polymers

`Polymer(molarity, σ, arg)` is its own solute type (`NonBiological("PEG-3350")` is an error): polymers, polydisperse surfactants and short oligomers, whose `ϕ°` and `Z` scale with the chain. `arg` is a grade name or a chain description; the volume comes from a group-contribution family where one exists (`Polymers.jl`) and from `polymers.json` through `polymers_lookup.json` otherwise (a name a family recognises uses the family; a grade whose row states no uncertainty gets 2 % of `ϕ°`; molarity is per mole of chains, except dextran, amphipol, PVP, PVA (per average monomer unit) and Ficoll (per 1000 Da, 540 electrons per 1000 Da is our estimate)). With `m` the number of monomer units:


| Input                                                | ϕ° (cm³ mol⁻¹)                                                                                            | Z                         | Basis                                                                                                    |
| ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------- | --------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `PEG-400`, `PEG 3350` (Mn) or `PEG n=22`             | `19.24 + 36.73 m`, σ 1 %                                                                                      | `24m + 10`                | ten PEGs 200–10 000 (Ayranci & Sahin 2008) and di- to pentaethylene glycol; `m = (Mn − 18.015)/44.053` |
| `Pluronic nEO=150 nPO=30`                            | `36.92 nEO + 53.13 nPO + 9`, σ 1 % + 8                                                                        | `24nEO + 32nPO + 10`      | Senkow 2002 (10.1039/b204404h); totals over both PEO blocks                                              |
| `PPG-2000`, `PPG n=10`                               | `18.10 + 53.20 m`, σ 1 %                                                                                      | `32m + 10`                | di- to pentapropylene glycol                                                                             |
| `UCON 3930` (Mn)                                     | `86.6 + 36.92 nEO + 53.13 nPO`, σ 1 % + 3                                                                     | `24nEO + 32nPO + 42`      | 1-butanol starter plus the Pluronic increments; random sequence assumed to add like blocks               |
| `dextran 40` (< 1000 means kDa), `dextran n=250`     | `16.6 + 102.2 m`, σ 2 %                                                                                       | `86m + 10`                | measured, 0.630 mL/g × 162.14 (Migliorini 2026)                                                         |
| `pullulan 100000`, `glucan n=250`                    | `16.6 + 96.7 m`, σ 4 %                                                                                        | `86m + 10`                | glucose to maltoheptaose (0.60 mL/g)                                                                     |
| `cyclodextrin n=7`                                   | `100.7 n`, σ 1 %                                                                                              | `86n`                     | α, β, γ                                                                                               |
| `Triton nEO=9.5`                                     | `239.7 + 36.92 n`, σ 2 %                                                                                      | `114 + 24n`               | Triton X-114 micelle (Szymczyk & Taraba 2016)                                                            |
| `C12E23`, `Brij nC=12 nEO=23`                        | `22.38 + 15.93 nC + 36.92 nEO`, σ 2 %                                                                         | `8nC + 24nEO + 10`        | 2-methoxy-/ethoxy-/butoxyethanol and the EO increment                                                    |
| `maltoside nC=10`, `LMNG nC=10`                      | `214.0 + 15.93 nC`; `464.3 + 31.86 nC`                                                                         | `8nC + 182`; `16nC + 386` | 3D-RISM with fitted corrections; **monomer**, not micellar                                               |
| `peptide GAG`, `tetraalanine` (two or more residues) | the protein scheme plus terminus titration (COOH pKa 3.3, +10.5; NH₂ pKa 8.0, +4.8; σ + 2 for ≤ 8 residues) | protein scheme            | reproduces Gly₃–Gly₅ to 0.1                                                                           |

(Electron counts: ethylene-oxide unit C₂H₄O 2·6+4+8 = 24, PPG unit 32, glucose residue C₆H₁₀O₅ 86, plus 10 for the end groups.) Fixed grades in `polymers.json`: measured PEG and Pluronic grades, Tween 20/80, Brij 35/58, NP-40, Triton X-100, amphipol A8-35 (100.3 per monomer), the detergent monomers (decyl and dodecyl maltoside, LMNG, digitonin, DPC; `estimated`), dextran, PVP (89.4 ± 0.6), PVA (33.2 ± 0.5), Ficoll 400 (680 ± 10 per 1000 Da) and Ficoll 70 (`cited-unverified`), 36 peptides, the cyclodextrins, maltotriose to maltodecaose, and di- to penta-ethylene/propylene glycol. Single amino acids, ethylene glycol, propylene glycol, glucose and maltose stay in `NonBiological/`. Tests check each family reproduces the rows it was fitted to.

## Constants

Module level in `BulkElectronDensity.jl`: `PMV_REFERENCE_TEMPERATURE_C` (25.0), `PMV_FRACTIONAL_EXPANSIBILITY` (3.0 × 10⁻³ K⁻¹), `BACKBONE_PMV`, `BACKBONE_ELECTRONS`. `Inference` imports the first two.
