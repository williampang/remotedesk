param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [string]$VcpkgRoot = $(if ($env:VCPKG_ROOT) { $env:VCPKG_ROOT } else { 'C:\dev\vcpkg' }),

    [switch]$NoBackup,

    [string[]]$ExpectedTriplets = @('x64-windows', 'x64-windows-static')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Find-InstalledRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SearchRoot
    )

    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue(@($SearchRoot, 0))

    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $current = [string]$item[0]
        $depth = [int]$item[1]

        if (Test-Path (Join-Path $current 'vcpkg\info')) {
            return $current
        }

        if ($depth -ge 4) {
            continue
        }

        $children = Get-ChildItem -Path $current -Directory -ErrorAction SilentlyContinue
        foreach ($child in $children) {
            $queue.Enqueue(@($child.FullName, $depth + 1))
        }
    }

    throw "Could not find an installed root under '$SearchRoot'. Expected a directory containing 'vcpkg\\info'."
}

function Copy-Tree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$From,
        [Parameter(Mandatory = $true)]
        [string]$To
    )

    New-Item -ItemType Directory -Path $To -Force | Out-Null
    robocopy $From $To /E /COPY:DAT /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed with exit code $LASTEXITCODE"
    }
}

function Show-ImportSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstalledRoot,
        [Parameter(Mandatory = $true)]
        [string[]]$Triplets
    )

    $infoRoot = Join-Path $InstalledRoot 'vcpkg\info'
    $wanted = 'ffmpeg', 'libvpx', 'libyuv', 'opus', 'aom'

    Write-Host "Imported root: $InstalledRoot"
    foreach ($triplet in $Triplets) {
        $tripletRoot = Join-Path $InstalledRoot $triplet
        if (-not (Test-Path $tripletRoot)) {
            Write-Warning "Triplet '$triplet' is missing."
            continue
        }

        Write-Host "Triplet '$triplet' is present."
        foreach ($name in $wanted) {
            $pattern = '{0}_*_{1}.list' -f $name, $triplet
            $entry = Get-ChildItem -Path $infoRoot -Filter $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $entry) {
                Write-Host ("  OK  {0}" -f $entry.Name)
            } else {
                Write-Warning ("  Missing package marker for {0}:{1}" -f $name, $triplet)
            }
        }
    }
}

$resolvedSource = (Resolve-Path -Path $SourcePath).Path
$resolvedVcpkgRoot = (Resolve-Path -Path $VcpkgRoot).Path
$installedTarget = Join-Path $resolvedVcpkgRoot 'installed'
$temporaryExtract = $null

try {
    if (Test-Path $resolvedSource -PathType Leaf) {
        if ([System.IO.Path]::GetExtension($resolvedSource) -ne '.zip') {
            throw "Source file '$resolvedSource' is not a .zip archive."
        }

        $temporaryExtract = Join-Path ([System.IO.Path]::GetTempPath()) ("rustdesk-vcpkg-installed-" + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temporaryExtract -Force | Out-Null
        Expand-Archive -Path $resolvedSource -DestinationPath $temporaryExtract -Force
        $sourceInstalledRoot = Find-InstalledRoot -SearchRoot $temporaryExtract
    } else {
        $sourceInstalledRoot = Find-InstalledRoot -SearchRoot $resolvedSource
    }

    if (Test-Path $installedTarget) {
        if ($NoBackup) {
            Remove-Item -Path $installedTarget -Recurse -Force
        } else {
            $backupPath = '{0}.backup-{1}' -f $installedTarget, (Get-Date -Format 'yyyyMMdd-HHmmss')
            Move-Item -Path $installedTarget -Destination $backupPath
            Write-Host "Existing installed directory moved to: $backupPath"
        }
    }

    Copy-Tree -From $sourceInstalledRoot -To $installedTarget
    Show-ImportSummary -InstalledRoot $installedTarget -Triplets $ExpectedTriplets

    Write-Host ''
    Write-Host 'Import complete.'
    Write-Host ("Local installed root: {0}" -f $installedTarget)
    Write-Host 'If you open a new terminal, Cargo will continue using VCPKG_ROOT for the default installed path.'
} finally {
    if ($null -ne $temporaryExtract -and (Test-Path $temporaryExtract)) {
        Remove-Item -Path $temporaryExtract -Recurse -Force
    }
}