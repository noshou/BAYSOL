#!/usr/bin/env python3
"""Apply rows.json (from specs.py) to NonBiological/ and Polymers/. Backups in ~/pmv_work/backup_rism4/.
usage: apply_rism4.py [--apply]   (without --apply: report only)"""
import sys, json, csv, re, shutil
from pathlib import Path
sys.path.insert(0, str(Path.home() / 'pmv_work/rism3')); sys.path.insert(0, str(Path.home() / 'pmv_work/names')); sys.path.insert(0, str(Path.home() / 'pmv_work/rism4'))
import apply_new as AN
from chem import electrons
import aledit
HERE = Path.home() / 'pmv_work/rism4'
SRC = Path.home() / 'BAYSOL/src/BulkElectronDensity'; NB = SRC / 'NonBiological'; PO = SRC / 'Polymers'
D = json.load(open(HERE / 'rows.json'))
APPLY = '--apply' in sys.argv
ROWS = D['rows']; ALIAS = D['alias']; MOVES = D['moves']
# polymer-side rows: DPC and the polynucleotide residues
import specs
sys.argv = sys.argv[:1]
PROWS = []; PALIAS = {}
def prow(common, iupac, f, ch, v, u, basis, note): PROWS.append((common, iupac, f, ch, v, u, basis, note))
dpc = specs.DPC
if dpc:
    prow('dodecylphosphocholine', 'dodecylphosphocholine', 'C17H38NO4P', 0, round(dpc[0], 2), round(dpc[1], 2), 'estimated', f'direct 3D-RISM of the zwitterionic monomer ({dpc[2]} seeds) with the group-wise correction fitted to 72 solutes of the NonBiological table (P diester and quaternary N are outside the fitted groups: extra 8); AmberTools 3D-RISM, cSPC/E, KH, GAFF2/AM1-BCC; ~/pmv_work/rism4/; monomer value, not micellar')
    PALIAS['dodecylphosphocholine'] = ['dpc', 'fos-choline-12', 'fos-choline 12', 'fc-12', 'fc12', 'foscholine-12', 'n-dodecylphosphocholine', 'dodecyl phosphocholine', 'lauryl phosphocholine']
vphos = 17.7
for nm, f, ns, tgt, al in (('poly(A)', 'C10H11N5O6P', 171.43, 'poly(adenylic acid)', ('poly(a)', 'polya', 'poly a', 'polyadenylic acid', 'poly(rA)', 'polyriboadenylic acid')),
                           ('poly(G)', 'C10H11N5O7P', 175.4, 'poly(guanylic acid)', ('poly(g)', 'polyg', 'poly g', 'polyguanylic acid', 'poly(rG)')),
                           ('poly(C)', 'C9H11N3O7P', 154.19, 'poly(cytidylic acid)', ('poly(c)', 'polyc', 'poly c', 'polycytidylic acid', 'poly(rC)')),
                           ('poly(U)', 'C9H10N2O8P', 152.32, 'poly(uridylic acid)', ('poly(u)', 'polyu', 'poly u', 'polyuridylic acid', 'poly(rU)'))):
    prow(nm, tgt, f, -1, round(ns + vphos, 2), 3.0, 'predicted', f'per nucleotide residue (a monomer unit of the polymer, sodium counter-ion separate): measured nucleoside {ns} plus the phosphate group increment {vphos} used by the RNA backend (Nucleotide/); the residue of the table equals AMP sodium salt 189.1 for A')
    PALIAS[tgt] = list(al)
# ---------------------------------------------------------------- tuple rows
def tup(r): return (r['common'], r['iupac'], r['formula'], r['charge'], r['v'], r['u'], r['basis'], r['note'])
NBROWS = [tup(r) for r in ROWS]
bad = []
for t in NBROWS + PROWS:
    try: electrons(t[2], int(t[3]))
    except Exception as e: bad.append((t[1], t[2], str(e)))
print('rows', len(NBROWS), 'polymer rows', len(PROWS), 'unparseable formulas', bad)
# alias classification
tg_rows = {t[1].lower() for t in NBROWS}
new_blocks = {t: a for t, a in ALIAS.items() if t.lower() in tg_rows}
extra_alias = {t: a for t, a in ALIAS.items() if t.lower() not in tg_rows}
print('alias targets with rows', len(new_blocks), 'on existing targets', len(extra_alias))
if not APPLY: sys.exit(0)
bk = Path.home() / 'pmv_work/backup_rism4'; bk.mkdir(exist_ok=True)
for p in (NB / 'nonbiological.tsv', NB / 'nonbiological.json', NB / 'nonbio_lookup.json', PO / 'polymers.tsv', PO / 'polymers.json', PO / 'polymers_lookup.json'):
    (bk / p.name).exists() or shutil.copy(p, bk / p.name)
# ---------------------------------------------------------------- NonBiological tsv/json
hdr, R = AN.add_rows(NB, NBROWS, 'nonbiological.json')
# tridecanoate: the Gianni-Lepori row is the dodecanoate (10.6 per CH2 over decanoate -> tridecanoate against 15.5 in the series)
for r in R:
    if r['iupac_name'] == 'tridecanoate' and r['basis'] == 'measured' and r['doi'] == '10.1007/BF00972756':
        r['basis'] = 'rejected'; r['doi'] += ' [rejected 2026-10-22: 196.98 is 10.6 per CH2 above decanoate 165.27 where the series gives 15.5, and equals dodecanoate (196.1); probably the dodecanoate row mislabelled, source not read]'
AN.write_tsv(NB / 'nonbiological.tsv', hdr, R)
J = json.load(open(NB / 'nonbiological.json'))
keys = {t[1] for t in NBROWS} | {'tridecanoate'}
ch = AN.recompute_json(J, R, keys)
if not any(r['basis'] != 'rejected' for r in R if r['iupac_name'].lower() == 'tridecanoate'): J.pop('tridecanoate', None)
(NB / 'nonbiological.json').write_text(json.dumps(J, indent=2, ensure_ascii=False))
for c in ch:
    if c[1]: print('JSON CHANGED', c)
print('json keys now', len(J), 'new/changed', len(ch))
# ---------------------------------------------------------------- lookup: new blocks, then aliases on existing targets and hydrate retargets
AN.NBROWS = NBROWS
Lk = AN.insert_lookup(NB / 'nonbio_lookup.json', {t: [a.lower() for a in al] for t, al in new_blocks.items()})
# retarget hydrate / salt-form targets: every alias of the old target moves to the anhydrous target
RET = {'sodium carbonate decahydrate': 'disodium carbonate', 'trehalose dihydrate': '2-(hydroxymethyl)-6-[3,4,5-trihydroxy-6-(hydroxymethyl)oxan-2-yl]oxyoxane-3,4,5-triol',
       'zinc diacetate dihydrate': 'zinc diacetate', 'sodium 2-aminopentanedioate monohydrate': 'sodium 2-aminopentanedioate', '1h-imidazole;hydrochloride': '1h-imidazol-3-ium chloride',
       'disodium tetraborate decahydrate': 'disodium tetraborate'}
Lk = json.load(open(NB / 'nonbio_lookup.json'))
exact = {t.lower(): t for t in Lk.values()}
moves = [a for a, t in Lk.items() if t.lower() in RET]
adds = {a: exact[RET[Lk[a].lower()].lower()] for a in moves}
for t, al in extra_alias.items():
    for a in al:
        a = a.lower()
        if a in Lk and Lk[a].lower() != t.lower() and a not in moves: print('ALIAS CONFLICT', a, Lk[a], '->', t, '(kept)'); continue
        adds[a] = exact.get(t.lower(), t)
aledit.apply(str(NB / 'nonbio_lookup.json'), adds, moves=moves)
print('lookup retargeted', len(moves), 'extra aliases', len(extra_alias))
# ---------------------------------------------------------------- polymers
hdrp, RP = AN.add_rows(PO, PROWS, 'polymers.json', 'polymers.tsv')
AN.write_tsv(PO / 'polymers.tsv', hdrp, RP)
JP = json.load(open(PO / 'polymers.json'))
for k in {t[1].lower() for t in PROWS}:
    rs = [r for r in RP if r['iupac_name'].lower() == k and r['basis'] != 'rejected']
    best = min(rs, key=AN.rk)
    JP[k] = [electrons(best['formula'], int(best['charge'])), float(best['v0_cm3_per_mol']), float(best['uncertainty_cm3_per_mol']) if best['uncertainty_cm3_per_mol'] else None]
(PO / 'polymers.json').write_text(json.dumps(JP, indent=2, ensure_ascii=False))
AN.NBROWS = PROWS
AN.insert_lookup(PO / 'polymers_lookup.json', {t: [a.lower() for a in al] for t, al in PALIAS.items()})
print('done')
