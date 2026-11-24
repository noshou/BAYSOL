# tui/julia/app

The entry of the packaged app: `baysol`, one executable that `bysl pkg` builds with `juliac`. It is the launcher of `baysol-tui`, the command line (`baysol run`), what the interface starts for a fit (`baysol run-tui`) and the setup wizard (`baysol setup`). Nothing in it knows the checkout it was built in; it finds its files beside itself.

| file | what it does |
| ---- | ------------ |
| `baysol.jl` | the entry point and its commands (`tui`, `run`, `setup`, `version`) |
| `bundle.jl` | where the bundle is, the environment the other programs read, the threads, the start of the interface |
| `workload.jl` | build time only: runs the projects of `BAYSOL_WORKLOAD` and compiles the statements of `BAYSOL_STATEMENTS`, so a user's first fit does not compile |

Built and checked by `bysl pkg` (see `dev/README.md`).
