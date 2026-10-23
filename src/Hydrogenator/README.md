# Hydrogenator

## Overview

Hydrogenator turns a heavy-atom .pdb into one with explicit hydrogens, through two external command-line tools run as subprocesses in a CondaPkg-managed Python environment: pdb2pqr (hydrogen placement) and propka3 (per-residue pKa prediction). It works on files, by path, in the `_cache/` store of `MolecularStructure`; `BAYSOL.seed_model` calls it between `resolve_structure` and `load_molecule`.

Two choices are the caller's: the **force field** (`ff`, among `FORCE_FIELDS`) and the **titration method** (`titration`: `Propka()` or `NoTitration()`). `seed_model` chooses both from what the structure contains: PARSE for protein-only and mixed structures, AMBER (`NUCLEIC_FORCE_FIELD`) for a nucleic acid alone, and the titration (see "Choosing the hydrogenation" below): `Propka` for proteins and mixed files, none for a nucleic acid alone.

## Module components

- Hydrogenator.jl: the module, the shared types (`TitrationMethod`, `Propka`, `NoTitration`), `FORCE_FIELDS` and the CondaPkg tool paths.
- Propka.jl: propka3 and its `.pka` parser (`propka_pKas`, cached as `<stem>.pka`), and the Henderson-Hasselbalch terminus rule the pKas feed.
- Pdb2pqr.jl: `resolve_hydrogens`, the pdb2pqr run, the per-chain partition and the cache.
- Content.jl: `hydrogenation_choice` (titration from the residue content), the guard against dropped nucleotides and `modified_hydrogen_deficit` (a diagnostic).
- Modified.jl: `relabel_modified` and `restore_modified!`, the hydrogenation of modified and legacy-named nucleotides through the standard residue of their base.
- ChainEnds.jl: `isolate_chain_ends` and `restore_chain_ends!`. pdb2pqr patches the 5' end of a nucleic chain only if its first residue is nucleic and the 3' end only if its last is, and a lone patch aborts its charge check; the leading and trailing non-nucleotide residues (a 5' GTP, the aminoacyl MET of a tRNA) therefore run under chain ids of their own and get their own back, and the `OXT`/`HXT` pdb2pqr adds to an isolated aminoacyl residue are removed.

## PROPKA (`propka_pKas`, in Propka.jl)

Inside a folded protein a titratable side chain's pKa is shifted from its textbook value by burial, hydrogen bonding and nearby charges; PROPKA predicts that shift.

```julia
using BAYSOL.Hydrogenator: propka_pKas, PropkaError

records = propka_pKas(pdb_path)
# Vector{<:NamedTuple}, one per standard titratable group:
# (resname::String, resnum::Int, chain::String, pKa::Float64)
```

## pdb2pqr (`resolve_hydrogens`, in Pdb2pqr.jl)

A structure from the RCSB or a crystallographic .cif/.pdb typically carries heavy atoms only, but the forward model needs the hydrogens, and which hydrogens a titratable group carries depends on its protonation state at the solution pH (a free amine's three vs. two, a carboxylate's "HO"). Pdb2pqr.jl runs pdb2pqr to add hydrogens consistent with the pH and force field.

```julia
using BAYSOL.Hydrogenator: resolve_hydrogens, propka_pKas, Propka, NoTitration

# proteins: PARSE force field (the default), PROPKA titration, which is asked for
hpath = resolve_hydrogens(pdb_path, pH; titration = Propka())
# the pKas of a structure already predicted can be passed along
hpath = resolve_hydrogens(pdb_path, pH; titration = Propka(propka_pKas(pdb_path)))
# nucleic acids alone: no pH model, so no PROPKA run (seed_model uses AMBER for them)
hpath = resolve_hydrogens(pdb_path, pH; titration = NoTitration())
```

`resolve_hydrogens(pdb_path, pH; ff, titration)` runs `pdb2pqr --ff <FF>` on the heavy-atom .pdb at `pdb_path` and returns the path to a hydrogen-included .pdb stored in `MolecularStructure._store_dir()` under `"<stem>_pH<pH>_<ff>_<method>.pdb"`. A repeat call for the same four is a cache hit and not re-run.

- `ff` is one of `FORCE_FIELDS` (`:amber, :charmm, :parse, :peoepb, :swanson, :tyl06`; default `DEFAULT_FORCE_FIELD` = `:parse`); an unknown one raises `Pdb2pqrError`. `seed_model` uses PARSE, or AMBER for a nucleic acid alone (see "Choosing the hydrogenation").
- `titration` is a `TitrationMethod`, `NoTitration()` by default: nothing implies PROPKA. `Propka()` adds `--titration-state-method propka --with-ph <pH>` and the per-chain terminus rule below; `Propka(pKas)` takes the records of [`propka_pKas`](@ref BAYSOL.Hydrogenator.propka_pKas) produced **on this same structure** (assumed, not re-verified) instead of predicting them. PROPKA has no nucleotide model, so `Propka` is protein-only (see CLAUDE.md, "Nucleotide support").

## Choosing the hydrogenation (`hydrogenation_choice`, in Content.jl)

`BAYSOL.seed_model` looks at the residues of the structure, through the component records of [`MolecularStructure.component`](@ref BAYSOL.MolecularStructure.component) (the `classify` stage of the timing log), and chooses the titration and the force field:

| structure content   | `content`  | force field | titration       | stages                              |
| :------------------ | :--------- | :---------- | :-------------- | :---------------------------------- |
| amino acids only    | `:protein` | PARSE       | `Propka(pKas)`  | `propka`, `pdb2pqr`                 |
| DNA/RNA only        | `:nucleic` | AMBER       | `NoTitration()` | `pdb2pqr (nucleic, none)`           |
| protein and DNA/RNA | `:mixed`   | PARSE       | `Propka(pKas)`  | `propka`, `pdb2pqr (mixed, propka)` |

pdb2pqr's `--pdb-output`, the only output BAYSOL reads, places the same hydrogens under PARSE and AMBER (same atoms, coordinates identical to 0.000 A on 1BNA, 3HDD and 1CRN; the "zero atoms for DNA" of PARSE holds for the PQR output only), so the choice is about robustness. Anything with protein keeps PARSE, because the terminus flags `--neutraln/--neutralc` that follow from PROPKA exist only with PARSE (AMBER exits with an error). A nucleic acid alone has no such flags and gets AMBER (`NUCLEIC_FORCE_FIELD`) because PARSE is not one-to-one on chimeras such as 246D (an RNA with one deoxy-C, where its charge check aborts the run); 20 nucleic fixtures run through both gave identical atom counts on 15 of them, and AMBER succeeded where PARSE aborted on 246D. NP7 and WJ4 fail under both (chain-end and fragment reasons, below).

The protein route is the one of before and its hydrogens do not change. The hydrogens of nucleic acids do not depend on pH (identical at pH 1, 7 and 13) and PROPKA has no model for the bases or the phosphates, so a nucleic acid alone runs no PROPKA; in a mixed file the protein stays pH driven. The cache file name carries the force field and the method (`<stem>_pH<pH>_<ff>_<method>.pdb`).

The choice reads the residue names from the file's ATOM and HETATM records by a text scan, without parsing the structure, so a file BioStructures' strict parser rejects still works. If the names are unknown to the dictionary but a residue carries at least four of the sugar-phosphate atoms (`P O5' C5' C4' O4' C3' C2' C1'`), it is taken as a nucleotide (the `classify` note says so). After every pdb2pqr run a text scan checks that every nucleotide residue of the input has atoms in the output, and raises `Pdb2pqrError` naming the residues otherwise.

### Legacy residue names

Older and CHARMM files name the bases `ADE`, `GUA`, `CYT`, `URI`, `THY` (`LEGACY_NUCLEOTIDE_NAMES` in MolecularStructure.jl; `DAD DCY DGU DTH` are not included, the dictionary has them as D-amino acids and a sugar). The wwPDB uses these ids for the **free bases** (ligands), so `component("ADE")` stays `:other`: the rule needs the atoms. A residue under one of these names is a nucleotide when it has a `P` atom, or at least four of the eight backbone atoms **and** its chain has at least two such residues (a free adenine or adenosine ligand, a lone residue and ATP/GTP/NAD, whose ids are not in the list, are not nucleotides). `THY` is DNA, `URI` is RNA, `ADE GUA CYT` are RNA when the residue has an `O2'` (or `O2*`) atom, else DNA; the base is the mapped letter. The rule applies to the content scan (`classify` says how many such residues it recognised), the guard, the loader (HETATM residues that satisfy it are kept too) and the hydrogenation, where they are run as the canonical standard names like the modified bases below (measured on relabelled 1SDR and 1BNA residues: pdb2pqr exits with an error on `ADE` and `URI` in a ribonucleotide chain, and places no hydrogen on `CYT`, `GUA` or `THY`) and get their names back.

### Plain letters: DNA written as RNA

A residue named `A`, `C`, `G` or `U` is RNA in the dictionary and pdb2pqr (PARSE or AMBER) treats it as RNA: a deoxy DNA written with the bare letters `A C G T` (SASDAN8) gets an `O2'` oxygen added to every `A C G` and no hydrogen on the `T`. So, in the temporary copy of the pdb2pqr run, a residue named `A C G U` that has **no** `O2'` (or `O2*`) atom is relabelled `DA DC DG DT` (`U` without `O2'` becomes `DT`, as for a DNA-class U below), and every residue named `T` becomes `DT`; the names are restored afterwards. The decision is per residue, on its own atoms, so a chain that mixes both (a DNA residue inside an RNA, as in 246D) is relabelled residue by residue; the cost is that an RNA residue whose `O2'` is simply missing from the model is taken for DNA. Residues with `O2'` keep their RNA names. The `classify` note says how many were relabelled (`N plain-letter DNA residues relabelled`). On SASDAN8: no `O2'` added, 2044 atoms plus 1111 hydrogens, hydrogens on the thymines.

### Modified amino acids

Whatever the route (protein only, mixed, nucleic acid with a modified peptide), the loader keeps the HETATM residues that are amino acids (`MSE`, `SEP`, `TPO`, `PTR`, ...) and the hydrogenation runs them through their standard parent, exactly as for the modified nucleotides: in the temporary copy of the pdb2pqr input a modified amino acid with a known parent (`MSE` is `MET`, `SEP` is `SER`; `amino_parent`) is named after the parent with the record type ATOM, and afterwards the output gets its own name and record type back (ATOM-record `MSE` lines are handled the same way; the twenty standard names written as HETATM, as in SASDB48, are left to pdb2pqr as before). Heavy atoms that pdb2pqr drops because they exist only in the modification (the phosphate of `SEP`, `TPO`, `PTR`) are put back verbatim by the heavy-atom balance (Balance.jl). Atoms the parent has under another name run as the parent's and get theirs back: the selenium of `MSE` runs as `SD` and returns as `SE` with its own coordinates and element (without this pdb2pqr drops it and builds a sulfur 2.4 A away); see `AMINO_ATOM_ALIASES`. The stage `modified amino acid hydrogens` of the timing log reports `[N residues: N hydrogenated through their parent, M without a parent; X hydrogens placed]`; the hydrogens are those of the standard parent, so those that exist only in the modification (a phosphate's, a methyl's) are not placed: an approximation, as for the nucleotides.

Decisions, with evidence:

- **D amino acids** are not run as their L parent: pdb2pqr places the hydrogens from the L form's internal coordinates, and a mirrored alanine run as `ALA` got its `HA` 0.58 A from its `CB` (2.05 A in the L residue). A D residue keeps its heavy atoms and gets no hydrogens (counted as without a parent); pdb2pqr leaves unknown residues alone, so hydrogens already in the file stay. Only 15 D components have a declared parent, most have none.
- **Terminal variants** (`... amino terminus`, `... carboxy terminus`) are run as their parent like any other: a tyrosine renamed `TYC` gave the same atoms and hydrogens as the unmodified structure.
- **Incomplete residues**: a modified amino acid is run as its parent only if it has every heavy atom of the parent (`STANDARD_AMINO_ATOMS`; the selenium of `MSE` counts as `SD`), because pdb2pqr invents the heavy atoms a residue lacks: homoserine (`HSE`, 32 residues written as ATOM records in SASDR99) run as `SER` would get an `OG` of its own and lose the hydrogens of its input. Such a residue keeps its atoms, and the hydrogens of the input if any, and counts as without a parent. This also keeps the SASDR99 baseline unchanged.
- **A parent that is itself non-standard** is followed up the table to a standard amino acid; if the chain does not end in one, or the dictionary lists several different parents, the residue has none and keeps its heavy atoms without hydrogens.
- **`UNK`** and every unknown or non-peptide HETATM residue (ligands, saccharides) stays dropped by the loader.
- Evidence: SASDH39 gains its 160 selenomethionine atoms and 183 hydrogens; a synthetic RNase A with one `MET` renamed `MSE` (`SD` to `SE`, HETATM or ATOM) gives the same atoms and hydrogens as the original; crystal structures with `MSE` (1A62), `SEP` (1VRV) and `PTR` (1AYB) build on the protein-only route. PROPKA reads the raw file and does not choke on them; it now sees the modified residues, which moves some pKas by a few tenths and, on a structure whose N-terminal residue is `MSE`, the N-terminus pKa (6.01 against 7.34 when the residue is removed), but the terminus flags at the pH of the fit were identical on all three.

### Modified nucleotides

pdb2pqr only knows the standard residues. A **modified** nucleotide (any nucleotide id that is not a standard base nor an Amber name: HETATM records such as `PSU`, `5MC`, `1MA`, `2MG`, `H2U`, `7MG`) is therefore **hydrogenated through its base**: before the pdb2pqr run a temporary copy of the input relabels each such residue with a known base to the standard residue of that base (`relabel_modified`; RNA `A C G U`, DNA `DA DC DG DT`) and record type ATOM, and afterwards the output gets the original residue names and record types back (`restore_modified!`, matching chain, number and insertion code; pdb2pqr keeps them, and a blank chain id comes back named by pdb2pqr, then the match is on the number). The base is the declared parent of the component, else the inferred base of the table (`base`, `base_source`). Awkward cases, measured: an RNA component with base T is run as `U`; a DNA component with base U is run as `DT` (pdb2pqr accepts `DU` but places no hydrogen on it).

On 1EHZ (tRNA-Phe) all 14 modified residues (11 types) have a base: no heavy atom is lost (323 of 323) and 149 hydrogens are placed (2MG 11, H2U 10 and 10, M2G 11, OMC 11, OMG 11, YYG 11, PSU 10 and 10, 5MC 11 and 11, 7MG 11, 5MU 10, 1MA 11), against 0 when the residues were left alone (672 hydrogens in the file before, 821 now). **This is an approximation**: the hydrogens placed are those of the standard residue, so the ones that exist only in the modification (a methyl's, for instance) are not placed (the formulas of the 14 components carry 232 hydrogens), and a residue whose component has no known base is left as it is, without hydrogens. `modified_hydrogen_deficit(path, infos)` reports both, and `seed_model` writes them as the note of the `modified nucleotide hydrogens` stage (`[14 residues: 14 hydrogenated through their base, 0 without a base; 149 hydrogens placed, 232 in the free components' formulas]`; the formula figure is the free monomer, an upper bound).

### Heavy atoms pdb2pqr drops or adds (Balance.jl)

pdb2pqr's `5TERM` patch deletes the `P`, `OP1` and `OP2` of the first nucleotide of every chain (1EHZ residue A1 loses its phosphorus: 1652 to 1651 heavy atoms) and gives its `O5'` an `H5T`. After each run `restore_dropped_atoms!` compares the heavy atoms of the input with the output, residue by residue, and re-attaches every heavy atom of the input that has neither an output atom of the same name nor one within 0.01 A in its residue and no *new* output atom within 3 A to pair with (pdb2pqr renames some atoms, such as the carboxylate `OC1`/`OC2` that become `O`/`OXT`, and its flips of HIS, ASN and GLN move others: none of these is a loss), with the input's coordinates, occupancy, B-factor and element. A restored phosphorus removes the `H5T` (the oxygen is bonded to it again), and the log line says so. Heavy atoms pdb2pqr **adds** (`OXT` of a protein, say) are not touched, only counted and warned about ("pdb2pqr added N heavy atoms"). The counts are recorded beside the cache file (`<file>.balance`) and shown by the `heavy atoms` stage of the timing log (`[1821 in, 1821 out; 1 restored, 0 added by pdb2pqr]`; the counts include waters and ions of the input file).

### Robustness of the pdb2pqr run

- The chains of a structure with conflicting termini are read, and the per-group outputs merged, **by text** (the chain-id column, lines verbatim), not with BioStructures' strict parser, so files pdb2pqr accepts but BioStructures does not still work.
- Hybrid-36 atom serials (`B0205`, from files of more than 99999 atoms) are not read by pdb2pqr, which does not need them: the temporary copy of such a file numbers its atoms afresh (ANISOU and CONECT records, which refer to serials, are left out of the copy).
- The standard error of pdb2pqr and of propka3 is captured to a file in the temporary directory, and the last relevant lines (`ValueError`, `RuntimeError`, `CRITICAL`, `non-integer charge`, `Giving up`) go into the `Pdb2pqrError`/`PropkaError` message.
- Chains that reuse an id and its residue numbers (two molecules both labelled `A`, separated by TER, as in SASDAC9) are given the next unused chain id in the copy that goes into pdb2pqr, and true duplicate atoms are dropped there (`MolecularStructure.sanitized_copy`, below); the output keeps the new ids, which never reach the scattering model.
- Residue keys are matched on chain, number and insertion code **stripped**, because some writers align the number differently (SASDPU6's terminal residues are shifted by one column) and pdb2pqr realigns it.

### Terminus protonation

pdb2pqr's terminus handling is not pH-driven (it defaults to a fixed charged state). Under `Propka`, `_terminus_groups(pKa_records, pH, chains)` overrides this from the "N+"/"C-" records, producing, per chain, pdb2pqr's --neutraln/--neutralc CLI flags. A free N-terminus gets --neutraln when it's deprotonated (neutral), a free C-terminus gets --neutralc when it's protonated (neutral). These flags are global to a single pdb2pqr call not per-chain, so a structure whose free N-termini (or C-termini) round to different protonation states at the same pH can't be represented by one run. `resolve_hydrogens` handles this by partitioning chains into groups that share a flag, running pdb2pqr once per group, and merging each run's chains back into one hydrogenated structure. Pdb2pqrError is raised when pdb2pqr cannot be run or produces no usable output (bad input path, non-zero exit, missing expected output file).

```
			  ┌───────────────────────────────────┐
              │ 	PROPKA pKa records            │
              │ propka_pKas(full_structure)       │
 			  │ computed once on the full complex │
			  └───────────────┬───────────────────┘
                              │
                              │
                              ▼
        ┌─────────────────────┴─────────────────────┐
        │ _terminus_groups(pKa_records, pH, chains) │
        │											│
        │	determine, for each chain:				│
        │ 		--neutraln?   --neutralc?		    │
        └─────────────────────┬─────────────────────┘
                              │
                              │
                              ▼
                  ┌───────────┴─────────────┐
                  │group chains by identical│
                  │terminal-flag combination│
                  └───────────┬─────────────┘
                              │
                ┌─────────────┴────────────────┐
                ▼    						   ▼
      ┌─────────┴──────────┐	    ┌──────────┴─────────┐
	  │ single flag group  │		│multiple flag groups│
      └─────────┬──────────┘        └────────────┬───────┘
                │							     │
                ▼                                ▼
      ┌─────────┴───────────┐     ┌──────────────┴───────────────┐
      │ Run Pdb2pqr once    │     │ For each distinct flag       │
      │ on the full         │     │ combination:                 │
      │ structure with      │     │                              │
      │ that group's flags. │     │  1. Run Pdb2pqr on the full  │
      └──────────┬──────────┘     │     original structure with  │
                 │                │     this group's flags       │
                 │                │                              │
                 │                │  2. Keep only atoms from     │
                 │                │     this group's chains      │
                 │                │                              │
                 │                │  3. Discard atoms from       │
                 │                │     all other chains         │
                 │                └──────────────┬───────────────┘
                 │                               │
                 │                               │
                 │                               ▼
                 │                ┌──────────────┴────────────┐
                 │                │ Merge the retained atoms  │
                 │                │ from all groups           │
                 │                └─────────────┬─────────────┘
                 │                				│
                 └───────────────┬──────────────┘
                                 │
                                 ▼
                  ┌──────────────┴─────────────┐
                  │ Write one hydrogenated PDB │
				  └──────────────┬─────────────┘
			                     │
                                 ▼
				  ┌──────────────┴─────────────────────────┐
                  │ cache "<stem>_pH<pH>_<ff>_<method>.pdb"│
				  └────────────────────────────────────────┘
```

## Terminus protonation (Henderson-Hasselbalch, in Propka.jl)

For a **base** group (charged when protonated, e.g. the free N-terminus), the protonated fraction at solution pH is

```
f = 1 / (1 + 10^(pH - pKa))
```

and for an **acid** group (charged when deprotonated, e.g. the free C-terminus) the deprotonated fraction is

```
f = 1 / (1 + 10^(pKa - pH))
```

`_group_protonated` reduces both to the same rule, charged ⟺ f > 0.5, so a group sitting exactly at its own pKa rounds to its *uncharged* state. `_terminus_groups` applies it to each chain's PROPKA N+/C- records to decide pdb2pqr's --neutraln/--neutralc flags, per chain.
