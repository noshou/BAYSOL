# FormFactor

X-ray atomic scattering factors, f(q, E) = f0(s) + f1(E) + i·f2(E) with s = q/(4π) in Å⁻¹.

The implementation is based on the Python package XrayDB.

Data:

- **waasmaier**: Waasmaier & Kirfel (1995) Gaussian coefficients for the non-resonant term f0. 211 species.
- **chantler**: Chantler FFAST (NIST) anomalous corrections f1/f2, spanning roughly 1.01 eV to 966 keV.


| Citation                                                                                                                                                                      | DOI                         |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------- |
| Waasmaier, D. & Kirfel, A. (1995). New analytical scattering-factor functions for free atoms and ions.*Acta Cryst.* A51, 416–431.                                            | 10.1107/S0108767394013292 |
| Chantler, C.T. (1995). Theoretical Form Factor, Attenuation, and Scattering Tabulation for Z = 1–92 from E = 1–10 eV to E = 0.4–1.0 MeV.*J. Phys. Chem. Ref. Data* 24, 71. | —                          |
| Chantler, C.T. (2000). Detailed Tabulation of Atomic Form Factors...*J. Phys. Chem. Ref. Data* 29, 597.                                                                       | —                          |

## Math

### f0: Waasmaier-Kirfel (non-resonant)

```
f0(s) = c + Σ_{i=1..5} a_i · exp(-b_i·s²),   s = q/(4π)  [Å⁻¹]
```

211 (c, a1..a5, b1..b5) rows, keyed by lowercase ion string ("fe3+", "o2-") or bare element ("fe"). Valid for 0 ≤ s ≤ S_MAX = 6.0 Å⁻¹; the fits go non-physical (some ionic c terms are large and negative, e.g.
fe3+'s c = -61.93) if extrapolated past that range, so f0 throws rather than extrapolating (f0("fe3+", S_MAX + eps) raises FormFactorError). 

At q → 0, f0 recovers the electron count: Z - charge for an ion, Z for a neutral atom (checked in tests to atol = 5e-3, the Cromer-Mann parameterization's own residual at s = 0).

### f1/f2: Chantler FFAST (anomalous / resonant)

- **f1**: interpolating **cubic spline with not-a-knot end conditions**, fitted to the local **7-point window** around the requested energy  (max(1, j-3):min(n, j+3), where j is the last grid point at or below the query. f1 is stored as
  f1_FFAST - Z + f_rel(3/5·CL) + f_NT
- **f2**: **linear interpolation in log-log space** over the same local window (values <1e-99 in magnitude are clamped to 1e-99 before taking the log, since the table can store an exact zero). f2 is used in log-log rather than cubic-spline form because it spans orders of magnitude across an absorption edge, whereas f1 changes sign through one.

# Tiering

Not every ion has both halves of the sum. [`compute_form_factors`](@ref BAYSOL.FormFactor.compute_form_factors) classifies each requested species into one of three tiers and logs anything short of a full resolution ([`form_factor_log`](@ref BAYSOL.FormFactor.form_factor_log)):

- **DUMMY**: no f0 entry at all for the species or its bare element.
- **F0-ONLY**: has f0 but no Chantler data for its element, or the requested energy falls outside that element's tabulated range (e.g. Pu, or Fe at 1 eV, below the Chantler floor); the row is real-valued (imag(f) == 0).
- **NEUTRAL**: no waasmaier entry for the exact charge state requested (e.g. "fe4+"), so the neutral atom's f0 is substituted.
- Anything not logged is **full**: both f0 and f1/f2 resolved for the requested ion and energy.

Ions are deduplicated on build, preserving first-seen order, so a batch like ["fe3+", "fe3+", "o2-", "fe3+"] produces one fe3+ row in t.tbl, while [`form_factors`](@ref BAYSOL.FormFactor.form_factors) still returns one output row per requested (possibly repeated) ion.
