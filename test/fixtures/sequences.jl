# SPDX-License-Identifier: LGPL-2.1-or-later
# Shared corpus of real biological sequences (protein/DNA/RNA)

# ---------------------------------------------------------------------------
# Protein (spans short/medium/long, and "regular" vs ionizable-residue-heavy)
# ---------------------------------------------------------------------------

"""
Human oxytocin, mature nonapeptide (UniProt P01178, oxytocin-neurophysin 1
proprotein, residues 3-11 of the precursor.
"""
const OXYTOCIN = "CYIQNCPLG"

"""
Human insulin A chain (UniProt P01308, INS_HUMAN, residues 90-110 of the
preproinsulin precursor). Short (21 aa), mildly ionizable (one E).
"""
const INSULIN_A = "GIVEQCCTSICSLYQLENYCN"

"""
Human insulin B chain (UniProt P01308, INS_HUMAN, residues 25-54 of the
preproinsulin precursor). Short (30 aa), "non-regular": ionizable-heavy
(H, E, K, R all present).
"""
const INSULIN_B = "FVNQHLCGSHLVEALYLVCGERGFFYTPKT"

"""
Hen egg-white lysozyme (UniProt P00698, mature chain, 129 aa). Medium
length; moderately ionizable.
"""
const LYSOZYME =    "KVFGRCELAAAMKRHGLDNYRGYSLGNWVCAAKFESNFNTQATNRNTDGSTDYGILQINSRW" *
                    "WCNDGRTPGSRNLCNIPCSALLSSDITASVNCAKKIVSDGNGMNAWVAWRNRCKGTDVQAWIRGCRL"

"""
Green fluorescent protein, *Aequorea victoria* (UniProt P42212, GFP_AEQVI,
full 238 aa mature chain). Long; "non-regular": ionizable-heavy
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
oligonucleotide (e.g. NEB/Thermo Fisher catalog; Messing 1983, "New M13
vectors for cloning", Methods Enzymol. 101). Short (18 nt) DNA oligo.
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
Science 185:435).
"""
const TRNA_PHE = "GCGGACUUAGCUCAGUUGGGAGAGCGCCAGACUGAAGAUCUGGAGGUCCUGUGUUCGAUCCACAGAGUUCGCA"

"""
*Escherichia coli* 5S ribosomal RNA (RNAcentral URS0000049E57; originally
sequenced by Brownlee, Sanger & Barrell 1968, "The sequence of 5S
ribosomal RNA", J. Mol. Biol. 34:379). Long (120 nt) RNA.
"""
const RRNA_5S = "UGCCUGGCGGCCGUAGCGCGGUGGUCCCACCUGACCCCAUGCCGAACUCAGAAGUGAAACGCCGUAGCGCC" *
                "GAUGGUAGUGUGGGGUCUCCCCAUGCGAGAGUAGGGAACUGCCAGGCAU"
