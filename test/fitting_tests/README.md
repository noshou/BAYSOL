# Fitting tests

```
julia --project=test/fitting_tests test/fitting_tests/SASDMJ9/SASDMJ9.jl
```

Fixture data lives in `test/fixtures/<CASE>/` (e.g. `test/fixtures/SASDMJ9/`,
a real SASBDB entry: experimental curve + fitted model + source structure),
one directory per case, matching the fitting-test folder names above.
