# tui/julia

`BAYSOLRun`: the Julia side of the terminal interface and of the packaged app. It runs the fit of a whole project folder (`runProject`) in one process and leaves a run folder of plain files; it knows nothing of the terminal interface, which only starts it and reads the files.

| folder | what it holds |
| ------ | ------------- |
| [`src/`](src/README.md) | the `BAYSOLRun` module: `runProject`, the command line, and the readers of the project's JSON files |
| [`app/`](app/README.md) | the entry of the packaged `baysol` executable (built by `bysl pkg` with `juliac`) |

The environment (`Project.toml`) depends on `BAYSOL` (the repository root) and `BAYSOLSetup` (`setup-wizard/`) through `[sources]`, and on nothing else but the standard library. It has no Conda environment: the Python tools are frozen into `baysol-pytools` by `bysl pkg`.

```bash
julia --project=tui/julia -e 'using BAYSOLRun'     # precompiles it
```
