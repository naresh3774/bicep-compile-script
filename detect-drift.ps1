<#
.SYNOPSIS
    Full Azure Bicep drift detection
    - Generates drift-changes.bicep for added/changed resources
    - Logs summary in drift-summary.txt including unsupported resources
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

# --- 1. Export ARM template ---
Write-Host "`n=== Exporting Azure → ARM JSON ===" -ForegroundColor Cyan
$ExportOutput = az group export --name $ResourceGroup 2>&1

$UnsupportedResources = @()
foreach ($line in $ExportOutput) {
    if ($line -match "ERROR: Could not get resources of the type '([A-Za-z0-9./@]+)'") {
        $UnsupportedResources += $Matches[1]
    }
}

# Save supported resources JSON
az group export --name $ResourceGroup | Out-File $ExportJson -Encoding utf8

# --- 2. Decompile supported resources ---
Write-Host "`n=== Decompiling ARM → Bicep (supported resources) ===" -ForegroundColor Cyan
az bicep decompile --file $ExportJson --force

# Split exported Bicep into per-resource files
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

# --- 3. Handle unsupported resources individually ---
$UnsupportedGenerated = @()
foreach ($ResType in $UnsupportedResources) {
    Write-Host "`nProcessing unsupported type: $ResType" -ForegroundColor Yellow
    $Resources = az resource list --resource-group $ResourceGroup --resource-type $ResType | ConvertFrom-Json
    foreach ($res in $Resources) {
        if (-not $res.id) { continue } # skip invalid
        $ResName = $res.name
        $TempJson = Join-Path $UnsupportedFolder "$ResName.json"

        az resource show --ids $res.id | Out-File $TempJson -Encoding utf8
        $TempBicep = Join-Path $UnsupportedFolder "$ResName.bicep"
        az bicep decompile --file $TempJson --force
        if (Test-Path $TempBicep) { $UnsupportedGenerated += $TempBicep }
    }
}

# --- 4. Compare all resources ---
$DriftResources = @(); $Added = @(); $Changed = @()
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

# --- 5. Write drift-changes.bicep ---
if ($DriftResources.Count -eq 0) {
    "" | Out-File $DriftBicep -Encoding utf8
    Write-Host "`nNo added or changed resources detected." -ForegroundColor Green
} else {
    $DriftResources -join "`n`n" | Out-File $DriftBicep -Encoding utf8
    Write-Host "`n✅ Drift Bicep file generated: $DriftBicep" -ForegroundColor Yellow
}

# --- 6. Write drift-summary.txt with commands for unsupported resources ---
$UnsupportedCommands = @()
foreach ($ResType in $UnsupportedResources) {
    $UnsupportedCommands += "az resource list --resource-group $ResourceGroup --resource-type $ResType"
}

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

UNSUPPORTED RESOURCES:
$(if ($UnsupportedResources) { $UnsupportedResources -join "`n" } else { "None" })

COMMANDS TO CHECK UNSUPPORTED RESOURCES:
$(if ($UnsupportedCommands) { $UnsupportedCommands -join "`n" } else { "None" })

"@

$Summary | Out-File $SummaryFile -Encoding utf8
Write-Host "`n📄 Drift summary written to: $SummaryFile" -ForegroundColor Yellow
Write-Host "`nDone." -ForegroundColor Green
