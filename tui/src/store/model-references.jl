# SPDX-License-Identifier: LGPL-3.0-or-later

# The reference curve of single models of a project run (`run_project`): what the fitting
# tests do for each atomic model of a deposited entry (the curve of the depositor's fit
# and the χ² it reports), read from `<project>/model-references.json`.

"""
The file of a project that gives single models a reference curve of their own and the
depositor's χ² (copied into the run folder like `model-settings.json`):
`{"<model>": {"tag", "software", "ref_chi2", "fit", "rescale"}}`, every key optional.

- `fit`: the file name of a curve of `reference-fit/` (`SASDCQ2_fit3.tsv`); the model's
    comparison figure draws it with the data and the MAP curve.
- `software`, `tag`: its label in the figure (`MultiFoXS 2-state fit3_model1`).
- `ref_chi2`: the depositor's χ² with its method (`"MultiFoXS 2-state 0.79"`), printed in
    the legend of that figure and as the `ref_chi2` row of the model's LOG.
- `rescale`: scale the curve to the measured one by least squares (a normalized fit).
"""
const MODEL_REFERENCES_FILE = "model-references.json"

"The keys of an entry of [`MODEL_REFERENCES_FILE`](@ref)."
const MODEL_REFERENCE_KEYS = (:tag, :software, :ref_chi2, :fit, :rescale)

"""
The table of a `model-references.json`, one `Dict` of the keys an entry gives for each
model, checked: text for `tag`, `software`, `ref_chi2` (a number is taken as its text)
and `fit`, a `Bool` for `rescale`. An entry that is not an object, a key that is not known
and a value of the wrong kind are skipped and described in the returned problems; the file
itself that cannot be read is one problem. Nothing is thrown.

# Returns
- `(table, problems)`: the model name => entry, and one line of text for each skipped part.
"""
function _read_model_references(path::AbstractString)
    table = Dict{String,Dict{Symbol,Any}}()
    problems = String[]
    label = basename(path)
    content = try
        _read_json(read(path, String))
    catch e
        e isa InterruptException && rethrow()
        push!(
            problems,
            "$label cannot be read: " *
            (e isa ArgumentError ? e.msg : first(split(sprint(showerror, e), '\n'))),
        )
        return table, problems
    end
    if !(content isa AbstractDict)
        push!(problems, "$label must hold an object with an entry for each model")
        return table, problems
    end
    for (model, entry) in content
        who = "$label, model $model"
        if !(entry isa AbstractDict)
            push!(problems, "$who: must be an object")
            continue
        end
        out = Dict{Symbol,Any}()
        for (k, v) in entry
            key = Symbol(k)
            if key == :rescale
                v isa Bool ? (out[key] = v) :
                push!(problems, "$who: rescale must be true or false")
            elseif key in MODEL_REFERENCE_KEYS
                if v isa AbstractString || v isa Real
                    isempty(strip(string(v))) || (out[key] = strip(string(v)))
                else
                    push!(problems, "$who: $key must be text")
                end
            else
                push!(problems, "$who: $key is not known and is ignored")
            end
        end
        isempty(out) || (table[String(model)] = out)
    end
    return table, problems
end

"""
`ref` scaled by the least-squares factor that brings it onto the measured curve (`q`, `I`):
the fit linearly interpolated at the measured q, `c = Σ I·f / Σ f²` over the points inside
its q range. The curve itself when no measured point is inside it.
"""
function _rescale_reference(ref::Reference, q::AbstractVector, I::AbstractVector)
    p = sortperm(ref.q)
    qf, If = ref.q[p], ref.I[p]
    num = den = 0.0
    for (x, y) in zip(q, I)
        (qf[1] ≤ x ≤ qf[end]) || continue
        j = clamp(searchsortedlast(qf, x), 1, length(qf) - 1)
        w = qf[j+1] > qf[j] ? (x - qf[j]) / (qf[j+1] - qf[j]) : 0.0
        f = If[j] * (1 - w) + If[j+1] * w
        num += y * f
        den += f^2
    end
    den > 0 || return ref
    return Reference(ref.name, qf, If .* (num / den))
end

"""
What the entry `entry` of a model gives the model's results: `(references, ref_chi2,
problems)`. `references` holds the curve of `fit` (the file `reference-fit-<fit>` of the run
folder `dir`, q divided by 10 when `q_scale` is 0.1) named `software tag` (the file's name
without both), rescaled onto the measured `data = (q, I)` with `rescale`; it is empty
without a `fit` or when the file cannot be read (a problem says why). `ref_chi2` is the
text or `nothing`. Nothing is thrown.
"""
function _model_reference(dir::AbstractString, model::AbstractString, entry, data, q_scale)
    problems = String[]
    refs = Reference[]
    chi2 = get(entry, :ref_chi2, nothing)
    fit = get(entry, :fit, nothing)
    if fit !== nothing
        path = joinpath(dir, RUN_REFERENCE_PREFIX * fit)
        try
            isfile(path) || throw(ArgumentError("$fit is not in reference-fit/"))
            ref = _read_reference(path; q_scale)
            get(entry, :rescale, false) && (ref = _rescale_reference(ref, data...))
            label = join(
                filter(!isempty, [get(entry, :software, ""), get(entry, :tag, "")]), " ",
            )
            isempty(label) && (label = ref.name)
            get(entry, :rescale, false) && (label *= " (rescaled)")
            push!(refs, Reference(label, ref.q, ref.I))
        catch e
            e isa InterruptException && rethrow()
            push!(
                problems,
                "model $model: the reference fit was skipped: " *
                (e isa ArgumentError ? e.msg : first(split(sprint(showerror, e), '\n'))),
            )
        end
    end
    return (; references = refs, ref_chi2 = chi2 === nothing ? nothing : String(chi2),
        problems)
end
