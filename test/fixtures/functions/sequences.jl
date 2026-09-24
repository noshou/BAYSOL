# SPDX-License-Identifier: LGPL-2.1-or-later

# Shared corpus of real biological sequences (protein/DNA/RNA)

# ---------------------------------------------------------------------------
# Protein (spans short/medium/long, and "regular" vs ionizable-residue-heavy)
# ---------------------------------------------------------------------------

"""
Human oxytocin, mature nonapeptide (UniProt P01178, oxytocin-neurophysin 1
proprotein, residues 3-11 of the precursor). Sequence corresponds to the
nonapeptide first synthesized by du Vigneaud et al. 1953, "The Synthesis of
an Octapeptide Amide with the Hormonal Activity of Oxytocin", J. Am. Chem.
Soc. 75:4879-4880, doi:10.1021/ja01115a553.
"""
const OXYTOCIN = "CYIQNCPLG"

"""
Human insulin A chain (UniProt P01308, INS_HUMAN, residues 90-110 of the
preproinsulin precursor; gene sequence from Bell, Pictet, Rutter, Cordell,
Tischer & Goodman 1980, "Sequence of the human insulin gene", Nature
284:26-32, doi:10.1038/284026a0). Short (21 aa), mildly ionizable (one E).
"""
const INSULIN_A = "GIVEQCCTSICSLYQLENYCN"

"""
Human insulin B chain (UniProt P01308, INS_HUMAN, residues 25-54 of the
preproinsulin precursor; gene sequence from Bell et al. 1980, Nature
284:26-32, doi:10.1038/284026a0). Short (30 aa), "non-regular": ionizable-heavy
(H, E, K, R all present).
"""
const INSULIN_B = "FVNQHLCGSHLVEALYLVCGERGFFYTPKT"

"""
Hen egg-white lysozyme (UniProt P00698, mature chain, 129 aa; sequence from
Canfield 1963, "The Amino Acid Sequence of Egg White Lysozyme", J. Biol.
Chem. 238:2698-2707, doi:10.1016/S0021-9258(18)67888-3). Medium length;
moderately ionizable.
"""
const LYSOZYME =    "KVFGRCELAAAMKRHGLDNYRGYSLGNWVCAAKFESNFNTQATNRNTDGSTDYGILQINSRW" *
                    "WCNDGRTPGSRNLCNIPCSALLSSDITASVNCAKKIVSDGNGMNAWVAWRNRCKGTDVQAWIRGCRL"

"""
Green fluorescent protein, *Aequorea victoria* (UniProt P42212, GFP_AEQVI,
full 238 aa mature chain; sequence from Prasher, Eckenrode, Ward,
Prendergast & Cormier 1992, "Primary structure of the Aequorea victoria
green-fluorescent protein", Gene 111:229-233,
doi:10.1016/0378-1119(92)90691-H). Long; "non-regular": ionizable-heavy
(D/E/K/R throughout).
"""
const GFP = "MSKGEELFTGVVPILVELDGDVNGHKFSVSGEGEGDATYGKLTLKFICTTGKLPVPWPTL" *
            "VTTFSYGVQCFSRYPDHMKQHDFFKSAMPEGYVQERTIFFKDDGNYKTRAEVKFEGDTLV" *
            "NRIELKGIDFKEDGNILGHKLEYNYNSHNVYIMADKQKNGIKVNFKIRHNIEDGSVQLAD" *
            "HYQQNTPIGDGPVLLPDNHYLSTQSALSKDPNEKRDHMVLLEFVTAAGITHGMDELYK"

# ---------------------------------------------------------------------------
# DNA
# ---------------------------------------------------------------------------

"""
M13 forward (-21) universal sequencing primer, a standard, widely-published
oligonucleotide (e.g. NEB/Thermo Fisher catalogue; Messing 1983, "New M13
vectors for cloning", Methods Enzymol. 101:20-78,
doi:10.1016/0076-6879(83)01005-8). Short (18 nt) DNA oligo.
"""
const M13_PRIMER = "TGTAAAACGACGGCCAGT"

"""
pUC19 cloning vector, GenBank L09137.2, positions 1-240 (the polylinker /
lacZα region of the plasmid). Longer (240 bp) real DNA fragment.
"""
const PUC19_FRAGMENT = "TCGCGCGTTTCGGTGATGACGGTGAAAACCTCTGACACATGCAGCTCCCGGAGACGGTCACAGCTTGTCT" *
                        "GTAAGCGGATGCCGGGAGCAGACAAGCCCGTCAGGGCGCGTCAGCGGGTGTTGGCGGGTGTCGGGGCTGG" *
                        "CTTAACTATGCGGCATCAGAGCAGATTGTACTGAGAGTGCACCATATGCGGTGTGAAATACCGCACAGAT" *
                        "GCGTAAGGAGAAAATACCGCATCAGGCGCC"

# ---------------------------------------------------------------------------
# RNA
# ---------------------------------------------------------------------------

"""
*Saccharomyces cerevisiae* tRNA-Phe-GAA-1-1, mature sequence (GtRNAdb,
gtrnadb.ucsc.edu, genome build sacCer3; intron and 3' CCA excluded,
naturally-modified bases shown as their unmodified parent letter). Medium
length (73 nt) RNA; classic structural-biology reference tRNA (its crystal
structure was the first solved for an intact tRNA, Kim et al. 1974,
Science 185:435-440, doi:10.1126/science.185.4149.435).
"""
const TRNA_PHE = "GCGGACUUAGCUCAGUUGGGAGAGCGCCAGACUGAAGAUCUGGAGGUCCUGUGUUCGAUCCACAGAGUUCGCA"

"""
*Escherichia coli* 5S ribosomal RNA (RNAcentral URS0000049E57; originally
sequenced by Brownlee, Sanger & Barrell 1968, "The sequence of 5S
ribosomal RNA", J. Mol. Biol. 34:379-412,
doi:10.1016/0022-2836(68)90168-X). Long (120 nt) RNA.
"""
const RRNA_5S = "UGCCUGGCGGCCGUAGCGCGGUGGUCCCACCUGACCCCAUGCCGAACUCAGAAGUGAAACGCCGUAGCGCC" *
                "GAUGGUAGUGUGGGGUCUCCCCAUGCGAGAGUAGGGAACUGCCAGGCAU"
