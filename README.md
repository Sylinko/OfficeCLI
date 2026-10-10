# OfficeCLI NuGet packaging

This repository packages the **unmodified** [iOfficeAI/OfficeCLI](https://github.com/iOfficeAI/OfficeCLI)
submodule for applications that run the CLI as a child process. The package ID is
`OfficeCLI`; binaries and their assembly versions retain the upstream identity.
It is a regular `PackageReference`, not a `dotnet tool` package.

## Package and runtime contract

The package contains `lib/net10.0/officecli.dll`, embedded upstream resources,
debug symbols in a separate `.snupkg`, and small SDK-generated apphosts for
`win-x64`, `linux-x64`, `linux-arm64`, `osx-x64` and `osx-arm64`. It declares the
upstream project's PackageReferences instead of bundling third-party DLLs or a
second .NET runtime. The large upstream project is compiled only once per pack;
a tiny separate project generates platform apphosts that load `officecli.dll`.
The tiny project's managed stub is never packaged.
Upstream build outputs are redirected to this wrapper's `artifacts` directory;
the source submodule does not need packaging changes or a custom gitignore.

`buildTransitive/OfficeCLI.targets` selects the apphost from `RuntimeIdentifier`
(or the SDK host RID for RID-less builds), copies it into executable consumers,
and preserves Unix executable permissions. Class libraries do not get launchers.
The consumer must target .NET 10 or newer and generate its dependency and runtime
configuration files. Single-file and NativeAOT consumers are rejected.

OfficeCLI and the consumer **share one output directory and dependency graph**.
The targets copy the consumer's SDK-generated `.deps.json` and `.runtimeconfig.json`
to the OfficeCLI sidecar names. The dependency manifest intentionally keeps the
consumer's root library and includes the OfficeCLI package; the apphost loads
`officecli.dll` as its entry assembly. A publish uses the final dependency manifest
after trimming, not the build manifest. This preserves NuGet dependency overrides
and selects either the installed runtime for framework-dependent builds or the
adjacent runtime for self-contained publishes. Both processes inherit the same
runtime configuration. Moving the launcher by itself is unsupported.

The CLI assembly is rooted for trimming because the consumer launches it without
static C# calls. Updating the consumer's other packages can still affect binary
compatibility with upstream dependencies; run the document/resident smoke after
such updates. An independent subdirectory containing another runtime or duplicate
managed dependencies would defeat the intended sharing.

## Consumer integration

```xml
<PackageReference Include="OfficeCLI" Version="[999.YYYYMMDD.RUN_NUMBER]" />
```

Launch the adjacent `officecli.exe` on Windows or `officecli` on Unix using
`ProcessStartInfo`. It must remain a real apphost: upstream uses
`Environment.ProcessPath` to spawn resident/watch processes. Set these variables
on the child process so embedded copies are managed by your application's release:

```text
OFFICECLI_NO_AUTO_INSTALL=1
OFFICECLI_SKIP_UPDATE=1
```

These disable automatic behavior; explicit `install`/update commands are not
blocked by the packaging layer. Do not expose those commands as maintenance of
the embedded copy. macOS consumers that put managed output into a Bundle must
copy the apphost and both sidecars to the same managed directory, apply `chmod +x`,
and sign the launcher using their own application identity and JIT entitlements.
The Apple SDK disables dependency manifest generation by default, so macOS
consumers must explicitly enable `GenerateDependencyFile`. For custom Bundle
copy targets, use `OfficeCliDepsFile` and `OfficeCliRuntimeConfig`: the package
sets these to the current build files or the final post-trimming publish files.
The runtime JSON comes from `ProjectRuntimeConfigFilePath`: the Apple SDK keeps
that generated file but removes it from the publish list when using `runtimeconfig.bin`.
The package itself does not provide Developer ID signing or notarization.

## Build and verify locally

Install .NET SDK 10.0.401 (or the version pinned in `global.json`) and PowerShell 7.
Initialize the source checkout with `git submodule update --init`.

```powershell
pwsh -File scripts/pack.ps1
pwsh -File scripts/smoke.ps1 -RuntimeIdentifier win-x64
```

Use your platform's supported RID for smoke. Packages appear under
`artifacts/packages`; command logs and exact upstream provenance are in
`artifacts/logs` and `artifacts/source.json`. `999.0.0` is a local draft only.
The smoke restores into a separate cache, exercises a dependency version override,
then runs RID-less framework-dependent build output and a trimmed self-contained
publish. It creates Word, Excel and PowerPoint documents and edits/reads a Word
document through upstream's resident child process.

The `osx-arm64` CI job also installs the macOS workload and publishes a
`net10.0-macos` consumer as an Apple `.app`, then runs the same CLI smoke from
`Contents/MonoBundle`. This covers Apple's runtime configuration conversion and
bundle layout, which a regular `net10.0` publish with an `osx` RID does not exercise.
To run it locally on a Mac with the matching Xcode and macOS workload, add
`-AppleBundle` to the smoke command.

## Publication and updates

1. Create the `Sylinko/OfficeCLI` GitHub repository and push this wrapper, including
   the upstream submodule's pinned commit. The submodule points to the upstream
   repository, not to a fork with packaging patches.
2. In `Sylinko/nuget-feed`, register `OfficeCLI` with source repository
   `Sylinko/OfficeCLI` and allow the original package ID. Merge that registration
   before running publication.
3. Configure the wrapper repository's Actions secret `SYLINKO_NUGET_FEED_TOKEN`.
   Follow the [feed token configuration](https://github.com/Sylinko/nuget-feed#readme):
   the fine-grained token needs access to `Sylinko/nuget-feed`, Metadata read,
   Contents read/write and Pull requests read/write. The producer's release is
   uploaded with its automatic `GITHUB_TOKEN` and `contents: write` permission.
4. Run **Publish NuGet** manually on `main`. It uses the workflow's original UTC
   creation date and CI run number to produce `999.YYYYMMDD.RUN_NUMBER`. The wrapper
   version is separate from upstream `Version`/AssemblyVersion. The package is
   built once, tested on all five supported RIDs, then published through
   `Sylinko/nuget-feed@v1`. This creates a GitHub Release and a feed PR.
5. Review/merge the feed PR, let the feed deploy, and pin the actual package version
   in Everywhere's central package management. Publication retries follow the
   shared action's current behavior; do not overwrite an already consumed version.

To update upstream, fetch a reviewed release tag/commit in `3rd/OfficeCLI`, check
it out, commit the new submodule pointer, and run publication again. Read
`artifacts/source.json` to identify the upstream version and commit in each run.
There is no scheduled update or automatic unreviewed upgrade.

## License

Upstream OfficeCLI is Apache-2.0. Every package contains the original `LICENSE`
and `THIRD-PARTY-NOTICES.txt`. Wrapper scripts and integration files are distributed
under the same license; the repository's LICENSE is copied from upstream.
