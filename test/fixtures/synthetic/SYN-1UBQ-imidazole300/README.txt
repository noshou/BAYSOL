SYNTHETIC entry SYN-1UBQ-imidazole300  (no experimental data, no fit)

Host: 1UBQ (protein), file 1UBQ.pdb: the RCSB download (files.rcsb.org/download/1UBQ.pdb); the repository has only the .cif of this entry, so the .pdb download is used.
Atoms as the loader sees them: 602 heavy atoms (waters dropped by the loader).
Edits to the model file: none (the file is the unmodified RCSB download).

1UBQ, human ubiquitin, X-ray, 1.80 Å, 76 residues, 602 heavy atoms, 58 waters (HOH, not
scattered: the loader drops waters), no other hetero group, no alternate location. File:
the RCSB download of 1UBQ in PDB format (the repository only has the mmCIF
test/fixtures/molecules/1UBQ-TEST.cif, whose atom records were not compared). Loaded as a
protein: PROPKA + PARSE hydrogens at the entry pH.

Buffer (INVENTED, flagged synthetic): 300 mM imidazole + 500 mM NaCl pH 8.0, pH 8.0, 25.0 C.
  imidazole: 300.0000 mM (±6.0000)  300 mM imidazole, ±2 %
  sodium chloride: 500.0000 mM (±5.0000)  500 mM NaCl, ±1 %
  chloride: 35.3930 mM (±7.2299)  Cl⁻ of the HCl titration

Assumptions (details in test/synthetic_tests/SYN-1UBQ-imidazole300/SYN-1UBQ-imidazole300.jl):
300 mM imidazole + 500 mM NaCl, pH 8.0 (the elution buffer of a Ni-NTA purification). The
pH is not part of the brief's recipe and is invented: imidazole alone is a weak base of pH
about 10 at this concentration, so it is taken as titrated with HCl to pH 8.0 (HCl for
amine buffers, as in the sibling scripts), and the counter-ion is modelled: Cl⁻ = C·f, f
the protonated (imidazolium) fraction f = 1/(1 + 10^(pH − pK)·γ₁), pK = 6.993 at 25 °C
(Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902,
as quoted in SASDA58 and not re-checked here; its 22 °C value 7.058 with ΔH 36.64 kJ/mol
moves to 6.993 at 25 °C), γ₁ the Davies activity coefficient (A = 0.509) at the
self-consistent ionic strength I = 0.5·(c_Na⁺ + c_Cl⁻ + 2·C·f) = 0.500 + 0.300·f = 0.5354
M, γ₁ = 0.7357:

    f = 0.1180  ->  Cl⁻ = 35.39 mM    (26.88 mM without the Davies correction)

I = 0.54 M is above the range of the Davies equation (about 0.5 M), so f is indicative. σ,
summed in quadrature: σ_pH = 0.1 (6.57 mM), pK ± 0.02 (1.46 mM), 30 % of the Davies shift
(2.56 mM), ±2 % on C (0.71 mM) = 7.23 mM. Rows "imidazole" (36 electrons, ϕ° = 59.95 ± 0.5
cm³/mol, the neutral base), "sodium chloride" and "chloride" (ϕ° = 17.8). The
imidazolium/imidazole volume difference itself is not modelled.

Expected solvent electron density (Python replica of BulkElectronDensity.rho_e with the
table values, to be confirmed by the smoke run, NOT BAYSOL output):
  rho_e = 0.339638 e/A^3, sigma = 0.000092 e/A^3, water at 25 C = 0.333292 e/A^3,
  ratio to water = 1.01904

Outputs of the script (next to it): SYN-1UBQ-imidazole300.profile.tsv (q in 1/A, 0.01..0.5 step 0.005;
I in e^2, CRYSOL3-default shell contrasts 1, 1, 0 x 0.03 e/A^3, c1 = 1, scale 1,
background 0) and SYN-1UBQ-imidazole300.solvent.txt.
Benchmark: Pepsi-SAXS, CRYSOL and FoXS on the raw host PDB with the same solvent density.
