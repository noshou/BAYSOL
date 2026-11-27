# Platform

The one place that detects the operating system (`platform.jl` at the root of the
repository, the module `BAYSOL.Platform`). Every package of the repository includes the file
by its relative path, so each has its own copy under its own name (`Dev.Platform`,
`BAYSOLSetup.Platform`, `BAYSOLRun.Platform`). The guide, the cache layout and the rule for
contributors (no `Sys.iswindows`, `Sys.isapple`, `Sys.islinux` or `Sys.which` elsewhere) are
in the [development guide](../testing/dev.md#The-operating-system-module); the TypeScript
twin is `tui/src/core/environment.ts`.

```@autodocs
Modules = [BAYSOL.Platform]
```
