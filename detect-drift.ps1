<#
.SYNOPSIS
    Drift detection for Bicep:
    Export Azure → Decompile → Split → Diff → Summaries + drift-changes.bicep
#>

param(
    [string]$ResourceGroup = "YOUR-RG-NAME",
    [string]$LocalRoot = "C:\IaC"
)

# Local folders
$LocalModulesFolder  = Join-Path $LocalRoot "modules"
$LocalExistingFolder = Join-Path $LocalRoot "existing"

# Temp folders
$TempRoot     = Join-Path $env:TEMP "bicep-drift"
$ExportJson   = Join-Path $TempRoot "export.json"
$ExportBicep  = Join-Path $TempRoot "export.bicep"
$SplitFolder  = Join-Path $TempRoot "split"

# Output artifacts
$SummaryFile  = Join-Path $LocalRoot "drift-summary.txt"
$DriftBicep   = Join-Path $LocalRoot "drift-changes.bicep"

# Clean & recreate temp
if (Test-Path $TempRoot) { Remove-Item $TempRoot -Recurse -Force }
New-Item -ItemType Directory $TempRoot | Out-Null
New-Item -ItemType Directory $SplitFolder | Out-Null

Write-Host "`n=== Exporting Azure → ARM JSON ===" -ForegroundColor Cyan
az group export --name $ResourceGroup | Out-File $ExportJson -Encoding utf8

Write-Host "`n=== Decompiling ARM → Bicep ===" -ForegroundColor Cyan
az bicep decompile --file $ExportJson --stdout |
    Out-File $ExportBicep -Encoding utf8

Write-Host "`n=== Splitting into individual resource files ===" -ForegroundColor Cyan

# Split resources into standalone files
$Lines = Get-Content $ExportBicep
$CurrName = ""
$CurrBlock = ""

foreach ($Line in $Lines) {
    if ($Line -match "resource\s+(\w+)\s+'?([^']+)'?\s*@") {

        if ($CurrName -ne "") {
            $OutFile = Join-Path $SplitFolder "$CurrName.bicep"
            $CurrBlock.Trim() | Out-File $OutFile -Encoding utf8
        }

        $CurrName = $Matches[1]
        $CurrBlock = $Line + "`n"
    }
    else {
        $CurrBlock += $Line + "`n"
    }
}

if ($CurrName -ne "") {
    $OutFile = Join-Path $SplitFolder "$CurrName.bicep"
    $CurrBlock.Trim() | Out-File $OutFile -Encoding utf8
}

# Drift tracking
$Added = @()
$Removed = @()
$Changed = @()
$DriftBicepLines = @()

Write-Host "`n=== Diffing against local Bicep ===" -ForegroundColor Cyan

$LocalAll = @(
    Get-ChildItem $LocalModulesFolder -Filter *.bicep |
    Select-Object -ExpandProperty BaseName
) + (
    Get-ChildItem $LocalExistingFolder -Filter *.bicep |
    Select-Object -ExpandProperty BaseName
)

$Exported = Get-ChildItem $SplitFolder -Filter *.bicep | Select-Object -ExpandProperty BaseName

# Detect Removed Resources
foreach ($LocalItem in $LocalAll) {
    if ($LocalItem -notin $Exported) {
        $Removed += $LocalItem

        $DriftBicepLines += @"
//// REMOVED RESOURCE: $LocalItem
resource $LocalItem 'REMOVED' = {
  // This resource no longer exists in Azure
}
"@
    }
}

# Detect Added + Changed
foreach ($GeneratedFile in Get-ChildItem $SplitFolder -Filter *.bicep) {

    $Name = [IO.Path]::GetFileNameWithoutExtension($GeneratedFile)
    $LocalFile = $null

    $ModFile = Join-Path $LocalModulesFolder "$Name.bicep"
    $ExistFile = Join-Path $LocalExistingFolder "$Name.bicep"

    if (Test-Path $ModFile) { $LocalFile = $ModFile }
    elseif (Test-Path $ExistFile) { $LocalFile = $ExistFile }
    else {
        # new resource
        $Added += $Name

        $Content = Get-Content $GeneratedFile -Raw
        $DriftBicepLines += @"
//// NEW RESOURCE FOUND: $Name
$Content

"@
        continue
    }

    # DIFF
    $Diff = git diff --no-index --color=none $LocalFile $GeneratedFile 2>&1

    if ($Diff.Trim().Length -gt 0) {
        $Changed += $Name

        $DriftBicepLines += @"
//// CHANGED RESOURCE: $Name
//// Only showing diff summary, not full resource

$Diff

"@
    }
}

# Write drift-summary.txt
$Summary = @"
============================
BICEP DRIFT SUMMARY
Resource Group: $ResourceGroup
Generated: $(Get-Date)
============================

ADDED RESOURCES:
$(if ($Added) { $Added -join "`n" } else { "None" })

REMOVED RESOURCES:
$(if ($Removed) { $Removed -join "`n" } else { "None" })

CHANGED RESOURCES:
$(if ($Changed) { $Changed -join "`n" } else { "None" })

"@
$Summary | Out-File $SummaryFile -Encoding utf8

# Write drift-changes.bicep
$DriftBicepLines -join "`n" | Out-File $DriftBicep -Encoding utf8

Write-Host "`n🔥 Drift summary written to: $SummaryFile" -ForegroundColor Yellow
Write-Host "🔥 Drift changes written to: $DriftBicep" -ForegroundColor Yellow
Write-Host "`nDone." -ForegroundColor Green
