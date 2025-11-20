<#
.SYNOPSIS
    Full Bicep drift detection including unsupported resource types
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
$UnsupportedFolder = Join-Path $TempRoot "unsupported"

# Outputs
$DriftBicep   = Join-Path $LocalRoot "drift-changes.bicep"
$SummaryFile  = Join-Path $LocalRoot "drift-summary.txt"

# Cleanup temp
if (Test-Path $TempRoot) { Remove-Item $TempRoot -Recurse -Force }
New-Item -ItemType Directory $TempRoot | Out-Null
New-Item -ItemType Directory $SplitFolder | Out-Null
New-Item -ItemType Directory $UnsupportedFolder | Out-Null

Write-Host "`n=== Exporting Azure → ARM JSON ===" -ForegroundColor Cyan

$ExportOutput = az group export --name $ResourceGroup 2>&1
$UnsupportedResources = @()

foreach ($line in $ExportOutput) {
    if ($line -match "ERROR: Could not get resources of the type '([^']+)'") {
        $UnsupportedResources += $Matches[1]
    }
}

# Save export JSON (supported resources)
az group export --name $ResourceGroup | Out-File $ExportJson -Encoding utf8

# Decompile supported resources
Write-Host "`n=== Decompiling ARM → Bicep (supported resources) ===" -ForegroundColor Cyan
az bicep decompile --file $ExportJson --out $ExportBicep

# Split supported resources into individual files
$Lines = Get-Content $ExportBicep
$CurrName = ""; $CurrContent = ""

foreach ($Line in $Lines) {
    if ($Line -match "resource\s+([^\s]+)\s+'[^']+'\s*@") {
        if ($CurrName -ne "") {
            $OutFile = Join-Path $SplitFolder "$CurrName.bicep"
            $CurrContent.Trim() | Out-File $OutFile -Encoding utf8
        }
        $CurrName = $Matches[1]; $CurrContent = $Line + "`n"
    } else {
        $CurrContent += $Line + "`n"
    }
}
if ($CurrName -ne "") {
    $OutFile = Join-Path $SplitFolder "$CurrName.bicep"
    $CurrContent.Trim() | Out-File $OutFile -Encoding utf8
}

# === Handle unsupported resources individually ===
$UnsupportedGenerated = @()

foreach ($ResType in $UnsupportedResources) {
    Write-Host "`nProcessing unsupported type: $ResType" -ForegroundColor Yellow
    $Resources = az resource list --resource-group $ResourceGroup --resource-type $ResType | ConvertFrom-Json
    foreach ($res in $Resources) {
        $ResName = $res.name
        $ResId = $res.id
        $TempJson = Join-Path $UnsupportedFolder "$ResName.json"

        # Export individual resource
        az resource show --ids $ResId | Out-File $TempJson -Encoding utf8

        # Decompile to Bicep
        $TempBicep = Join-Path $UnsupportedFolder "$ResName.bicep"
        az bicep decompile --file $TempJson --out $TempBicep

        # Save file path for drift comparison
        $UnsupportedGenerated += $TempBicep
    }
}

# === Compare all resources (supported + unsupported) ===
$DriftResources = @()
$Added = @()
$Changed = @()

$AllGeneratedFiles = Get-ChildItem $SplitFolder -Filter *.bicep | Select-Object -ExpandProperty FullName
$AllGeneratedFiles += $UnsupportedGenerated

foreach ($GeneratedFile in $AllGeneratedFiles) {
    $ResourceName = [IO.Path]::GetFileNameWithoutExtension($GeneratedFile)
    $LocalFile = $null
    $ModuleFile = Join-Path $LocalModulesFolder "$ResourceName.bicep"
    $ExistFile = Join-Path $LocalExistingFolder "$ResourceName.bicep"

    if (Test-Path $ModuleFile) { $LocalFile = $ModuleFile }
    elseif (Test-Path $ExistFile) { $LocalFile = $ExistFile }

    $GeneratedContent = Get-Content $GeneratedFile -Raw

    if ($LocalFile) {
        $LocalContent = Get-Content $LocalFile -Raw
        if ($GeneratedContent -ne $LocalContent) {
            $Changed += $ResourceName
            $DriftResources += $GeneratedContent
        }
    } else {
        $Added += $ResourceName
        $DriftResources += $GeneratedContent
    }
}

# Write drift-changes.bicep
if ($DriftResources.Count -eq 0) {
    "" | Out-File $DriftBicep -Encoding utf8
    Write-Host "`nNo added or changed resources detected." -ForegroundColor Green
} else {
    $DriftResources -join "`n`n" | Out-File $DriftBicep -Encoding utf8
    Write-Host "`n✅ Drift Bicep file generated: $DriftBicep" -ForegroundColor Yellow
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

CHANGED RESOURCES:
$(if ($Changed) { $Changed -join "`n" } else { "None" })

UNSUPPORTED RESOURCES (exported individually):
$(if ($UnsupportedResources) { $UnsupportedResources -join "`n" } else { "None" })
"@

$Summary | Out-File $SummaryFile -Encoding utf8
Write-Host "`n📄 Drift summary written to: $SummaryFile" -ForegroundColor Yellow
Write-Host "`nDone." -ForegroundColor Green
