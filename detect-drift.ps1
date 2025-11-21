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
# 1. List ALL resources in resource group first
# ------------------------------
Write-Host "`n=== Listing all resources in resource group ===" -ForegroundColor Cyan
$AllAzureResources = az resource list --resource-group $ResourceGroup | ConvertFrom-Json
Write-Host "Found $($AllAzureResources.Count) resources in Azure" -ForegroundColor Green

# Display resource types for visibility
$ResourceTypes = $AllAzureResources | Select-Object -ExpandProperty type | Sort-Object -Unique
Write-Host "`nResource types found:"
$ResourceTypes | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }

# ------------------------------
# 2. Export ARM Template (safe fallback)
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
# 3. Decompile to Bicep (supported resources)
# ------------------------------
Write-Host "`n=== Decompiling ARM → Bicep ===" -ForegroundColor Cyan
$DecompileOutput = az bicep decompile --file $ExportJson --stdout 2>&1
$DecompileOutput | Out-File $ExportBicep -Encoding utf8

# Capture unsupported resources from stderr
$UnsupportedResources = @()
$DecompileOutput | Where-Object { $_ -match "WARNING.*not.*supported|unable to decompile" } | ForEach-Object {
    if ($_ -match "'([^']+)'" -or $_ -match "type '([^']+)'") {
        $UnsupportedResources += $Matches[1]
    }
}

# ------------------------------
# 4. Split decompiled Bicep into per-resource files
# ------------------------------
$Lines = Get-Content $ExportBicep -ErrorAction SilentlyContinue
$CurrName = ""; $CurrContent = ""
$ExportedResourceNames = @()
if ($Lines) {
    foreach ($Line in $Lines) {
        if ($Line -match "resource\s+([^\s]+)\s+'[^']+'\s*@") {
            if ($CurrName -ne "") {
                $OutFile = Join-Path $SplitFolder "$CurrName.bicep"
                $CurrContent.Trim() | Out-File $OutFile -Encoding utf8
                $ExportedResourceNames += $CurrName
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
        $ExportedResourceNames += $CurrName
    }
}

# ------------------------------
# 5. Detect added/changed/removed resources
# ------------------------------
$Added = @(); $Changed = @(); $Removed = @(); $Unsupported = $UnsupportedResources; $ModuleDrift = @{}

# Detect resources that exist in Azure but weren't exported/decompiled
$MissingFromExport = @()
foreach ($AzResource in $AllAzureResources) {
    $ResourceName = $AzResource.name
    $ResourceType = $AzResource.type
    
    # Check if this resource was successfully exported and decompiled
    $WasExported = $ExportedResourceNames -contains $ResourceName
    
    if (-not $WasExported) {
        $MissingFromExport += @{
            Name = $ResourceName
            Type = $ResourceType
            Id = $AzResource.id
        }
    }
}

if ($MissingFromExport.Count -gt 0) {
    Write-Host "`n⚠️ WARNING: $($MissingFromExport.Count) resource(s) exist in Azure but weren't exported:" -ForegroundColor Yellow
    $MissingFromExport | ForEach-Object {
        Write-Host "  - $($_.Name) [$($_.Type)]" -ForegroundColor Yellow
        $Unsupported += "$($_.Name) [$($_.Type)]"
    }
}

# Find all local resources (exclude .drift.bicep files)
$LocalFiles = Get-ChildItem $LocalModulesFolder -Filter *.bicep -Recurse | Where-Object { $_.Name -notmatch '\.drift\.bicep$' }
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
        # Don't add to ModuleDrift - new resources don't need drift files
    }
}

# Detect removed resources (present locally but missing in Azure)
foreach ($LocalName in $LocalNames) {
    $ExistsInAzure = $GeneratedFiles | Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $LocalName }
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
# 6. Generate per-module drift Bicep (only if drift exists)
# ------------------------------
if ($ModuleDrift.Count -gt 0) {
    foreach ($ResName in $ModuleDrift.Keys) {
        $Content = $ModuleDrift[$ResName]
        $OutFile = Join-Path $LocalModulesFolder "$ResName.drift.bicep"
        $Content | Out-File $OutFile -Encoding utf8
    }
    Write-Host "`n✅ Created $($ModuleDrift.Count) .drift.bicep file(s) for CHANGED/REMOVED resources" -ForegroundColor Yellow
} else {
    Write-Host "`n✨ No drift detected - no .drift.bicep files created" -ForegroundColor Green
}

# ------------------------------
# 7. Generate drift summary
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
