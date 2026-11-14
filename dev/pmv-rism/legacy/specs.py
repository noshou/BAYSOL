#!/usr/bin/env python3
"""All candidate rows of the 2026-10-22 gap-filling batch. Run: python3 specs.py  (dry run, prints every row, writes rows.json)"""
import sys, json, re, math
sys.path.insert(0, '/home/noso/pmv_work/rism4')
from evaluate import *
from rdkit import Chem
from rdkit.Chem import rdMolDescriptors
ROWS = []; ALIAS = {}; MOVES = []; MISSING = []
EXACT = {t.lower(): t for t in L.values()}
def exact(name): return EXACT.get(name.lower(), name)
def formula_of(job):
    f = rdMolDescriptors.CalcMolFormula(Chem.MolFromSmiles(smi_of(job)))
    return re.sub(r'[+-]\d*$', '', f)
def row(common, iupac, formula, charge, V, u, basis, note):
    ROWS.append(dict(common=common, iupac=exact(iupac), formula=formula, charge=charge, v=round(V, 2), u=round(u, 2), basis=basis, note=note))
def alias(target, *names): ALIAS.setdefault(exact(target), []).extend(names)
def need(x, what):
    if x is None: MISSING.append(what)
    return x
NA = -1.21; K = 9.0; LI = -0.98; CL = 17.8; HCL = 17.82
RISMNOTE = 'AmberTools 3D-RISM, cSPC/E, KH, GAFF2/AM1-BCC, RDKit conformers; ~/pmv_work/rism4/'
def rn(r): return f'{r[2]} seeds'
# ---------------------------------------------------------------- Good-buffer anions (anchored on the table zwitterion)
GB = [  # job stem, zw job, anion job, zw table key, anion target, salt target (+counterion value), aliases
 ('MES', 'MES_zw', 'MES_a', '2-(morpholin-4-yl)ethane-1-sulfonic acid', '2-(morpholin-4-yl)ethane-1-sulfonate', 'sodium 2-(morpholin-4-yl)ethane-1-sulfonate', NA, ['mes anion', 'mes(1-)', 'mes-', 'mes sodium salt']),
 ('MOPS', 'MOPS_zw', 'MOPS_a', '3-(morpholin-4-yl)propane-1-sulfonic acid', '3-(morpholin-4-yl)propane-1-sulfonate', 'sodium 3-(morpholin-4-yl)propane-1-sulfonate', NA, ['mops anion', 'mops(1-)', 'mops-', 'mops sodium salt']),
 ('MOPSO', 'MOPSO_zw', 'MOPSO_a', '2-hydroxy-3-(morpholin-4-yl)propane-1-sulfonic acid', '2-hydroxy-3-(morpholin-4-yl)propane-1-sulfonate', 'sodium 2-hydroxy-3-(morpholin-4-yl)propane-1-sulfonate', NA, ['mopso anion', 'mopso(1-)', 'mopso-', 'mopso sodium salt']),
 ('HEPES', 'HEPES_zw', 'HEPES_a', '2-[4-(2-hydroxyethyl)piperazin-1-yl]ethane-1-sulfonic acid', '2-[4-(2-hydroxyethyl)piperazin-1-yl]ethane-1-sulfonate', 'sodium 2-[4-(2-hydroxyethyl)piperazin-1-yl]ethane-1-sulfonate', NA, ['hepes anion', 'hepes(1-)', 'hepes-', 'sodium hepes', 'hepes sodium', 'hepes sodium salt', 'hepes-na', 'na-hepes']),
 ('CHES', 'CHES_zw', 'CHES_a', '2-(cyclohexylamino)ethane-1-sulfonic acid', '2-(cyclohexylamino)ethane-1-sulfonate', 'sodium 2-(cyclohexylamino)ethane-1-sulfonate', NA, ['ches anion', 'ches(1-)', 'ches-', 'ches sodium salt']),
 ('CAPS', 'CAPS_zw', 'CAPS_a', '3-(cyclohexylamino)propane-1-sulfonic acid', '3-(cyclohexylamino)propane-1-sulfonate', 'sodium 3-(cyclohexylamino)propane-1-sulfonate', NA, ['caps anion', 'caps(1-)', 'caps-', 'caps sodium salt']),
]
GBV = {}
for stem, zw, an, zkey, atgt, stgt, cat, als in GB:
    vz, uz = tv(zkey)
    r = anchored(an, zw, vz, uz, 2.0)
    if need(r, f'{stem} anion') is None: continue
    V, u, n = r; GBV[stem] = (V, u)
    row(f'{stem} anion', atgt, formula_of(an), -1, V, u, 'estimated',
        f'3D-RISM difference anchored on the table zwitterion {vz} (anion - zwitterion = {V - vz:+.2f}); {RISMNOTE}')
    alias(atgt, *als[:3])
    if stem == 'HEPES':
        row('potassium HEPES', 'potassium 2-[4-(2-hydroxyethyl)piperazin-1-yl]ethane-1-sulfonate', 'C8H17KN2O4S', 0, V + K, q(u, 1.0), 'derived', f'HEPES anion {V:.2f} + K+ {K}')
        alias('potassium 2-[4-(2-hydroxyethyl)piperazin-1-yl]ethane-1-sulfonate', 'potassium hepes', 'hepes potassium', 'hepes potassium salt', 'hepes-k')
    f = formula_of(an)
    sf = {'MES': 'C6H12NNaO4S', 'MOPS': 'C7H14NNaO4S', 'MOPSO': 'C7H14NNaO5S', 'HEPES': 'C8H17N2NaO4S', 'CHES': 'C8H16NNaO3S', 'CAPS': 'C9H18NNaO3S'}[stem]
    row(f'sodium {stem}', stgt, sf, 0, V + NA, q(u, 1.0), 'derived', f'{stem} anion {V:.2f} + Na+ {NA}')
    alias(stgt, *[a for a in als[3:]])
# PIPES: disodium salt (both nitrogens neutral); direct RISM
rp = direct('PIPES_m2', 4.0)
if need(rp, 'PIPES 2-'):
    V, u, n = rp
    row('PIPES dianion', "2,2'-(piperazine-1,4-diyl)di(ethane-1-sulfonate)", 'C8H16N2O6S2', -2, V, u, 'estimated', f'3D-RISM with the group correction ({n} seeds); {RISMNOTE}')
    alias("2,2'-(piperazine-1,4-diyl)di(ethane-1-sulfonate)", 'pipes(2-)', 'pipes dianion')
    row('disodium PIPES', "disodium 2,2'-(piperazine-1,4-diyl)di(ethane-1-sulfonate)", 'C8H16N2Na2O6S2', 0, V + 2 * NA, q(u, 1.4), 'derived', f'PIPES(2-) {V:.2f} + 2 Na+')
    alias("disodium 2,2'-(piperazine-1,4-diyl)di(ethane-1-sulfonate)", 'disodium pipes', 'pipes disodium salt', 'na2pipes', 'pipes sodium salt')
# ---------------------------------------------------------------- fatty acids and anions
va, ua = tv('decanoate'); vh, uh = tv('hexanoic acid')
FA = [('myristic', 'tetradecanoic acid', 'tetradecanoate', 14, 0, ['myristic acid', 'tetradecanoic acid'], ['myristate', 'tetradecanoate']),
      ('palmitic', 'hexadecanoic acid', 'hexadecanoate', 16, 0, ['palmitic acid', 'hexadecanoic acid', 'cetylic acid'], ['palmitate', 'hexadecanoate']),
      ('stearic', 'octadecanoic acid', 'octadecanoate', 18, 0, ['stearic acid', 'octadecanoic acid'], ['stearate', 'octadecanoate']),
      ('oleic', 'octadec-9-enoic acid', 'octadec-9-enoate', 18, 1, ['oleic acid', 'cis-9-octadecenoic acid'], ['oleate']),
      ('linoleic', 'octadeca-9,12-dienoic acid', 'octadeca-9,12-dienoate', 18, 2, ['linoleic acid'], ['linoleate']),
      ('linolenic', 'octadeca-9,12,15-trienoic acid', 'octadeca-9,12,15-trienoate', 18, 3, ['linolenic acid', 'alpha-linolenic acid'], ['linolenate'])]
for k, acid, anion, nC, nd, aal, anal in FA:
    ex = q(0.3 * (nC - 10), 2.5 * nd)
    r = anchored(f'{k}_a', 'decanoate', va, 0.5, ex)
    if need(r, f'{k} anion'):
        V, u, n = r
        row(f'{k} anion', anion, formula_of(f'{k}_a'), -1, V, u, 'estimated', f'3D-RISM difference anchored on measured decanoate {va} ({RISMNOTE})')
        alias(anion, *anal)
    r = anchored(f'{k}_acid', 'hexanoic_acid', vh, uh or 0.1, q(0.3 * (nC - 6), 2.5 * nd))
    if need(r, f'{k} acid'):
        V, u, n = r
        row(k + ' acid', acid, formula_of(f'{k}_acid'), 0, V, u, 'estimated', f'3D-RISM difference anchored on measured hexanoic acid {vh} ({RISMNOTE})')
        alias(acid, *aal[:1] if k != 'myristic' else [])
r = direct('lauroylsarcosinate_a', 6.0)
if need(r, 'lauroyl sarcosinate'):
    V, u, n = r
    row('N-lauroylsarcosinate', 'dodecanoylsarcosinate', 'C15H28NO3', -1, V, u, 'estimated', f'3D-RISM with the group correction ({n} seeds); {RISMNOTE}')
    alias('dodecanoylsarcosinate', 'lauroylsarcosinate', 'n-lauroylsarcosinate', 'sarkosyl anion', 'lauroyl sarcosinate')
    row('sodium lauroyl sarcosinate', 'sodium lauroyl sarcosinate', 'C15H28NNaO3', 0, V + NA, q(u, 1.0), 'derived', f'N-lauroylsarcosinate {V:.2f} + Na+')
    alias('sodium lauroyl sarcosinate', 'sarkosyl', 'sodium n-lauroylsarcosinate', 'sodium lauroylsarcosinate')
# ---------------------------------------------------------------- analogy (predicted) rows
row('isobutyric acid', '2-methylpropanoic acid', 'C4H8O2', 0, tv('butanoic acid')[0], 1.0, 'predicted', 'isomer analogy: 2-methylbutanoic, 3-methylbutanoic and pentanoic acid all 100.5 in the table, so branching changes nothing; value of butanoic acid')
row('isobutyrate', '2-methylpropanoate', 'C4H7O2', -1, tv('butanoate')[0], 1.0, 'predicted', 'isomer analogy as for isobutyric acid; value of butanoate')
alias('2-methylpropanoate', 'isobutyrate', 'isobutanoate', 'isobutyrate anion')
v1 = tv('pentan-2-one')[0]; vb = tv('butan-2-one')[0]
row('methyl isobutyl ketone', '4-methylpentan-2-one', 'C6H12O', 0, v1 + (v1 - vb) - 1.5, 3.0, 'predicted', f'pentan-2-one {v1} plus one CH2 ({v1 - vb:.2f}, from butan-2-one {vb}) minus 1.5 for the branch (3-methylbutan-2-one is 3.0 below pentan-2-one for an alpha branch)')
vp = tv('proline')[0]; vdm = tv('n,n-dimethylglycine')[0]; vs = tv('sarcosine')[0] if 'sarcosine' in T or 'sarcosine' in L else 62.51
row('N-methylproline', '1-methylpyrrolidine-2-carboxylate', 'C6H11NO2', 0, vp + (vdm - vs), 3.0, 'predicted', f'proline {vp} plus the secondary to tertiary amine step of sarcosine {vs} to N,N-dimethylglycine {vdm} (zwitterion)')
alias('1-methylpyrrolidine-2-carboxylate', 'n-methylproline', 'hygric acid', 'n-methyl-l-proline', '1-methylproline')
vt = 40.5 + (tv('trifluoromethanesulfonate')[0] - tv('methanesulfonate')[0])
row('trifluoroacetate', 'trifluoroacetate', 'C2F3O2', -1, vt, 4.0, 'predicted', 'acetate 40.5 plus the CF3 for CH3 step measured on the sulfonates (trifluoromethanesulfonate - methanesulfonate = 19.72); the 3D-RISM value with the acetate offset is about 54')
alias('trifluoroacetate', 'tfa anion', 'tfa-', 'trifluoroacetate anion', 'trifluoroethanoate')
row('trifluoroacetic acid', 'trifluoroacetic acid', 'C2HF3O2', 0, vt, 4.0, 'predicted', 'strong acid (pKa 0.5), fully dissociated: trifluoroacetate with V(H+) = 0')
alias('trifluoroacetic acid', 'tfa')
row('sodium trifluoroacetate', 'sodium trifluoroacetate', 'C2F3NaO2', 0, vt + NA, 4.1, 'derived', f'trifluoroacetate {vt:.2f} + Na+')
vsorb = 104.7 - K
row('sorbate', 'hexa-2,4-dienoate', 'C6H7O2', -1, vsorb, 1.6, 'derived', 'potassium hexa-2,4-dienoate 104.7 minus K+ 9.0')
alias('hexa-2,4-dienoate', 'sorbate', 'sorbate anion')
row('sorbic acid', 'hexa-2,4-dienoic acid', 'C6H8O2', 0, vsorb + (tv('hexanoic acid')[0] - tv('hexanoate')[0]), 2.0, 'predicted', f'sorbate {vsorb:.2f} plus the carboxylate to acid step of hexanoate to hexanoic acid ({tv("hexanoic acid")[0] - tv("hexanoate")[0]:.2f})')
alias('hexa-2,4-dienoic acid', 'sorbic acid')
vprop = tv('propane')[0]; vet = tv('ethane')[0]
row('hexane', 'hexane', 'C6H14', 0, vprop + 3 * (vprop - vet), 3.0, 'predicted', f'propane {vprop} plus three CH2 at the ethane to propane increment {vprop - vet:.1f}; sparingly soluble, a pure-water volume')
vac = tv('azanium acetate')[0]
# ---------------------------------------------------------------- RISM direct and anchored small organics
def put(job, common, iupac, formula, charge, res, how):
    if need(res, common) is None: return
    V, u, n = res
    row(common, iupac, formula or formula_of(job), charge, V, u, 'estimated', f'{how} ({n} seeds); {RISMNOTE}')
vbet = tv('betaine')[0]; ubet = tv('betaine')[1] or 0.05
put('carnitine_zw', 'carnitine', '3-hydroxy-4-(trimethylazaniumyl)butanoate', None, 0, anchored('carnitine_zw', 'betaine', vbet, ubet, 3.0), f'3D-RISM difference anchored on measured betaine {vbet}')
alias('3-hydroxy-4-(trimethylazaniumyl)butanoate', 'carnitine', 'l-carnitine', 'levocarnitine', 'dl-carnitine')
put('acetylcarnitine_zw', 'acetylcarnitine', 'acetylcarnitine', None, 0, anchored('acetylcarnitine_zw', 'betaine', vbet, ubet, 5.0), f'3D-RISM difference anchored on measured betaine {vbet}')
alias('acetylcarnitine', 'acetyl-l-carnitine', 'alcar')
vh_, uh_ = tv('hedma') if 'hedma' in T else (90.7, 2.1)
put('BHEDMA', 'bis(2-hydroxyethyl)dimethylazanium', 'bis(2-hydroxyethyl)dimethylazanium', None, 1, anchored('BHEDMA', 'HEDMA', 90.7, 2.1, 3.0), '3D-RISM difference anchored on 2-hydroxyethyldimethylammonium 90.7')
vtris, utris = tv('tris')
put('AMPol_0', '2-amino-2-methylpropan-1-ol', '2-amino-2-methylpropan-1-ol', None, 0, anchored('AMPol_0', 'Tris', vtris, utris, 2.5), f'3D-RISM difference anchored on measured Tris {vtris}')
alias('2-amino-2-methylpropan-1-ol', 'amp', '2-amino-2-methyl-1-propanol', 'aminomethylpropanol', 'ampol', '2-amino-2-methylpropanol')
put('AMPol_1', '2-amino-2-methylpropan-1-aminium', '2-hydroxy-1,1-dimethylethylazanium', None, 1, direct('AMPol_1', 3.0), '3D-RISM with the group correction')
put('creatine_zw', 'creatine', 'n-carbamimidoyl-n-methylglycine', None, 0, direct('creatine_zw', 6.0), '3D-RISM with the group correction (guanidinium group unmodelled)')
alias('n-carbamimidoyl-n-methylglycine', 'creatine', 'n-methylguanidinoacetic acid', 'methylguanidinoacetic acid')
put('NAC_0', 'N-acetylcysteine', 'n-acetylcysteine', None, 0, direct('NAC_0', 6.0), '3D-RISM with the group correction (thiol unmodelled)')
put('NAC_a', 'N-acetylcysteinate', 'n-acetylcysteinate', None, -1, direct('NAC_a', 6.0), '3D-RISM with the group correction (thiol unmodelled)')
alias('n-acetylcysteinate', 'nac anion', 'n-acetylcysteine anion', 'acetylcysteinate')
alias('n-acetylcysteine', 'nac', 'n-acetyl-l-cysteine', 'acetylcysteine')
LIPOIC = 'pentanoic'
put('lipoic_0', 'lipoic acid', '5-(1,2-dithiolan-3-yl)pentanoic acid', None, 0, direct('lipoic_0', 8.0), '3D-RISM with the group correction (dithiolane unmodelled)')
put('lipoic_a', 'lipoate', '5-(1,2-dithiolan-3-yl)pentanoate', None, -1, direct('lipoic_a', 8.0), '3D-RISM with the group correction (dithiolane unmodelled)')
alias('5-(1,2-dithiolan-3-yl)pentanoate', 'lipoate', 'thioctate', 'alpha-lipoate')
alias('5-(1,2-dithiolan-3-yl)pentanoic acid', 'lipoic acid', 'alpha-lipoic acid', 'thioctic acid')
BIO = '5-[2-oxo-1,3,3a,4,6,6a-hexahydrothieno[3,4-d]imidazol-4-yl]pentanoic acid'
put('biotin_0', 'biotin', BIO, None, 0, direct('biotin_0', 8.0), '3D-RISM with the group correction (ureido thiolane ring unmodelled)')
put('biotin_a', 'biotinate', '5-[2-oxo-1,3,3a,4,6,6a-hexahydrothieno[3,4-d]imidazol-4-yl]pentanoate', None, -1, direct('biotin_a', 8.0), '3D-RISM with the group correction (ureido thiolane ring unmodelled)')
alias('5-[2-oxo-1,3,3a,4,6,6a-hexahydrothieno[3,4-d]imidazol-4-yl]pentanoate', 'biotinate', 'biotin anion', 'biotin(1-)')
alias(BIO, 'biotin', 'd-biotin', 'vitamin h')
GLCA = '2,3,4,5,6-pentahydroxyhexanoic acid'
put('gluconic_0', 'gluconic acid', GLCA, None, 0, direct('gluconic_0', 4.0), '3D-RISM with the group correction')
put('gluconate_a', 'gluconate', '2,3,4,5,6-pentahydroxyhexanoate', None, -1, direct('gluconate_a', 4.0), '3D-RISM with the group correction')
alias('2,3,4,5,6-pentahydroxyhexanoate', 'gluconate', 'd-gluconate', 'gluconate anion')
alias(GLCA, 'gluconic acid', 'd-gluconic acid')
# pyridine family anchored on nicotinic acid
vn, un = 80.21, 0.05
for job, common, tgt, ex in (('picolinic_0', 'picolinic acid', 'pyridine-2-carboxylic acid', 3.0), ('isonicotinic_0', 'isonicotinic acid', 'pyridine-4-carboxylic acid', 3.0),
                             ('dipicolinic_0', 'dipicolinic acid', 'pyridine-2,6-dicarboxylic acid', 4.0), ('nicotinamide', 'nicotinamide', 'pyridine-3-carboxamide', 3.0)):
    put(job, common, tgt, None, 0, anchored(job, 'nicotinic_0', vn, un, ex), f'3D-RISM difference anchored on measured nicotinic acid {vn}')
alias('pyridine-2-carboxylic acid', 'picolinic acid', '2-picolinic acid', 'pyridine-2-carboxylic acid')
alias('pyridine-4-carboxylic acid', 'isonicotinic acid', '4-picolinic acid')
alias('pyridine-2,6-dicarboxylic acid', 'dipicolinic acid', '2,6-pyridinedicarboxylic acid')
alias('pyridine-3-carboxamide', 'nicotinamide', 'niacinamide', 'nicotinic acid amide', 'vitamin b3 amide')
put('benzamidine_0', 'benzamidine', 'benzenecarboximidamide', None, 0, direct('benzamidine_0', 8.0), '3D-RISM with the group correction (aromatic amidine unmodelled)')
vcholate = tv('cholate')[0]
put('taurocholate_a', 'taurocholate', 'taurocholate', None, -1, anchored('taurocholate_a', 'cholate', vcholate, 0.3, 8.0), f'3D-RISM difference anchored on measured cholate {vcholate}')
alias('taurocholate', 'taurocholate anion', 'taurocholic acid anion')
row('sodium taurocholate', 'sodium taurocholate', 'C26H44NNaO7S', 0, ([r for r in ROWS if r['common'] == 'taurocholate'] or [dict(v=0, u=0)])[0]['v'] + NA, 8.4, 'derived', 'taurocholate + Na+') if any(r['common'] == 'taurocholate' for r in ROWS) else None
alias('sodium taurocholate', 'sodium taurocholate hydrate', 'taurocholic acid sodium salt', 'na taurocholate')
put('glycocholate_a', 'glycocholate', 'glycocholate', None, -1, anchored('glycocholate_a', 'cholate', vcholate, 0.3, 8.0), f'3D-RISM difference anchored on measured cholate {vcholate}')
alias('glycocholate', 'glycocholate anion', 'glycocholic acid anion')
row('sodium glycocholate', 'sodium glycocholate', 'C26H42NNaO6', 0, ([r for r in ROWS if r['common'] == 'glycocholate'] or [dict(v=0)])[0]['v'] + NA, 8.4, 'derived', 'glycocholate + Na+') if any(r['common'] == 'glycocholate' for r in ROWS) else None
alias('sodium glycocholate', 'glycocholic acid sodium salt', 'na glycocholate')
# ---------------------------------------------------------------- nucleotides
va_, vg_, vi_, vc_, vu_ = 171.43, 175.4, 166.10, 154.19, 152.32
vamp = 189.1 - NA                                  # H-AMP(-) from the monosodium salt
vh2atp = 238.9 + 2 * (-NA)                         # H2ATP(2-) from the disodium salt
ATP4 = None
e2 = anchored('ATP4', 'H2ATP2', vh2atp, 0.4, 10.0) if rism('H2ATP2') else None
if need(e2, 'ATP4-'):
    gtp = 290.0 - 4 * NA                           # GTP(4-) from the tetrasodium salt (+-22)
    e1 = (gtp + (va_ - vg_), 22.0)
    V, u = e2[0], q(e2[1], 5.0)
    ATP4 = (V, u)
    row('ATP(4-)', "adenosine 5'-triphosphate(4-)", 'C10H12N5O13P3', -4, V, u, 'estimated', f'measured ATP disodium {238.9} + 2 Na+ as H2ATP(2-), plus the 3D-RISM H2ATP(2-) to ATP(4-) step; the GTP tetrasodium row (290 +- 22) would give {e1[0]:.1f} through the measured adenosine - guanosine step and is not used (it disagrees by about 70 and looks inflated against GMP 220); {RISMNOTE}')
    alias("adenosine 5'-triphosphate(4-)", 'atp(4-)', 'atp4-', 'atp anion', 'atp tetraanion')
def step(job, ref, vref, uref, extra, tgt, common, charge=None, al=(), note=''):
    r = anchored(job, ref, vref, uref, extra)
    if need(r, common) is None: return None
    V, u, n = r
    row(common, tgt, formula_of(job), SM[job][1], V, u, 'estimated', f'{note}3D-RISM difference anchored on the ATP(4-) estimate; {RISMNOTE}')
    alias(tgt, *al); return V, u
if ATP4:
    gts = step('GTPgS4', 'ATP4', ATP4[0] + (vg_ - va_), ATP4[1], 4.0, "guanosine 5'-[γ-thio]triphosphate(4-)", 'GTPgammaS(4-)', al=('gtpγs(4-)', 'gtp-gamma-s(4-)'), note='guanosine-for-adenosine step measured on the nucleosides; ')
    ats = step('ATPgS4', 'ATP4', ATP4[0], ATP4[1], 4.0, "adenosine 5'-[γ-thio]triphosphate(4-)", 'ATPgammaS(4-)', al=('atpγs(4-)', 'atp-gamma-s(4-)', 'atpgs4-'))
    ata = step('ATPaS4', 'ATP4', ATP4[0], ATP4[1], 4.0, "adenosine 5'-[α-thio]triphosphate(4-)", 'ATPalphaS(4-)', al=('atpαs(4-)', 'atp-alpha-s(4-)'))
    apn = step('AMPPNP4', 'ATP4', ATP4[0], ATP4[1], 3.0, "adenosine 5'-[β,γ-imido]triphosphate(4-)", 'AMP-PNP(4-)', al=('amp-pnp(4-)', 'ampPNP4-', 'adenylyl imidodiphosphate(4-)', 'app(nh)p(4-)'))
    adp = step('ADP3', 'ATP4', ATP4[0], ATP4[1], 5.0, "adenosine 5'-diphosphate(3-)", 'ADP(3-)', al=('adp(3-)', 'adp3-', 'adp anion'))
    itp_v = ATP4[0] + (vi_ - va_)
    row('ITP(4-)', "inosine 5'-triphosphate(4-)", 'C10H11N4O14P3', -4, itp_v, ATP4[1], 'estimated', f'ATP(4-) estimate plus the measured inosine - adenosine step ({vi_ - va_:.2f}); {RISMNOTE}')
    alias("inosine 5'-triphosphate(4-)", 'itp(4-)', 'itp4-')
    if adp:
        idp_v = adp[0] + (vi_ - va_)
        row('IDP(3-)', "inosine 5'-diphosphate(3-)", 'C10H11N4O11P2', -3, idp_v, adp[1], 'estimated', f'ADP(3-) estimate plus the measured inosine - adenosine step; {RISMNOTE}')
        alias("inosine 5'-diphosphate(3-)", 'idp(3-)', 'idp3-')
        # H-ADP(2-) and the disodium salt
        had = anchored('HADP2', 'ADP3', adp[0], adp[1], 6.0)
        if need(had, 'HADP2-'):
            row('disodium ADP', "disodium adenosine 5'-diphosphate", 'C10H13N5Na2O10P2', 0, had[0] + 2 * NA, q(had[1], 1.4), 'estimated', f'ADP(3-) estimate plus the RISM protonation step to HADP(2-), plus 2 Na+')
            alias("disodium adenosine 5'-diphosphate", 'adp disodium', 'adp disodium salt', 'na2adp', 'adp-na2', 'adenosine 5-diphosphate disodium')
    hat = anchored('HATP3', 'H2ATP2', vh2atp, 0.4, 8.0)
    if need(hat, 'HATP3-'):
        row('trisodium ATP', "trisodium adenosine 5'-triphosphate", 'C10H13N5Na3O13P3', 0, hat[0] + 3 * NA, q(hat[1], 1.7), 'estimated', 'measured ATP disodium as H2ATP(2-) plus the RISM protonation step to HATP(3-), plus 3 Na+; ' + RISMNOTE)
        alias("trisodium adenosine 5'-triphosphate", 'atp trisodium', 'atp trisodium salt', 'na3atp', 'atp-na3')
    # trisodium GDPNP from the tetrasodium row
    if apn:
        gd4 = apn[0] + (vg_ - va_)
        hg = anchored('HGDPNP3', 'GDPNP4', gd4, apn[1], 8.0)
        if need(hg, 'HGDPNP3-'):
            row('trisodium GDPNP', "trisodium guanosine 5'-[β,γ-imido]triphosphate", 'C10H14N6Na3O13P3', 0, hg[0] + 3 * NA, q(hg[1], 1.7), 'estimated', 'AMP-PNP(4-) estimate plus the measured guanosine - adenosine step, RISM protonation step to HGDPNP(3-), plus 3 Na+; the older tetrasodium GDPNP row (288.8) rests on the GTP row and disagrees by about 60; ' + RISMNOTE)
            alias("trisodium guanosine 5'-[β,γ-imido]triphosphate", 'gdpnp trisodium', 'gmppnp trisodium')
camp = anchored('cAMP_a', 'AMP_a', vamp, 0.3, 4.0)
if need(camp, 'cAMP'):
    V, u, n = camp
    for nm, tgt, base, job, al in (('cAMP', "adenosine 3',5'-cyclic monophosphate", 0.0, 'cAMP_a', ('camp', "3',5'-cyclic amp", 'cyclic amp', 'cyclic adenosine monophosphate', 'adenosine cyclic monophosphate')),
                                  ('cGMP', "guanosine 3',5'-cyclic monophosphate", vg_ - va_, None, ('cgmp', 'cyclic gmp', 'cyclic guanosine monophosphate')),
                                  ('cCMP', "cytidine 3',5'-cyclic monophosphate", vc_ - va_, None, ('ccmp', 'cyclic cmp')),
                                  ('cUMP', "uridine 3',5'-cyclic monophosphate", vu_ - va_, None, ('cump', 'cyclic ump'))):
        f = {'cAMP': 'C10H11N5O6P', 'cGMP': 'C10H11N5O7P', 'cCMP': 'C9H11N3O7P', 'cUMP': 'C9H10N2O8P'}[nm]
        ex = 0 if nm == 'cAMP' else 1.5
        row(nm + '(1-)', tgt + '(1-)', f, -1, V + base, q(u, ex), 'estimated', f'3D-RISM difference anchored on measured AMP(-) {vamp:.2f} (monosodium AMP 189.1 + Na+)' + ('' if nm == 'cAMP' else f' plus the measured nucleoside step {base:+.2f}') + '; ' + RISMNOTE)
        alias(tgt + '(1-)', nm.lower() + '(1-)', nm.lower() + ' anion', nm.lower() + '-')
        # neutral acid named by the lookup target: anion plus the AMP neutral-to-monoanion step of the table
        vamp0 = tv("adenosine 5'-monophosphate")[0]
        row(nm + ' (neutral)', tgt, f.replace('C10H11','C10H12').replace('C9H11N3','C9H12N3').replace('C9H10N2','C9H11N2'), 0, V + base + (vamp0 - vamp), q(u, ex, 5.0), 'predicted', f'cyclic monophosphate anion {V + base:.2f} plus the neutral-to-monoanion step of AMP in this table ({vamp0 - vamp:+.2f})')
        alias(tgt, *al)
# ---------------------------------------------------------------- cofactors, vitamins, dyes, peptides (direct RISM, large extra terms)
def pair(jobN, jobI, nameN, tgtN, nameI, tgtI, chI, extra, how, alN=(), alI=(), fN=None, fI=None):
    rN = direct(jobN, extra) if jobN else None
    rI = direct(jobI, extra) if jobI else None
    if jobN and need(rN, nameN): row(nameN, tgtN, fN or formula_of(jobN), SM[jobN][1], rN[0], rN[1], 'estimated', f'{how} ({rN[2]} seeds); {RISMNOTE}'); alias(tgtN, *alN)
    if jobI and need(rI, nameI): row(nameI, tgtI, fI or formula_of(jobI), chI, rI[0], rI[1], 'estimated', f'{how} ({rI[2]} seeds); {RISMNOTE}'); alias(tgtI, *alI)
    return rN, rI
G = 'direct RISM + group correction'
pair('FAD_0', 'FAD_m2', 'FAD', 'flavin adenine dinucleotide', 'FAD(2-)', 'flavin adenine dinucleotide(2-)', -2, 15.0, G, ('fad', 'flavin adenine dinucleotide', 'fad oxidized'), ('fad(2-)', 'fad2-'))
pair('FADH2_0', 'FADH2_m2', 'FADH2', 'reduced flavin adenine dinucleotide', 'FADH2(2-)', 'reduced flavin adenine dinucleotide(2-)', -2, 15.0, G, ('fadh2', 'fad reduced', 'reduced fad'), ('fadh2(2-)',))
pair('FMN_0', 'FMN_m2', 'FMN', "riboflavin 5'-phosphate", 'FMN(2-)', "riboflavin 5'-phosphate(2-)", -2, 12.0, G, ('fmn', 'flavin mononucleotide', 'riboflavin phosphate'), ('fmn(2-)', 'fmn2-'))
pair('riboflavin', None, 'riboflavin', '7,8-dimethyl-10-(1-ribityl)isoalloxazine', None, None, 0, 10.0, G, ('riboflavin', 'vitamin b2', 'lactoflavin'))
pair('PLP_0', 'PLP_m2', "pyridoxal 5'-phosphate", "pyridoxal 5'-phosphate", "pyridoxal 5'-phosphate(2-)", "pyridoxal 5'-phosphate(2-)", -2, 8.0, G, ('plp', 'pyridoxal phosphate', 'pyridoxal 5-phosphate'), ('plp(2-)',))
pair('folate_0', 'folate_m2', 'folic acid', 'folic acid', 'folate(2-)', 'folate(2-)', -2, 10.0, G, ('folic acid', 'vitamin b9', 'pteroylglutamic acid'), ('folate', 'folate(2-)', 'folate anion'))
pair('THF_m2', 'THF_0', 'tetrahydrofolate(2-)', 'tetrahydrofolate', 'tetrahydrofolic acid', 'tetrahydrofolic acid', 0, 10.0, G, ('thf', 'tetrahydrofolate', 'tetrahydrofolate(2-)', 'h4folate'), ('tetrahydrofolic acid',), fN=None, fI=None)
pair('acCoA_0', 'acCoA_m4', 'acetyl coenzyme A', 'acetyl coenzyme A', 'acetyl coenzyme A(4-)', 'acetyl coenzyme A(4-)', -4, 18.0, G, ('acetyl coenzyme a',), ('acetyl-coa', 'acetyl coa', 'acetylcoa', 'acetyl coenzyme a(4-)'))
pair('CoA_0', 'CoA_m4', 'coenzyme A', 'coenzyme A', 'coenzyme A(4-)', 'coenzyme A(4-)', -4, 18.0, G, ('coenzyme a',), ('coa', 'coash', 'coa-sh', 'coenzyme a(4-)'))
pair('TPP_0', 'TPP_m2', 'thiamine diphosphate', 'thiamine diphosphate', 'thiamine diphosphate(2-)', 'thiamine diphosphate(2-)', -2, 10.0, G, ('thiamine diphosphate', 'thiamine pyrophosphate'), ('tpp', 'thiamine pyrophosphate(2-)', 'cocarboxylase'))
rt = direct('thiamine_p1', 8.0)
if need(rt, 'thiamine'):
    row('thiamine', 'thiamine', 'C12H17N4OS', 1, rt[0], rt[1], 'estimated', f'direct RISM + group correction ({rt[2]} seeds); {RISMNOTE}')
    alias('thiamine', 'vitamin b1', 'aneurin', 'thiamine cation', 'thiamin')
    row('thiamine chloride', 'thiamine;hydrochloride', 'C12H17ClN4OS', 0, rt[0] + CL, q(rt[1], 1.0), 'derived', f'thiamine cation {rt[0]:.2f} + Cl- {CL}; the hydrochloride adds a second chloride, which is not stored (bulk)')
    alias('thiamine;hydrochloride', 'thiamine hcl', 'thiamine hydrochloride', 'vitamin b1 hydrochloride')
pair('Q10', 'Q10H2', 'ubiquinone-10', 'ubiquinone', 'ubiquinol-10', 'ubiquinol', 0, 20.0, G, ('ubiquinone', 'coenzyme q10', 'coq10', 'ubiquinone-10', 'q10'), ('ubiquinol', 'ubiquinol-10', 'reduced coq10', 'coq10h2'))
pair('SOS_0', 'SOS_m8', 'sucrose octasulfate', 'sucrose octasulfate', 'sucrose octasulfate(8-)', 'sucrose octasulfate(8-)', -8, 30.0, G, ('sucrose octasulfate',), ('sos', 'sucrose octasulfate(8-)', 'sucralfate anion'))
pair('leupeptin_0', None, 'leupeptin', 'leupeptin', None, None, 0, 10.0, G, ('leupeptin',))
pair('pepstatin_0', 'pepstatin_m1', 'pepstatin A', 'pepstatin A', 'pepstatin A(1-)', 'pepstatin A(1-)', -1, 12.0, G, ('pepstatin a', 'pepstatin'), ('pepstatin a(1-)',))
# dyes and indicators
pair('neocuproine', None, 'neocuproine', '2,9-dimethyl-1,10-phenanthroline', None, None, 0, 10.0, G, ('neocuproine', '2,9-dimethylphenanthroline'))
pair('bathocuproine', None, 'bathocuproine', '2,9-dimethyl-4,7-diphenyl-1,10-phenanthroline', None, None, 0, 12.0, G, ('bathocuproine',))
pair('ferrozine_0', 'ferrozine_m2', 'ferrozine (acid)', '3-(2-pyridyl)-5,6-bis(4-phenylsulfonic acid)-1,2,4-triazine', 'ferrozine(2-)', '3-(2-pyridyl)-5,6-bis(4-phenylsulfonate)-1,2,4-triazine', -2, 12.0, G, ('ferrozine acid',), ('ferrozine', 'ferrozine(2-)', 'ferrozine anion'))
pair('methylred_0', 'methylred_m1', 'methyl red', '2-{[4-(dimethylamino)phenyl]diazenyl}benzoic acid', 'methyl red anion', '2-{[4-(dimethylamino)phenyl]diazenyl}benzoate', -1, 10.0, G, ('methyl red',), ('methyl red anion',))
pair('phenolred_0', None, 'phenol red (sultone form)', 'phenolsulfonphthalein', None, None, 0, 15.0, G, ('phenol red', 'phenolsulfonphthalein', 'phenolsulfonephthalein', 'phenol red sultone'))
pair('bromophenolblue_0', None, 'bromophenol blue (sultone form)', "3',3'',5',5''-tetrabromophenolsulfonphthalein", None, None, 0, 15.0, G, ('bromophenol blue', 'bpb', 'bromophenol blue sultone'))
pair('phenolphthalein', None, 'phenolphthalein', '3,3-bis(4-hydroxyphenyl)-2-benzofuran-1(3H)-one', None, None, 0, 10.0, G, ('phenolphthalein',))
pair('sulfathiazole', None, 'sulfathiazole', '4-amino-N-(1,3-thiazol-2-yl)benzenesulfonamide', None, None, 0, 10.0, G, ('sulfathiazole',))
pair('pyridoxine', None, 'pyridoxine', '4,5-bis(hydroxymethyl)-2-methylpyridin-3-ol', None, None, 0, 6.0, G, ('pyridoxine', 'vitamin b6'))
pair('maltitol', None, 'maltitol', '4-O-alpha-D-glucopyranosyl-D-glucitol', None, None, 0, 4.0, G, ('maltitol',))
pair('TCEPO_0', 'TCEPO_m3', 'TCEP oxide', '3,3\',3\'\'-phosphoryltripropanoic acid', 'TCEP oxide(3-)', "3,3',3''-phosphoryltripropanoate", -3, 8.0, G, ('tcep oxide', 'tcepo'), ('tcep oxide(3-)',))
ra = direct('methylorange_m1', 10.0)
if need(ra, 'methyl orange anion'):
    row('methyl orange anion', '4-[[4-(dimethylamino)phenyl]diazenyl]benzenesulfonate', formula_of('methylorange_m1'), -1, ra[0], ra[1], 'estimated', f'{G} ({ra[2]} seeds); {RISMNOTE}')
    row('methyl orange sodium', 'sodium 4-[[4-(dimethylamino)phenyl]diazenyl]benzenesulfonate', 'C14H14N3NaO3S', 0, ra[0] + NA, q(ra[1], 1.0), 'derived', 'anion + Na+')
    alias('sodium 4-[[4-(dimethylamino)phenyl]diazenyl]benzenesulfonate', 'methyl orange', 'sodium methyl orange', 'helianthin', 'tropaeolin d')
rn_ = direct('neutralred_p1', 10.0)
if need(rn_, 'neutral red'):
    row('neutral red cation', '3-amino-7-dimethylamino-2-methylphenazin-10-ium', formula_of('neutralred_p1'), 1, rn_[0], rn_[1], 'estimated', f'{G} ({rn_[2]} seeds); {RISMNOTE}')
    row('neutral red chloride', '3-amino-7-dimethylamino-2-methylphenazine hydrochloride', 'C15H17ClN4', 0, rn_[0] + CL, q(rn_[1], 1.0), 'derived', 'cation + Cl-')
    alias('3-amino-7-dimethylamino-2-methylphenazine hydrochloride', 'neutral red', 'neutral red chloride', 'toluylene red')
rz = direct('azodye_m3', 15.0)
if need(rz, 'azo dye'):
    row('azo dye (3-)', '3-hydroxy-4-[2-sulfonatophenylazo]-2,7-naphthalenedisulfonate', formula_of('azodye_m3'), -3, rz[0], rz[1], 'estimated', f'{G} ({rz[2]} seeds); {RISMNOTE}')
rb = direct('acidblue_m2', 15.0)
if need(rb, 'acid blue dye'):
    tg = '2-[[4-[ethyl-[(3-sulfonatophenyl)methyl]amino]phenyl]-(2-sulfonatophenyl)methylidene]cyclohexa-3,5-dien-1-one'
    row('acid blue dye (2-)', tg, formula_of('acidblue_m2'), -2, rb[0], rb[1], 'estimated', f'{G} ({rb[2]} seeds); {RISMNOTE}')
    row('acid blue dye disodium', 'disodium ' + tg, 'C27H23N1Na2O7S2'.replace('N1', 'N'), 0, rb[0] + 2 * NA, q(rb[1], 1.4), 'derived', 'dianion + 2 Na+')
# detergent DPC goes to Polymers; keep here for the apply step
DPC = direct('DPC_zw', 8.0)
# ---------------------------------------------------------------- arsenic: P analogue + the table's P -> As step (cacodylic acid 74.0 vs 72.81)
AS = 1.2; UAS = 5.0
for job, common, tgt, formula, ch, al in (('MPA_0', 'methylarsonic acid', 'methylarsonic acid', 'CH5AsO3', 0, ('methylarsonic acid', 'methanearsonic acid', 'monomethylarsonic acid', 'mma')),
                                     ('MPA_m1', 'methylarsonate(1-)', 'methylarsonate', 'CH4AsO3', -1, ('methylarsonate', 'methylarsonate(1-)', 'hydrogen methylarsonate', 'monomethylarsonate')),
                                     ('MPA_m2', 'methylarsonate(2-)', 'methylarsonate(2-)', 'CH3AsO3', -2, ('methylarsonate(2-)',)),
                                     ('TMPO', 'trimethylarsine oxide', 'trimethylarsine oxide', 'C3H9AsO', 0, ('trimethylarsine oxide', 'tmao arsenic', 'trimethylarsenic oxide')),
                                     ('DMPhi', 'dimethylarsinous acid', 'dimethylarsinous acid', 'C2H7AsO', 0, ('dimethylarsinous acid', 'dimethylarsinic(iii) acid')),
                                     ('TMPhiAnh', 'dimethylarsinic anhydride', 'dimethylarsinic anhydride', 'C4H12As2O3', 0, ('dimethylarsinic anhydride', 'cacodylic anhydride', 'cacodyl oxide dioxide'))):
    r = direct(job, 3.0)
    if need(r, common):
        row(common, tgt, formula, ch, r[0] + AS, q(r[1], UAS), 'estimated', f'3D-RISM of the phosphorus analogue ({job}, {r[2]} seeds) with the group correction, plus the P to As step of +{AS} fixed by the table\'s cacodylic acid (74.0 against 72.81 for dimethylphosphinic acid); the step is unvalidated; {RISMNOTE}')
        alias(tgt, *al)
# ---------------------------------------------------------------- boron and arsenic(III) from the literature and the table's own series
vba, _ = tv('boric acid'); VW = 18.07
dV = -26.0; udV = 3.0
vbor = vba + VW + dV
row('borate', 'borate', 'BH4O4', -1, vbor, q(4.0, udV), 'predicted', f'tetrahydroxyborate from boric acid {vba} (table, OBIGT) + H2O {VW} + the ionization volume of boric acid at 25 C, B(OH)3 + H2O -> B(OH)4- + H+, about -26 cm3/mol (Ward and Millero 1975, Geochim. Cosmochim. Acta 39, 1595; -25.9 in 0.725 m NaCl, -28.9 at I = 0.1 m in a later spectrophotometric study; the papers were not read in full); V(H+) = 0')
alias('borate', 'tetrahydroxyborate', 'borate ion', 'borate(1-)', 'b(oh)4-', 'metaborate', 'tetrahydroxyborate(1-)')
vtb = 2 * NA + 2 * vbor + 2 * vba - 7 * VW
row('disodium tetraborate', 'disodium tetraborate', 'B4Na2O7', 0, vtb, q(2 * 4.0, 2 * 4.0, 1.0), 'predicted', 'Na2B4O7 + 7 H2O -> 2 Na+ + 2 B(OH)4- + 2 B(OH)3: two borate ions, two boric acids and two Na+ minus seven waters of pure-water volume; the large uncertainty is the borate estimate; the hydrates (borax) are on the anhydrous basis')
alias('disodium tetraborate', 'borax', 'sodium tetraborate', 'sodium borate', 'sodium tetraborate decahydrate', 'borax decahydrate', 'na2b4o7', 'disodium tetraborate decahydrate', 'sodium borate decahydrate')
MOVES += ['disodium tetraborate decahydrate']
h2as = tv('dihydrogen arsenite')[0]; has_ = tv('hydrogen arsenate')[0]; as_ = tv('arsenate')[0]; h2a = tv('dihydrogen arsenate')[0]
row('arsenite', 'arsenite', 'AsO3', -3, h2as + (as_ - h2a), 8.0, 'predicted', f'dihydrogen arsenite {h2as} plus the two-step deprotonation shift of arsenate (arsenate {as_} - dihydrogen arsenate {h2a}); arsenite(3-) exists only above pH 12')
alias('arsenite', 'arsenite(3-)', 'asO3 3-')
row('sodium arsenite', 'sodium arsenite', 'AsNaO2', 0, NA + h2as - VW, 3.5, 'derived', f'NaAsO2 + H2O -> Na+ + H2AsO3-: Na+ {NA} + dihydrogen arsenite {h2as} - H2O {VW}')
alias('sodium arsenite', 'sodium metaarsenite', 'naaso2')
row('potassium arsenite', 'potassium arsenite', 'AsKO2', 0, K + h2as - VW, 3.5, 'derived', f'K+ {K} + dihydrogen arsenite {h2as} - H2O {VW}')
alias('potassium arsenite', 'potassium metaarsenite')
# ---------------------------------------------------------------- lipids (literature bilayer volumes, other temperatures) and polynucleotide residues
NJ = '10.1021/acs.jpcb.8b12010'
for nm, tgt, f, A3, T_, u, doi in (('DMPC', '1,2-dimyristoyl-glycero-3-phosphocholine', 'C36H72NO8P', 1117, 323.15, 0.01, NJ + ' [Table 4, volume per lipid of the fluid bilayer at 50 C, a bilayer value, not a monomer in solution; T=323.15 K]'),
                                   ('DOPC', '1,2-dioleoyl-glycero-3-phosphocholine', 'C44H84NO8P', 1303, 313.15, 0.01, NJ + ' [Table 5 fluid-phase volume per lipid, 1303 A3 (Table 4 gives 1312); bilayer value, not a monomer in solution; T=313.15 K]'),
                                   ('POPC', '1-palmitoyl-2-oleoyl-glycero-3-phosphocholine', 'C42H82NO8P', 1256, 303.15, 0.01, 'IUCr data supplement fs5056 (SDP-GAP analysis): POPC volume per lipid 1256 A3 at 30 C; authorship not confirmed, bilayer value; T=303.15 K')):
    V = A3 * 0.602214076
    row(nm, tgt, f, 0, V, V * u, 'other-T', doi)
vpopc = 1256 * 0.602214076
row('phosphatidylcholine (generic)', 'phosphatidylcholine', 'C42H82NO8P', 0, vpopc, vpopc * 0.04, 'predicted', 'generic egg or soy PC taken as POPC (C16:0 + C18:1 mean chain composition) at the bilayer volume of POPC, 30 C, 4 % uncertainty for the composition and temperature')
row('phosphatidylcholine mixture', 'phosphatidylcholine mixture', 'C42H82NO8P', 0, vpopc, vpopc * 0.05, 'predicted', 'as phosphatidylcholine (generic): POPC bilayer volume; composition not specified')
row('soybean phospholipid mixture', 'soybean phospholipid mixture', 'C42H82NO8P', 0, vpopc, vpopc * 0.06, 'predicted', 'soybean PC dominated by linoleoyl chains; taken as the POPC bilayer volume, 6 % uncertainty; other phospholipids in the mixture ignored')
alias('phosphatidylcholine', 'pc', 'egg pc', 'soy pc', 'lecithin', 'egg phosphatidylcholine', 'soy phosphatidylcholine')
alias('1,2-dimyristoyl-glycero-3-phosphocholine', 'dmpc', '1,2-dimyristoyl-sn-glycero-3-phosphocholine')
alias('1,2-dioleoyl-glycero-3-phosphocholine', 'dopc', '1,2-dioleoyl-sn-glycero-3-phosphocholine')
alias('1-palmitoyl-2-oleoyl-glycero-3-phosphocholine', 'popc', '1-palmitoyl-2-oleoyl-sn-glycero-3-phosphocholine')
alias('soybean phospholipid mixture', 'soybean phospholipids', 'soy phospholipid', 'asolectin')
# ---------------------------------------------------------------- additivity of table ion rows (derived)
def addit(common, tgt, formula, comps, extra=1.5, note=''):
    V = 0.0; us = []
    for name, n in comps:
        v, u = tv(name); V += n * v
        us.append(abs(n) * (u if u else 1.0))
    u = q(*us, extra)
    row(common, tgt, formula, 0, V, u, 'derived', 'additivity of table ion rows: ' + ' '.join(f'{"+" if n > 0 else "-"}{abs(n) if abs(n) != 1 else ""}{nm}' for nm, n in comps) + (' ' + note if note else ''))
    return V, u
ED = {2: "dihydrogen 2,2',2'',2'''-(ethane-1,2-diyldinitrilo)tetraacetate", 4: "2,2',2'',2'''-(ethane-1,2-diyldinitrilo)tetraacetate"}
addit('ammonium dihydrogen phosphate', 'azanium dihydrogen phosphate', 'H6NO4P', [('azanium', 1), ('dihydrogen phosphate', 1)])
alias('azanium dihydrogen phosphate', 'ammonium dihydrogen phosphate', 'ammonium phosphate monobasic', 'monoammonium phosphate', 'map', 'nh4h2po4')
addit('ammonium formate', 'azanium formate', 'CH5NO2', [('azanium', 1), ('formate', 1)])
alias('azanium formate', 'ammonium formate', 'nh4hco2')
addit('ammonium bicarbonate', 'azanium hydrogen carbonate', 'CH5NO3', [('azanium', 1), ('hydrogen carbonate', 1)])
alias('azanium hydrogen carbonate', 'ammonium bicarbonate', 'ammonium hydrogen carbonate', 'nh4hco3', 'ammonium hydrogencarbonate')
addit('ammonium carbonate', 'bis(azanium) carbonate', 'CH8N2O3', [('azanium', 2), ('carbonate', 1)])
alias('bis(azanium) carbonate', 'ammonium carbonate', '(nh4)2co3')
addit('diammonium hydrogen phosphate', 'bis(azanium) hydrogen phosphate', 'H9N2O4P', [('azanium', 2), ('hydrogen phosphate', 1)])
alias('bis(azanium) hydrogen phosphate', 'diammonium hydrogen phosphate', 'ammonium phosphate dibasic', 'dap', '(nh4)2hpo4', 'diammonium phosphate')
addit('calcium lactate', 'calcium bis(2-hydroxypropanoate)', 'C6H10CaO6', [('calcium(2+)', 1), ('lactate', 2)])
alias('calcium bis(2-hydroxypropanoate)', 'calcium lactate', 'calcium dilactate')
addit('potassium glutamate', 'potassium 2-aminopentanedioate', 'C5H8KNO4', [('potassium(1+)', 1), ('glutamate', 1)])
alias('potassium 2-aminopentanedioate', 'potassium glutamate', 'monopotassium glutamate', 'k-glutamate', 'kglu')
addit('potassium lactate', 'potassium 2-hydroxypropanoate', 'C3H5KO3', [('potassium(1+)', 1), ('lactate', 1)])
alias('potassium 2-hydroxypropanoate', 'potassium lactate')
addit('potassium benzoate', 'potassium benzoate', 'C7H5KO2', [('potassium(1+)', 1), ('benzoate', 1)])
vcac = tv('sodium dimethylarsinate')
row('potassium cacodylate', 'potassium dimethylarsinate', 'C2H6AsKO2', 0, vcac[0] - NA + K, q(vcac[1], 1.5), 'derived', f'sodium cacodylate {vcac[0]} with the Na to K swap (K+ {K} - Na+ {NA}); the sodium row is itself an estimate')
alias('potassium dimethylarsinate', 'potassium cacodylate')
addit('sodium pyruvate', 'sodium 2-oxopropanoate', 'C3H3NaO3', [('sodium(1+)', 1), ('pyruvate', 1)])
alias('sodium 2-oxopropanoate', 'sodium pyruvate')
addit('sodium glutamate', 'sodium 2-aminopentanedioate', 'C5H8NNaO4', [('sodium(1+)', 1), ('glutamate', 1)])
alias('sodium 2-aminopentanedioate', 'sodium glutamate', 'monosodium glutamate', 'msg', 'na-glutamate', 'sodium l-glutamate')
MOVES += ['sodium 2-aminopentanedioate monohydrate']
alias('sodium 2-aminopentanedioate', 'sodium glutamate monohydrate', 'monosodium glutamate monohydrate')
addit('disodium EDTA', "disodium 2,2',2'',2'''-(ethane-1,2-diyldinitrilo)tetraacetate", 'C10H14N2Na2O8', [('sodium(1+)', 2), (ED[2], 1)], 3.0, '(disodium dihydrogen EDTA; the two lookup names are the same compound)')
addit('disodium dihydrogen EDTA', "disodium dihydrogen 2,2',2'',2'''-(ethane-1,2-diyldinitrilo)tetraacetate", 'C10H14N2Na2O8', [('sodium(1+)', 2), (ED[2], 1)], 3.0)
alias("disodium 2,2',2'',2'''-(ethane-1,2-diyldinitrilo)tetraacetate", 'disodium edta', 'na2edta', 'edta disodium', 'edta disodium salt', 'disodium edetate', 'edta na2', 'edta-na2', 'disodium ethylenediaminetetraacetate')
alias("disodium dihydrogen 2,2',2'',2'''-(ethane-1,2-diyldinitrilo)tetraacetate", 'disodium dihydrogen edta', 'disodium edta dihydrate', 'na2h2edta', 'edta disodium dihydrate')
addit('tetrasodium EDTA', "tetrasodium 2,2',2'',2'''-(ethane-1,2-diyldinitrilo)tetraacetate", 'C10H12N2Na4O8', [('sodium(1+)', 4), (ED[4], 1)], 3.0)
alias("tetrasodium 2,2',2'',2'''-(ethane-1,2-diyldinitrilo)tetraacetate", 'tetrasodium edta', 'edta tetrasodium', 'na4edta', 'edta tetrasodium salt', 'edta-na4', 'tetrasodium ethylenediaminetetraacetate')
for common, tgt, f, comps, al, ex in (
    ('copper(II) chloride', 'copper(2+) dichloride', 'CuCl2', [('copper(2+)', 1), ('chloride', 2)], ('copper chloride', 'copper(ii) chloride', 'cupric chloride', 'cucl2', 'copper(ii) chloride dihydrate'), 3.0),
    ('iron(II) chloride', 'iron(2+) dichloride', 'FeCl2', [('iron(2+)', 1), ('chloride', 2)], ('iron(ii) chloride', 'ferrous chloride', 'fecl2', 'iron chloride'), 3.0),
    ('iron(II) sulfate', 'iron(2+) sulfate', 'FeO4S', [('iron(2+)', 1), ('sulfate', 1)], ('iron(ii) sulfate', 'ferrous sulfate', 'feso4', 'ferrous sulphate', 'iron(ii) sulfate heptahydrate'), 3.0),
    ('iron(III) chloride', 'iron(3+) trichloride', 'FeCl3', [('iron(3+)', 1), ('chloride', 3)], ('iron(iii) chloride', 'ferric chloride', 'fecl3', 'iron(iii) chloride hexahydrate'), 4.0),
    ('manganese(II) chloride', 'manganese(2+) dichloride', 'MnCl2', [('manganese(2+)', 1), ('chloride', 2)], ('manganese chloride', 'manganese(ii) chloride', 'mncl2', 'manganese dichloride', 'manganese(ii) chloride tetrahydrate'), 3.0),
    ('manganese(II) sulfate', 'manganese(2+) sulfate', 'MnO4S', [('manganese(2+)', 1), ('sulfate', 1)], ('manganese sulfate', 'manganese(ii) sulfate', 'mnso4', 'manganese(ii) sulfate monohydrate'), 3.0),
    ('iron(III) sulfate', 'diiron trisulfate', 'Fe2O12S3', [('iron(3+)', 2), ('sulfate', 3)], ('iron(iii) sulfate', 'ferric sulfate', 'fe2(so4)3'), 4.0),
    ('zinc acetate', 'zinc diacetate', 'C4H6O4Zn', [('zinc(2+)', 1), ('acetate', 2)], ('zinc acetate', 'zinc(ii) acetate', 'znoac2', 'zn(oac)2', 'zinc acetate dihydrate'), 3.0),
    ('lithium hydroxide', 'lithium hydroxide', 'HLiO', [('lithium(1+)', 1), ('hydroxide', 1)], ('lioh', 'lithium hydroxide monohydrate'), 1.5),
    ('potassium hydroxide', 'potassium hydroxide', 'HKO', [('potassium(1+)', 1), ('hydroxide', 1)], ('koh', 'caustic potash', 'potassium hydroxide pellets'), 1.5),
    ('hydrogen bromide', 'bromane', 'BrH', [('bromide', 1)], ('hbr', 'hydrobromic acid', 'hydrogen bromide'), 1.0),
    ('hydrogen iodide', 'iodane', 'HI', [('iodide', 1)], ('hi', 'hydroiodic acid', 'hydrogen iodide'), 1.0),
    ('perchloric acid', 'perchloric acid', 'ClHO4', [('perchlorate', 1)], ('hclo4', 'perchloric acid'), 1.0),
    ('methanesulfonic acid', 'methanesulfonic acid', 'CH4O3S', [('methanesulfonate', 1)], ('msa', 'mesylic acid', 'methanesulphonic acid'), 1.0),
    ('disodium hydrogen arsenate', 'disodium hydrogen arsenate', 'AsHNa2O4', [('sodium(1+)', 2), ('hydrogen arsenate', 1)], ('sodium arsenate dibasic', 'disodium arsenate', 'na2haso4', 'sodium hydrogen arsenate'), 2.0),
    ('sodium dihydrogen arsenate', 'sodium dihydrogen arsenate', 'AsH2NaO4', [('sodium(1+)', 1), ('dihydrogen arsenate', 1)], ('sodium arsenate monobasic', 'nah2aso4'), 2.0),
    ('tripotassium arsenate', 'tripotassium arsenate', 'AsK3O4', [('potassium(1+)', 3), ('arsenate', 1)], ('potassium arsenate', 'k3aso4'), 2.0),
    ('trisodium arsenate', 'trisodium arsenate', 'AsNa3O4', [('sodium(1+)', 3), ('arsenate', 1)], ('sodium arsenate', 'na3aso4', 'sodium arsenate tribasic'), 2.0),
    ('lithium dihydrogen phosphate', 'lithium dihydrogen phosphate', 'H2LiO4P', [('lithium(1+)', 1), ('dihydrogen phosphate', 1)], ('lih2po4', 'lithium phosphate monobasic'), 1.5),
    ('lithium dodecyl sulfate', 'lithium dodecyl sulfate', 'C12H25LiO4S', [('lithium(1+)', 1), ('dodecyl sulfate', 1)], ('lds', 'lithium lauryl sulfate', 'lithium dodecyl sulphate'), 1.5),
    ('guanidinium perchlorate', 'guanidinium perchlorate', 'CH6ClN3O4', [('guanidinium', 1), ('perchlorate', 1)], ('guanidine perchlorate',), 2.0),
    ('diguanidinium sulfate', 'diguanidinium sulfate', 'C2H12N6O4S', [('guanidinium', 2), ('sulfate', 1)], ('guanidinium sulfate', 'guanidine sulfate', 'guanidine sulphate'), 2.5),
    ('magnesium salicylate', 'magnesium bis(2-hydroxybenzoate)', 'C14H10MgO6', [('magnesium(2+)', 1), ('2-hydroxybenzoate', 2)], ('magnesium salicylate',), 3.0),
    ('potassium aluminium sulfate', 'aluminium potassium bis(sulfate) dodecahydrate', 'AlKO8S2', [('aluminium(3+)', 1), ('potassium(1+)', 1), ('sulfate', 2)], ('alum', 'potassium alum', 'potassium aluminium sulfate', 'aluminium potassium sulfate', 'aluminum potassium sulfate dodecahydrate'), 4.0),
    ('ammonium aluminium sulfate', 'aluminium azanium bis(sulfate) dodecahydrate', 'AlH4NO8S2', [('aluminium(3+)', 1), ('azanium', 1), ('sulfate', 2)], ('ammonium alum', 'ammonium aluminium sulfate', 'aluminium ammonium sulfate'), 4.0),
    ('ammonium nickel sulfate', 'bis(azanium) nickel bis(sulfate) dodecahydrate', 'H8N2NiO8S2', [('azanium', 2), ('nickel(2+)', 1), ('sulfate', 2)], ('ammonium nickel sulfate', 'nickel ammonium sulfate'), 3.0),
):
    addit(common, tgt, f, comps, ex)
    alias(tgt, *al)
# hydrates retargeted to their anhydrous basis
MOVES += ['sodium carbonate decahydrate', 'trehalose dihydrate', 'zinc diacetate dihydrate']
alias('disodium carbonate', 'sodium carbonate decahydrate', 'sodium carbonate monohydrate')
alias('2-(hydroxymethyl)-6-[3,4,5-trihydroxy-6-(hydroxymethyl)oxan-2-yl]oxyoxane-3,4,5-triol', 'trehalose dihydrate', 'd-(+)-trehalose dihydrate', 'trehalose dihydrate')
# water and ammonia;water
row('water', 'water', 'H2O', 0, VW, 0.01, 'derived', 'molar volume of pure water at 25 C, 18.07 (1.00 g/mL basis; Kell); a pure-water solute adds nothing to the electron density balance')
alias('water', 'h2o', 'dihydrogen monoxide', 'light water')
amm = tv('ammonia')
row('ammonia water', 'ammonia;water', 'H3N', 0, amm[0], amm[1] or 0.1, 'derived', 'aqueous ammonia (ammonium hydroxide) as dissolved NH3, the table value of ammonia; the hydroxide is not separated')
alias('ammonia;water', 'ammonium hydroxide', 'ammonia solution', 'aqueous ammonia', 'nh4oh', 'ammonia water')
# ---------------------------------------------------------------- hydrochlorides (parent + HCl with the table's protonation steps)
amine_step = 5.0 / 1.0
def hcl(common, tgt, f, base_name, step, ustep, al, parent_v=None):
    v, u = tv(base_name) if parent_v is None else parent_v
    V = v + step + HCL
    row(common, tgt, f, 0, V, q(u or 0.5, ustep, 1.0), 'predicted', f'parent {v} plus the protonation step {step:+.1f} ({ustep and "table analogues"}) plus HCl {HCL}; the hydrochloride is dissociated, so this is the cation plus chloride')
    alias(tgt, *al)
# carboxylate -> acid step from acetate/acetic acid; amine -> ammonium step from the methyl/butyl/hexyl amines in the table
dCOO = tv('acetic acid')[0] - tv('acetate')[0]
dNH = (tv('methanaminium')[0] - tv('methanamine')[0] + tv('butan-1-aminium')[0] - tv('butan-1-amine')[0] + tv('hexan-1-aminium')[0] - tv('hexan-1-amine')[0]) / 3 if all(k in T for k in ('methanaminium', 'butan-1-aminium', 'hexan-1-aminium', 'methanamine', 'butan-1-amine', 'hexan-1-amine')) else -4.8
hcl('betaine hydrochloride', '(trimethylazaniumyl)acetate;hydrochloride', 'C5H12ClNO2', 'betaine', dCOO, 2.0, ('betaine hcl', 'betaine hydrochloride', 'glycine betaine hydrochloride'))
hcl('glycine hydrochloride', 'glycine;hydrochloride', 'C2H6ClNO2', 'glycine', dCOO, 2.0, ('glycine hcl', 'glycine hydrochloride', 'glycine-hcl', 'glycine·hcl'))
hcl('Tris hydrochloride', '2-amino-2-(hydroxymethyl)propane-1,3-diol;hydrochloride', 'C4H12ClNO3', 'tris', dNH, 1.5, ('tris-hcl', 'tris hcl', 'tris hydrochloride', 'tris-cl', 'tris/hcl', 'trizma hcl', 'tromethamine hydrochloride', 'tris·hcl', 'tris-hydrochloride'))
hcl('bis-tris hydrochloride', '2-[bis(2-hydroxyethyl)amino]-2-(hydroxymethyl)propane-1,3-diol;hydrochloride', 'C8H20ClNO5', 'bis-tris', dNH, 1.5, ('bis-tris hcl', 'bis-tris hydrochloride', 'bistris hcl'))
hcl('TCEP hydrochloride', '3,3\',3\'\'-phosphanetriyltripropanoic acid;hydrochloride', 'C9H16ClO6P', 'tcep', dNH, 4.0, ('tcep hcl', 'tcep-hcl', 'tcep hydrochloride', 'tris(2-carboxyethyl)phosphine hydrochloride'))
vim = tv('1h-imidazol-3-ium chloride')
MOVES += ['imidazole hydrochloride']
alias('1h-imidazol-3-ium chloride', '1h-imidazole;hydrochloride', 'imidazole hydrochloride', 'imidazole hcl', 'imidazole-hcl', 'imidazolium chloride')
rc = anchored('carnitine_zw', 'betaine', vbet, ubet, 3.0)
if need(rc, 'carnitine HCl'):
    row('carnitine hydrochloride', '3-hydroxy-4-(trimethylazaniumyl)butanoate;hydrochloride', 'C7H16ClNO3', 0, rc[0] + dCOO + HCL, q(rc[1], 2.0, 1.0), 'estimated', f'carnitine {rc[0]:.2f} + carboxylate to acid step {dCOO:.1f} + HCl {HCL}')
    alias('3-hydroxy-4-(trimethylazaniumyl)butanoate;hydrochloride', 'carnitine hcl', 'carnitine hydrochloride', 'l-carnitine hydrochloride')
rbh = direct('BHEDMA', 3.0) and anchored('BHEDMA', 'HEDMA', 90.7, 2.1, 3.0)
if need(rbh, 'bis(2-hydroxyethyl)dimethylazanium chloride'):
    row('bis(2-hydroxyethyl)dimethylazanium chloride', 'bis(2-hydroxyethyl)dimethylazanium chloride', 'C6H16ClNO2', 0, rbh[0] + CL, q(rbh[1], 1.0), 'derived', 'cation + Cl-'); alias('bis(2-hydroxyethyl)dimethylazanium chloride', 'bhedma chloride')
vcr = tv('n-carbamimidoyl-n-methylglycine') if 'n-carbamimidoyl-n-methylglycine' in T else None
crow = [r for r in ROWS if r['common'] == 'creatine']
if crow:
    c0 = crow[0]
    row('creatine monohydrate', 'n-carbamimidoyl-n-methylglycine monohydrate', 'C4H9N3O2', 0, c0['v'], c0['u'], 'derived', 'anhydrous basis: the creatine row (hydrate water is bulk)')
    alias('n-carbamimidoyl-n-methylglycine monohydrate', 'creatine monohydrate')
    row('creatine phosphate salt', 'n-carbamimidoyl-n-methylglycine phosphate', 'C4H12N3O6P', 0, c0['v'] + tv('phosphoric acid')[0], q(c0['u'], 3.0), 'predicted', f'creatine {c0["v"]} + phosphoric acid {tv("phosphoric acid")[0]} (the salt as two neutral molecules)')
    alias('n-carbamimidoyl-n-methylglycine phosphate', 'creatine phosphate', 'creatine phosphate salt')
# sodium and calcium salts that need an RISM anion
for anj, tgtna, f, comps_, al in (('gluconate_a', 'sodium 2,3,4,5,6-pentahydroxyhexanoate', 'C6H11NaO7', ('na', 1), ('sodium gluconate', 'na-gluconate')),
                                 ('gluconate_a', 'calcium bis(2,3,4,5,6-pentahydroxyhexanoate)', 'C12H22CaO14', ('ca', 2), ('calcium gluconate',))):
    g = [r for r in ROWS if r['common'] == 'gluconate']
    if g:
        v = g[0]['v']
        if comps_[0] == 'na': row('sodium gluconate', tgtna, f, 0, v + NA, q(g[0]['u'], 1.0), 'derived', 'gluconate + Na+')
        else: row('calcium gluconate', tgtna, f, 0, 2 * v + tv('calcium(2+)')[0], q(2 * g[0]['u'], 1.5), 'derived', '2 gluconate + Ca2+')
        alias(tgtna, *al)
if __name__ == '__main__':
    json.dump(dict(rows=ROWS, alias=ALIAS, moves=MOVES, missing=MISSING), open(HERE + '/rows.json', 'w'), indent=1, ensure_ascii=False)
    for r in ROWS: print(f"{r['basis']:9s} {r['v']:9.2f} ±{r['u']:6.2f}  z={r['charge']:>3}  {r['iupac'][:62]:62s} {r['formula']}")
    print(len(ROWS), 'rows;', len(MISSING), 'missing:', MISSING)
