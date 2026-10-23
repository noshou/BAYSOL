# SPDX-License-Identifier: LGPL-3.0-or-later

"""
Explicit-hydrogen structure generation, through two external command-line tools run as
plain subprocesses in an isolated CondaPkg-managed Python environment: pdb2pqr
(hydrogen placement, [`resolve_hydrogens`](@ref)) and propka3 (per-residue pKa
prediction, [`propka_pKas`](@ref)).

How the titratable groups are protonated is a choice, a [`TitrationMethod`](@ref):
[`Propka`](@ref) (pdb2pqr's propka mode, pH-driven, protein only) or [`NoTitration`](@ref)
(no pH model). The force field pdb2pqr names the hydrogens and charges with is a second
choice, one of [`FORCE_FIELDS`](@ref) (`:parse`, except `:amber` for a nucleic acid
alone, see [`NUCLEIC_FORCE_FIELD`](@ref)).
Files are exchanged by path, in the store of
`MolecularStructure`.
"""
module Hydrogenator

using CondaPkg: CondaPkg
using FastClosures: @closure
using ..Runtime: Lazy, force, KeyedCache
using ..MolecularStructure:
    _store_dir, component, ComponentError, AMBER_NUCLEIC_NAMES, WATER_NAMES,
    STANDARD_NUCLEOTIDES, BACKBONE_ATOMS, BACKBONE_MIN, legacy_nucleotides_in_file,
    sanitized_copy, STANDARD_AMINO_ACIDS, amino_parent, _is_amino_type

# ---------------------------------------------------------------------------
#   Constants and shared types
# ---------------------------------------------------------------------------

"""
One lock per output path, so concurrent callers
for the same structure run the external tool once.
"""
const _PATH_LOCKS = KeyedCache{String,ReentrantLock}()

"Standard titratable protein groups for PROPKA."
const _STANDARD_GROUPS = Set(["ASP", "GLU", "CYS", "TYR", "HIS", "LYS", "ARG", "N+", "C-"])

"""
The force fields pdb2pqr accepts for `--ff`, which fix the hydrogen names and the
partial charges. PARSE has parameters for amino acids only; AMBER and CHARMM also have
nucleotides.
"""
const FORCE_FIELDS = (:amber, :charmm, :parse, :peoepb, :swanson, :tyl06)

"Force field of [`resolve_hydrogens`](@ref) when none is given."
const DEFAULT_FORCE_FIELD = :parse

"""
Force field [`hydrogenation_choice`](@ref) picks for a structure with nucleic acids and no
protein. PARSE and AMBER place the same hydrogens (pdb2pqr's `--pdb-output` does not
depend on the force field), but PARSE is not one-to-one on chimeras such as 246D (an RNA
with one deoxy-C, where it aborts on its charge check). Proteins keep PARSE because the
terminus flags `--neutraln`/`--neutralc` work only with it, and a mixed structure has them.
"""
const NUCLEIC_FORCE_FIELD = :amber

"""
Residue names that are in the dictionary as something else but are also Amber nucleotide
names: `RU` (ruthenium in the dictionary; uracil in Amber). They are tested by their atoms
like unknown names ([`hydrogenation_choice`](@ref)).
"""
const NUCLEIC_NAME_CLASH = ("RU",)

"""
How [`resolve_hydrogens`](@ref) decides the protonation state of the titratable groups.
Subtypes: [`Propka`](@ref), [`NoTitration`](@ref).
"""
abstract type TitrationMethod end

"""
    Propka()
    Propka(pKas)

pH-driven protonation by PROPKA: pdb2pqr runs with `--titration-state-method propka`, and
each chain's free termini are made neutral or charged from the PROPKA N+/C- pKa records
([`_terminus_groups`](@ref)). Protein only: PROPKA has no nucleotide model.

`pKas` are records as [`propka_pKas`](@ref) returns them **for the structure being
hydrogenated**, assumed and not re-verified; without them they are computed (and cached)
on demand.
"""
struct Propka <: TitrationMethod
    pKas::Union{Nothing,Vector{<:NamedTuple}}
end
Propka() = Propka(nothing)

"""
    NoTitration()

No pH model: pdb2pqr's own fixed protonation (charged termini, the force field's
default states) and no PROPKA run. The pH is only part of the cache key.
"""
struct NoTitration <: TitrationMethod end

"""
The CondaPkg environment's variables and the paths of the two tools run
from it, captured once. `CondaPkg.withenv` edits the process-wide `ENV`
for the duration of its block, which is not safe beside other tasks; the
subprocesses are given this environment explicitly instead (`setenv`).
"""
struct _CondaTools
    env     :: Dict{String,String}
    propka3 :: Union{Nothing,String}
    pdb2pqr :: Union{Nothing,String}
end

function _read_conda_tools()::_CondaTools
    CondaPkg.withenv() do
        _CondaTools(
            Dict{String,String}(ENV),
            CondaPkg.which("propka3"),
            CondaPkg.which("pdb2pqr"),
        )
    end
end

"""
The CondaPkg tools, resolved on first use (thread
safe, once per process; reset in `__init__`).
"""
const _CONDA = Ref(Lazy{_CondaTools}(_read_conda_tools))

__init__() = (_CONDA[] = Lazy{_CondaTools}(_read_conda_tools))

_path_lock(path::AbstractString) = get!(ReentrantLock, _PATH_LOCKS, String(path))

"""
The lines of a tool's captured standard error `path` that explain a failure (`ValueError`,
`RuntimeError`, `CRITICAL`, `non-integer charge`, `Giving up`, `Error`), the last
`n` of them, as a suffix for an error message (`""` when there is none or the file is
missing).
"""
function _stderr_tail(path::AbstractString, n::Integer = 8)::String
    isfile(path) || return ""
    keep = filter(
        l -> occursin(
            r"ValueError|RuntimeError|CRITICAL|non-integer charge|Giving up|Error",
            l,
        ),
        readlines(path),
    )
    isempty(keep) && return ""
    return "\n  tool output (last " * string(min(n, length(keep))) *
           " relevant lines):\n    " *
           join(strip.(last(keep, n)), "\n    ")
end

include("Propka.jl")
include("Pdb2pqr.jl")
include("Modified.jl")
include("ChainEnds.jl")
include("Balance.jl")
include("Content.jl")

export propka_pKas, PropkaError, resolve_hydrogens, Pdb2pqrError,
    TitrationMethod, Propka, NoTitration, FORCE_FIELDS, DEFAULT_FORCE_FIELD

end # module
