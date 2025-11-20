<#
.SYNOPSIS
    Detect Bicep drift and generate a Bicep file containing
    full resources that were added or changed in Azure.
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

# Output
$DriftBicep   = Join-Path $LocalRoot "drift-changes.bicep"

# Cleanup temp
if (Test-Path $TempRoot) { Remove-Item $TempRoot -Recurse -Force }
New-Item -ItemType Directory $TempRoot | Out-Null
New-Item -ItemType Directory $SplitFolder | Out-Null

Write-Host "`n=== Exporting Azure → ARM JSON ===" -ForegroundColor Cyan
az group export --name $ResourceGroup | Out-File $ExportJson -Encoding utf8

Write-Host "`n=== Decompiling ARM → Bicep ===" -ForegroundColor Cyan
az bicep decompile --file $ExportJson --stdout |
    Out-File $ExportBicep -Encoding utf8

Write-Host "`n=== Splitting exported Bicep into resources ===" -ForegroundColor Cyan

# Split the exported Bicep into per-resource files
$Lines = Get-Content $ExportBicep
$CurrName = ""
$CurrContent = ""

foreach ($Line in $Lines) {
    # Match resource declaration
    if ($Line -match "resource\s+([^\s]+)\s+'[^']+'\s*@") {
        if ($CurrName -ne "") {
            $OutFile = Join-Path $SplitFolder "$CurrName.bicep"
            $CurrContent.Trim() | Out-File $OutFile -Encoding utf8
        }
        $CurrName = $Matches[1]
        $CurrContent = $Line + "`n"
    }
    else {
        $CurrContent += $Line + "`n"
    }
}
# Write last block
if ($CurrName -ne "") {
    $OutFile = Join-Path $SplitFolder "$CurrName.bicep"
    $CurrContent.Trim() | Out-File $OutFile -Encoding utf8
}

Write-Host "`n=== Checking for added/changed resources ===" -ForegroundColor Cyan

$DriftResources = @()

foreach ($GeneratedFile in Get-ChildItem $SplitFolder -Filter *.bicep) {
    $ResourceName = [IO.Path]::GetFileNameWithoutExtension($GeneratedFile)

    # Try matching with local modules
    $LocalFile = $null
    $ModuleFile = Join-Path $LocalModulesFolder "$ResourceName.bicep"
    $ExistFile = Join-Path $LocalExistingFolder "$ResourceName.bicep"

    if (Test-Path $ModuleFile) { $LocalFile = $ModuleFile }
    elseif (Test-Path $ExistFile) { $LocalFile = $ExistFile }

    $GeneratedContent = Get-Content $GeneratedFile -Raw

    if ($LocalFile) {
        $LocalContent = Get-Content $LocalFile -Raw

        # Compare raw content
        if ($GeneratedContent -ne $LocalContent) {
            # Changed resource → add full block
            $DriftResources += $GeneratedContent
        }
        # else unchanged → skip
    }
    else {
        # Added resource → add full block
        $DriftResources += $GeneratedContent
    }
}

# Output drift-changes.bicep with full resource blocks
if ($DriftResources.Count -eq 0) {
    Write-Host "`nNo added or changed resources detected." -ForegroundColor Green
    "" | Out-File $DriftBicep -Encoding utf8
}
else {
    $DriftResources -join "`n`n" | Out-File $DriftBicep -Encoding utf8
    Write-Host "`n✅ Drift Bicep file generated: $DriftBicep" -ForegroundColor Yellow
}

Write-Host "`nDone." -ForegroundColor Green
