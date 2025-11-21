<#
.SYNOPSIS
    Module-wise Bicep Drift Detection Script
    - Exports Azure → Decompile → Compare → Generate module Bicep for drift
    - Safe for any deployment
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory=$true)]
    [string]$LocalRoot
)

# ------------------------------
# Local folders
# ------------------------------
$LocalModulesFolder  = Join-Path $LocalRoot "modules"
$LocalExistingFolder = Join-Path $LocalRoot "existing"

# ------------------------------
# Temporary folders
# ------------------------------
$TempRoot         = Join-Path $env:TEMP "bicep-drift"
$ExportJson        = Join-Path $TempRoot "export.json"
$ExportBicep       = Join-Path $TempRoot "export.bicep"
$SplitFolder       = Join-Path $TempRoot "split"
$UnsupportedFolder = Join-Path $TempRoot "unsupported"

# ------------------------------
# Output files
# ------------------------------
$SummaryFile = Join-Path $LocalRoot "drift-summary.txt"

# ------------------------------
# Prepare folders (do not delete local files)
# ------------------------------
foreach ($folder in @($TempRoot, $SplitFolder, $UnsupportedFolder)) {
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory $folder | Out-Null }
}

# ------------------------------
# 1. Export ARM Template (safe fallback)
# ------------------------------
Write-Host "`n=== Exporting Azure → ARM JSON ===" -ForegroundColor Cyan
try {
    az group export --name $ResourceGroup | Out-File $ExportJson -Encoding utf8
} catch {
    Write-Warning "Group export failed, falling back to per-resource export."
    $Resources = az resource list --resource-group $ResourceGroup | ConvertFrom-Json
    $Resources | ConvertTo-Json -Depth 10 | Out-File $ExportJson -Encoding utf8
}

# ------------------------------
# 2. Decompile to Bicep (supported resources)
# ------------------------------
Write-Host "`n=== Decompiling ARM → Bicep ===" -ForegroundColor Cyan
try {
    az bicep decompile --file $ExportJson --stdout | Out-File $ExportBicep -Encoding utf8
} catch {
    Write-Warning "Bicep decompile failed for some resources. They will be handled as placeholders."
}

# ------------------------------
# 3. Split decompiled Bicep into per-resource files
# ------------------------------
$Lines = Get-Content $ExportBicep -ErrorAction SilentlyContinue
$CurrName = ""; $CurrContent = ""
if ($Lines) {
    foreach ($Line in $Lines) {
        if ($Line -match "resource\s+([^\s]+)\s+'[^']+'\s*@") {
            if ($CurrName -ne "") {
                $OutFile = Join-Path $SplitFolder "$CurrName.bicep"
                $CurrContent.Trim() | Out-File $OutFile -Encoding utf8
            }
            $CurrName = $Matches[1]
            $CurrContent = $Line + "`n"
        } else {
            $CurrContent += $Line + "`n"
        }
    }
    if ($CurrName -ne "") {
        $OutFile = Join-Path $SplitFolder "$CurrName.bicep"
        $CurrContent.Trim() | Out-File $OutFile -Encoding utf8
    }
}

# ------------------------------
# 4. Detect added/changed/removed resources
# ------------------------------
$Added = @(); $Changed = @(); $Removed = @(); $Unsupported = @(); $ModuleDrift = @{}

# Find all local resources
$LocalFiles = Get-ChildItem $LocalModulesFolder -Filter *.bicep -Recurse
$LocalNames = $LocalFiles | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.FullName) }

# Process generated/exported Bicep
$GeneratedFiles = Get-ChildItem $SplitFolder -Filter *.bicep
foreach ($Gen in $GeneratedFiles) {
    $ResName = [IO.Path]::GetFileNameWithoutExtension($Gen.FullName)
    $LocalFileModule = Join-Path $LocalModulesFolder "$ResName.bicep"
    $LocalFileExisting = Join-Path $LocalExistingFolder "$ResName.bicep"
    $LocalFile = $null
    if (Test-Path $LocalFileModule) { $LocalFile = $LocalFileModule }
    elseif (Test-Path $LocalFileExisting) { $LocalFile = $LocalFileExisting }

    $GenContent = (Get-Content $Gen -Raw).Trim() -replace '\r\n', '\n' -replace '\s+\n', '\n'
    if ($LocalFile) {
        $LocalContent = (Get-Content $LocalFile -Raw).Trim() -replace '\r\n', '\n' -replace '\s+\n', '\n'
        if ($GenContent -ne $LocalContent) {
            $Changed += $ResName
            $ModuleDrift[$ResName] = $GenContent
        }
    } else {
        $Added += $ResName
        $ModuleDrift[$ResName] = $GenContent
    }
}

# Detect removed resources (present locally but missing in Azure)
foreach ($LocalName in $LocalNames) {
    $ExistsInAzure = $GeneratedFiles | Where-Object { $_.Name -eq $LocalName }
    if (-not $ExistsInAzure) {
        $Removed += $LocalName
        $ModuleDrift[$LocalName] = @"
//// REMOVED RESOURCE: $LocalName
resource $LocalName 'REMOVED' = {
  // This resource no longer exists in Azure
}
"@
    }
}

# ------------------------------
# 5. Generate per-module drift Bicep (only if drift exists)
# ------------------------------
if ($ModuleDrift.Count -gt 0) {
    foreach ($ResName in $ModuleDrift.Keys) {
        $Content = $ModuleDrift[$ResName]
        $OutFile = Join-Path $LocalModulesFolder "$ResName.drift.bicep"
        $Content | Out-File $OutFile -Encoding utf8
    }
    Write-Host "`n✅ Drift Bicep files created in: $LocalModulesFolder/*.drift.bicep" -ForegroundColor Yellow
} else {
    Write-Host "`n✨ No drift detected - no .drift.bicep files created" -ForegroundColor Green
}

# ------------------------------
# 6. Generate drift summary
# ------------------------------
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

REMOVED RESOURCES:
$(if ($Removed) { $Removed -join "`n" } else { "None" })

UNSUPPORTED RESOURCES:
$(if ($Unsupported) { $Unsupported -join "`n" } else { "None" })

COMMANDS TO INSPECT UNSUPPORTED RESOURCES:
$(if ($Unsupported) { $Unsupported | ForEach-Object { "az resource list --resource-group $ResourceGroup --resource-type $_" } } else { "None" })

"@

$Summary | Out-File $SummaryFile -Encoding utf8
Write-Host "`n📄 Drift summary written to: $SummaryFile" -ForegroundColor Yellow
Write-Host "`nDone. Script is safe and does NOT delete or modify resources."
