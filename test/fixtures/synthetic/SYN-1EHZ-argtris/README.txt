SYNTHETIC entry SYN-1EHZ-argtris  (no experimental data, no fit)

Host: 1EHZ (rna), file 1EHZ.pdb: the RCSB download (files.rcsb.org/download/1EHZ.pdb); ATOM/HETATM records identical to test/fixtures/molecules/1EHZ-TEST.pdb.
Atoms as the loader sees them: 1661 heavy atoms (waters dropped by the loader).
Edits to the model file: none (the file is the unmodified RCSB download).

1EHZ, yeast tRNA-Phe (Saccharomyces cerevisiae), X-ray, 1.93 Å, 76 nucleotides. The file
has 1329 ATOM records (the standard nucleotides) and, as HETATM, 14 modified residues (11
types: 1MA, 2MG, 5MC, 5MU, 7MG, H2U, M2G, OMC, OMG, PSU, YYG; hydrogenated through their
parent base), 6 Mg2+ and 3 Mn2+ ions and 160 waters; no alternate location. The loader
keeps the modified residues and the 9 ions (ligands, heavy atoms without hydrogens; 1652 +
9 = 1661 heavy atoms, 2481 with hydrogens, as in test_nucleotide_fixtures) and drops the
waters. The ions are scattered although the buffer of the entry has no Mg2+ or Mn2+: that
is part of the structure, not of the buffer. File: the RCSB download of 1EHZ; its
ATOM/HETATM records are identical to the checked-in test/fixtures/molecules/1EHZ-TEST.pdb
(compared line by line, no difference). Loaded as a nucleic acid alone: AMBER hydrogens
through pdb2pqr (83 hydrogens of the modifications are not placed, about 0.7 % of the
electrons; src/hydrogenator/README.md).

Buffer (INVENTED, flagged synthetic): 500 mM L-arginine HCl + 50 mM Tris pH 7.5, pH 7.5, 25.0 C.
  tris: 50.0000 mM (±1.0000)  50 mM Tris, ±2 %
  arginine: 500.0000 mM (±10.0000)  500 mM L-arginine, ±2 %
  chloride: 541.7560 mM (±10.2080)  Cl⁻: 500 Arg-HCl + 41.76 Tris-HCl

Assumptions (details in test/synthetic_tests/SYN-1EHZ-argtris/SYN-1EHZ-argtris.jl):
500 mM L-arginine hydrochloride in 50 mM Tris-HCl pH 7.5 (an aggregation-suppressing
co-solute). Convention of the sibling scripts, not a speciation: Arg-HCl is the arginium
cation (net +1 at this pH: guanidinium +1, the α-NH₃⁺/α-COO⁻ pair neutral) with one
chloride, so it is the table's neutral amino acid row "arginine" (94 electrons, ϕ° =
127.42 ± 0.01 cm³/mol, as in SASDRJ8) plus 500 mM "chloride"; the pH is taken as the
Tris-HCl's 7.5 and the (small) pH shift Arg-HCl would cause is ignored.

Tris-HCl counter-ion: Tris base titrated with HCl to pH 7.5 (the convention of the
siblings for amine buffers), Cl⁻ = C_Tris · f with f the protonated fraction f = 1/(1 +
10^(pH − pK)·γ₁), pK = 8.072 at 25 °C (the 22 °C value 8.156 and ΔH 47.45 kJ/mol of
Goldberg, Kishore & Lennen 2002, J. Phys. Chem. Ref. Data 31, 231, DOI 10.1063/1.1416902,
as quoted in SASDA58 and not re-checked here, moved to 25 °C by van't Hoff), γ₁ the Davies
activity coefficient (A = 0.509) at the self-consistent ionic strength I = 0.5·(c_Arg⁺ +
c_Cl⁻ + 2·C·f) = 0.500 + 0.050·f = 0.5418 M, γ₁ = 0.7361:

    f = 0.8351  ->  Cl⁻(Tris) = 41.76 mM    (39.43 mM without the Davies correction)
    Cl⁻ in all = 500 + 41.76 = 541.76 mM

I = 0.54 M is above the range of the Davies equation (about 0.5 M), so f is indicative.
σ(Cl⁻, Tris part), summed in quadrature: σ_pH = 0.1 (1.71 mM), pK ± 0.02 (0.31 mM), 30 %
of the Davies shift (0.70 mM), ±2 % on C (0.84 mM) = 2.05 mM; with ±2 % on the 500 mM of
Arg-HCl chloride (10 mM) the row's σ is 10.21 mM. At 0.5 M the arginine displaces 6.4 % of
the water; its ϕ° is the value of the neutral amino acid at low concentration, so the
linear-mixing error is the largest term here.

Expected solvent electron density (Python replica of BulkElectronDensity.rho_e with the
table values, to be confirmed by the smoke run, NOT BAYSOL output):
  rho_e = 0.343497 e/A^3, sigma = 0.000570 e/A^3, water at 25 C = 0.333292 e/A^3,
  ratio to water = 1.03062

Outputs of the script (next to it): SYN-1EHZ-argtris.profile.tsv (q in 1/A, 0.01..0.5 step 0.005;
I in e^2, CRYSOL3-default shell contrasts 1, 1, 0 x 0.03 e/A^3, c1 = 1, scale 1,
background 0) and SYN-1EHZ-argtris.solvent.txt.
Benchmark: Pepsi-SAXS, CRYSOL and FoXS on the raw host PDB with the same solvent density.
