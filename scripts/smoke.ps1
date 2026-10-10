param(
    [string] $Version = '999.0.0',
    [Parameter(Mandatory)] [string] $RuntimeIdentifier,
    [switch] $AppleBundle
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path $root "artifacts/smoke/$RuntimeIdentifier"
$project = Join-Path $root 'tests/Consumer/Consumer.csproj'
New-Item -ItemType Directory -Force $work | Out-Null
$config = Join-Path $work 'NuGet.Config'
$localSource = [System.Security.SecurityElement]::Escape((Join-Path $root 'artifacts/packages'))
@"
<configuration>
  <packageSources><clear /><add key="local" value="$localSource" /><add key="nuget" value="https://api.nuget.org/v3/index.json" /></packageSources>
  <packageSourceMapping>
    <packageSource key="local"><package pattern="OfficeCLI" /></packageSource>
    <packageSource key="nuget"><package pattern="*" /></packageSource>
  </packageSourceMapping>
</configuration>
"@ | Set-Content $config -Encoding utf8

function Invoke-Dotnet([string] $Name, [string[]] $Arguments) {
    $log = Join-Path $work "$Name.log"
    & dotnet @Arguments *> $log
    if ($LASTEXITCODE -ne 0) {
        Get-Content $log -Tail 60 | Write-Host
        throw "dotnet $Name failed; see $log"
    }
    Write-Host "Completed $Name; log: $log"
}

function Invoke-OfficeCli([string] $Executable, [string[]] $Arguments) {
    $start = [System.Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $work
    $start.Environment['OFFICECLI_SKIP_UPDATE'] = '1'
    $start.Environment['OFFICECLI_NO_AUTO_INSTALL'] = '1'
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            throw "OfficeCLI timed out: $Arguments"
        }
        if (-not [System.Threading.Tasks.Task]::WaitAll(@($stdout, $stderr), 10000)) { throw 'OfficeCLI output streams did not close.' }
        $output = $stdout.Result + $stderr.Result
        if ($process.ExitCode -ne 0) { throw "OfficeCLI exited $($process.ExitCode): $Arguments`n$output" }
        return $output
    }
    finally { $process.Dispose() }
}

function Test-Output([string] $Directory, [bool] $IsSelfContained, [string] $ReferenceDirectory = $Directory) {
    $hostName = if ($RuntimeIdentifier.StartsWith('win-')) { 'officecli.exe' } else { 'officecli' }
    $executable = Join-Path $Directory $hostName
    foreach ($suffix in @('deps.json', 'runtimeconfig.json')) {
        $consumerHash = (Get-FileHash (Join-Path $ReferenceDirectory "Consumer.$suffix")).Hash
        $officeHash = (Get-FileHash (Join-Path $Directory "officecli.$suffix")).Hash
        if ($consumerHash -ne $officeHash) { throw "OfficeCLI $suffix does not match the final consumer output." }
    }
    $deps = Get-Content (Join-Path $Directory 'officecli.deps.json') -Raw | ConvertFrom-Json -AsHashtable
    if (-not $deps.libraries.ContainsKey('System.IO.Packaging/10.0.11')) { throw 'The consumer dependency override was lost.' }
    $runtime = Get-Content (Join-Path $Directory 'officecli.runtimeconfig.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($IsSelfContained -and ($runtime.runtimeOptions.ContainsKey('framework') -or -not $runtime.runtimeOptions.ContainsKey('includedFrameworks'))) {
        throw 'Published OfficeCLI must use the adjacent self-contained runtime.'
    }
    foreach ($name in @('officecli.dll', 'DocumentFormat.OpenXml.dll', 'DocumentFormat.OpenXml.Framework.dll', 'System.CommandLine.dll', 'System.IO.Packaging.dll')) {
        # A RID-less build directory may contain sibling RID build outputs from prior runs.
        $copies = @(Get-ChildItem $Directory -File -Filter $name)
        if ($IsSelfContained) { $copies = @(Get-ChildItem $Directory -Recurse -File -Filter $name) }
        if ($copies.Count -ne 1) { throw "Expected one shared copy of $name, found $($copies.Count)." }
    }

    Invoke-OfficeCli $executable @('--version') | Write-Host
    foreach ($extension in @('docx', 'xlsx', 'pptx')) {
        $document = Join-Path $work "smoke-$([guid]::NewGuid().ToString('N')).$extension"
        try {
            Invoke-OfficeCli $executable @('create', $document) | Out-Null
            if ($extension -eq 'docx') {
                Invoke-OfficeCli $executable @('add', $document, '/body', '--type', 'paragraph', '--prop', 'text=NuGet packaging smoke') | Out-Null
                $output = Invoke-OfficeCli $executable @('get', $document, '/body/p[1]')
                if ($output -notmatch 'NuGet packaging smoke') { throw 'Word resident edit/read failed.' }
            }
            Invoke-OfficeCli $executable @('close', $document) | Out-Null
            Invoke-OfficeCli $executable @('validate', $document) | Out-Null
        }
        finally {
            # Close any resident even when an earlier assertion fails.
            try { Invoke-OfficeCli $executable @('close', $document) | Out-Null } catch { Write-Warning $_ }
            if (Test-Path -LiteralPath $document) { Remove-Item -LiteralPath $document }
        }
    }
    Write-Host "OfficeCLI apphost, resident process and document smoke passed: $Directory"
}

# Isolated package cache prevents an older local draft from masking this package.
$packageCache = Join-Path $work "packages/$([guid]::NewGuid().ToString('N'))"
$common = @($project, '-c', 'Release', "-p:OfficeCliPackageVersion=$Version", "-p:RestoreConfigFile=$config", "-p:RestorePackagesPath=$packageCache", '-p:NuGetAudit=false', '--nologo')
Invoke-Dotnet 'build' (@('build') + $common)
$buildDir = Join-Path $root 'tests/Consumer/bin/Release/net10.0'
Test-Output $buildDir $false

$publish = Join-Path $work 'publish'
Invoke-Dotnet 'publish' (@('publish') + $common + @('-r', $RuntimeIdentifier, '--self-contained', 'true', '-p:PublishTrimmed=true', '-o', $publish))
Test-Output $publish $true

if ($AppleBundle) {
    if (-not $IsMacOS -or -not $RuntimeIdentifier.StartsWith('osx-')) { throw 'The Apple bundle smoke requires a macOS runner and an osx RID.' }
    $appleProject = Join-Path $root 'tests/MacConsumer/MacConsumer.csproj'
    $applePublish = Join-Path $work 'apple-publish'
    $appleCommon = @($appleProject, '-c', 'Release', "-p:OfficeCliPackageVersion=$Version", "-p:RestoreConfigFile=$config", "-p:RestorePackagesPath=$packageCache", '-p:NuGetAudit=false', '--nologo')
    Invoke-Dotnet 'publish-apple' (@('publish') + $appleCommon + @('-r', $RuntimeIdentifier, '-o', $applePublish))
    $bundleDirectory = (Get-Content (Join-Path $applePublish 'bundle-path.txt') -Raw).Trim()
    Test-Output (Join-Path $bundleDirectory 'Contents/MonoBundle') $true (Join-Path $applePublish 'smoke-reference')
}

Write-Host "Smoke passed for OfficeCLI $Version / $RuntimeIdentifier"
