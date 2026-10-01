param([string] $Version = '999.0.0')

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$project = Join-Path $root '3rd/OfficeCLI/src/officecli/officecli.csproj'
$artifacts = Join-Path $root 'artifacts'
$RuntimeIdentifiers = @('win-x64', 'linux-x64', 'linux-arm64', 'osx-x64', 'osx-arm64')
New-Item -ItemType Directory -Force (Join-Path $artifacts 'logs') | Out-Null

function Invoke-Dotnet([string] $Name, [string[]] $Arguments) {
    $log = Join-Path $artifacts "logs/$Name.log"
    & dotnet @Arguments *> $log
    if ($LASTEXITCODE -ne 0) {
        Get-Content $log -Tail 60 | Write-Host
        throw "dotnet $Name failed; see $log"
    }
    Write-Host "Completed $Name; log: $log"
}

if ($Version -notmatch '^999\.[0-9]+\.[0-9]+$') { throw 'Use 999.YYYYMMDD.CI_RUN_NUMBER, or 999.0.0 for a local draft.' }
[xml] $upstream = Get-Content $project -Raw
if ($upstream.Project.PropertyGroup.TargetFramework -ne 'net10.0' -or $upstream.Project.PropertyGroup.AssemblyName -ne 'officecli') {
    throw 'The upstream target framework or assembly name changed; review the packaging contract.'
}

# Build the large managed project once. Platform apphosts contain no upstream code.
$common = @('-c', 'Release', '-p:SelfContained=false', '-p:PublishSingleFile=false', '-p:PublishTrimmed=false', '-p:UseAppHost=false', '-p:GenerateRuntimeConfigurationFiles=false', "-p:BaseOutputPath=$artifacts/upstream-bin/", "-p:BaseIntermediateOutputPath=$artifacts/upstream-obj/")
Invoke-Dotnet 'managed-build' (@('build', $project, '--nologo') + $common)
foreach ($rid in $RuntimeIdentifiers) {
    # Keep the SDK's RID-separated intermediate directories: sharing them can reuse
    # a previously generated apphost for another platform during incremental builds.
    Invoke-Dotnet "apphost-$rid" @('build', (Join-Path $root 'pack/AppHost/AppHost.csproj'), '-c', 'Release', '-r', $rid, '--nologo')
    # Copy only the apphost, never the stub DLL or its sidecars.
    $hostDir = Join-Path $artifacts "hosts/$rid"
    $hostName = if ($rid.StartsWith('win-')) { 'officecli.exe' } else { 'officecli' }
    New-Item -ItemType Directory -Force $hostDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $root "pack/AppHost/bin/Release/net10.0/$rid/$hostName") -Destination (Join-Path $hostDir $hostName)
}

# Pack the upstream project's own PackageReferences; never duplicate their versions here.
Invoke-Dotnet 'pack' (@('pack', $project, '--no-build', '--nologo', '-o', (Join-Path $artifacts 'packages')) + $common + @(
    '-p:PackageId=OfficeCLI', "-p:PackageVersion=$Version", '-p:IncludeSymbols=true', '-p:SymbolPackageFormat=snupkg',
    '-p:PackageReadmeFile=README.md', '-p:PackageLicenseFile=LICENSE', '-p:PackageProjectUrl=https://github.com/iOfficeAI/OfficeCLI',
    '-p:RepositoryUrl=https://github.com/iOfficeAI/OfficeCLI', '-p:Description=Unmodified OfficeCLI with shared .NET dependencies and platform apphosts.',
    "-p:DirectoryBuildTargetsPath=$(Join-Path $root 'pack/Pack.targets')", "-p:OfficeCliPackagingRoot=$root"
))

$commit = (& git -C (Join-Path $root '3rd/OfficeCLI') rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot determine upstream commit.' }
@{ packageVersion = $Version; upstreamVersion = [string]$upstream.Project.PropertyGroup.Version; upstreamCommit = $commit; runtimeIdentifiers = $RuntimeIdentifiers } |
    ConvertTo-Json | Set-Content (Join-Path $artifacts 'source.json') -Encoding utf8
Write-Host "Packed OfficeCLI $Version from upstream $commit"
