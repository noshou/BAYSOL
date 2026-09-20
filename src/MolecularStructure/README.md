# charge_topology.json

Per-titratable-group charge topology for ionizable protein side chains and  termini: which atoms carry a group's charge and how it splits between them, and whether the group is charged when protonated (`"base"`) or deprotonated (`"acid"`). Consumed by `Ionization.jl` together with per-residue-instance pKa PROPKA via Henderson-Hasselbalch, to produce a per-atom charge at a given solution pH.

## Schema

```json
{
  "RESNAME": {"type": "acid" | "base", "atoms": {"ATOMNAME": fraction, ...}}
}
```

`fraction` values within one group sum to `1.0`. `type` sets the Henderson-Hasselbalch direction: `"base"` groups are charged when  protonated; `"acid"` groups are charged when deprotonated.

## Groups and Splits

- **ASP** (`OD1`/`OD2`, acid), **GLU** (`OE1`/`OE2`, acid): even 0.5/0.5 split across the carboxylate's two chemically-equivalent oxygens.
- **CYS** (`SG`, acid), **LYS** (`NZ`, base): single atom, no split needed.
- **TYR** (`OH`, acid): single atom, no split needed
- **HIS** (`ND1`/`NE2`, base) and **ARG** (`NE`/`NH1`/`NH2`, base): even split across the ring's/guanidinium's resonance-delocalized nitrogens.
- **N+**/**C-**: PROPKA's group-labeling convention for the N-/C-terminus. Matched by residue number and chain, not resname.

## Source

"A summary of the measured pK values of the ionizable groups in folded proteins," *Protein Science* 18(1):247-251 (2009), DOI `10.1002/pro.19`.
