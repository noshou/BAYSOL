# SPDX-License-Identifier: LGPL-2.1-or-later

# Shared corpus of real biological sequences (protein/DNA/RNA)

# ---------------------------------------------------------------------------
# Protein (spans short/medium/long, and "regular" vs ionizable-residue-heavy)
# ---------------------------------------------------------------------------

"""
Hen egg-white lysozyme (UniProt P00698, mature chain, 129 aa; sequence from
Canfield 1963, "The Amino Acid Sequence of Egg White Lysozyme", J. Biol.
Chem. 238:2698-2707, doi:10.1016/S0021-9258(18)67888-3). Medium length;
moderately ionizable.
"""
const LYSOZYME =    "KVFGRCELAAAMKRHGLDNYRGYSLGNWVCAAKFESNFNTQATNRNTDGSTDYGILQINSRW" *
                    "WCNDGRTPGSRNLCNIPCSALLSSDITASVNCAKKIVSDGNGMNAWVAWRNRCKGTDVQAWIRGCRL"

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
