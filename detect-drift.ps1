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
$MissingResourcesFile = Join-Path $LocalRoot "missing-resources.txt"
$MissingResourcesBicepFile = Join-Path $LocalRoot "missing-resources.bicep"

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
$MissingLocally = @()

# Find all local resources (exclude .drift.bicep files)
$LocalFiles = Get-ChildItem $LocalModulesFolder -Filter *.bicep -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.drift\.bicep$' }
$LocalResourceDeclarations = @()
foreach ($file in $LocalFiles) {
    $lines = Get-Content $file.FullName
    foreach ($line in $lines) {
        if ($line -match "resource\\s+([a-zA-Z0-9_-]+)\\s+'([^']+)'") {
            $LocalResourceDeclarations += [PSCustomObject]@{
                Name = $Matches[1]
                Type = $Matches[2]
            }
        }
    }
}

Write-Host "`n=== Comparing Azure resources with local Bicep files (name AND type match required) ===" -ForegroundColor Cyan
Write-Host "Local Bicep resource declarations found: $($LocalResourceDeclarations.Count)" -ForegroundColor Gray

# Check each Azure resource against local files (name AND type must match)
foreach ($AzResource in $AllAzureResources) {
    $ResourceName = $AzResource.name
    $ResourceType = $AzResource.type
    $Found = $false
    foreach ($decl in $LocalResourceDeclarations) {
        if ($decl.Name -eq $ResourceName -and $decl.Type -eq $ResourceType) {
            $Found = $true
            break
        }
    }
    if (-not $Found) {
        $MissingLocally += @{
            Name = $ResourceName
            Type = $ResourceType
            Id = $AzResource.id
        }
    }
}

if ($MissingLocally.Count -gt 0) {
    Write-Host "`n🔍 MISSING IN LOCAL BICEP: $($MissingLocally.Count) Azure resource(s) have no local Bicep file (name AND type):" -ForegroundColor Magenta
    $MissingLocally | ForEach-Object {
        Write-Host "  ❌ $($_.Name) [$($_.Type)]" -ForegroundColor Magenta
    }
    Write-Host "`nThese resources exist in Azure but you don't have Bicep files for them in your modules folder." -ForegroundColor Yellow
}

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
    Write-Host "`n⚠️  NOT EXPORTED: $($MissingFromExport.Count) resource(s) exist in Azure but weren't exported by 'az group export':" -ForegroundColor Yellow
    $MissingFromExport | ForEach-Object {
        Write-Host "  - $($_.Name) [$($_.Type)]" -ForegroundColor Yellow
        $Unsupported += "$($_.Name) [$($_.Type)]"
    }
    Write-Host "`nThese may be child resources, unsupported types, or require manual export." -ForegroundColor Gray
}

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
# 7. Generate missing resources Bicep file
# ------------------------------
if ($MissingLocally.Count -gt 0) {
    $MissingBicepContent = @"
// ============================================
// MISSING RESOURCES IN LOCAL BICEP
// Generated: $(Get-Date)
// Resource Group: $ResourceGroup
// ============================================
// These resources exist in Azure but are missing from your local Bicep files.
// Add the ones you need to your modules folder.

"@

    foreach ($Missing in $MissingLocally) {
        $ResourceName = $Missing.Name
        $ResourceType = $Missing.Type
        $ResourceId = $Missing.Id
        
        # Try to get the resource details and generate Bicep
        try {
            $ResourceJson = az resource show --ids "$ResourceId" 2>$null | ConvertFrom-Json
            $ApiVersion = $ResourceJson.apiVersion
            if (-not $ApiVersion) {
                # Get latest API version for the resource type
                $ApiVersion = "2023-01-01" # fallback
            }
            
            $MissingBicepContent += @"

// ============================================
// Resource: $ResourceName
// Type: $ResourceType
// ============================================
resource $(($ResourceName -replace '[^a-zA-Z0-9]','')) '$ResourceType@$ApiVersion' = {
  name: '$ResourceName'
  location: resourceGroup().location
  // TODO: Add properties from Azure portal or use 'az resource show --ids $ResourceId'
  properties: {
    // Configure based on your requirements
  }
}

"@
        } catch {
            $MissingBicepContent += @"

// ============================================
// Resource: $ResourceName  
// Type: $ResourceType
// ============================================
// Error retrieving details. Use: az resource show --ids $ResourceId
resource $(($ResourceName -replace '[^a-zA-Z0-9]','')) '$ResourceType@2023-01-01' = {
  name: '$ResourceName'
  location: resourceGroup().location
  properties: {}
}

"@
        }
    }
    
    $MissingBicepContent | Out-File $MissingResourcesBicepFile -Encoding utf8
    Write-Host "`n📝 Missing resources Bicep template: $MissingResourcesBicepFile" -ForegroundColor Cyan
}

# ------------------------------
# 8. Generate drift summary
# ------------------------------
$Summary = @"
============================
BICEP DRIFT SUMMARY
Resource Group: $ResourceGroup
Generated: $(Get-Date)
============================

CHANGED RESOURCES (content differs):
$(if ($Changed) { $Changed -join "`n" } else { "None" })

ADDED RESOURCES (in generated split but not in local):
$(if ($Added) { $Added -join "`n" } else { "None" })

REMOVED RESOURCES (in local but not in Azure):
$(if ($Removed) { $Removed -join "`n" } else { "None" })

NOT EXPORTED (exist in Azure but 'az group export' failed):
$(if ($MissingFromExport) { $MissingFromExport | ForEach-Object { "$($_.Name) [$($_.Type)]" } | Out-String } else { "None" })

UNSUPPORTED RESOURCES (decompile warnings):
$(if ($Unsupported) { $Unsupported -join "`n" } else { "None" })

"@

$Summary | Out-File $SummaryFile -Encoding utf8

# Generate separate missing resources summary
if ($MissingLocally.Count -gt 0) {
    $MissingSummary = @"
============================
MISSING RESOURCES IN LOCAL BICEP
Resource Group: $ResourceGroup  
Generated: $(Get-Date)
============================

These $($MissingLocally.Count) resource(s) exist in Azure but have no corresponding Bicep file in your modules folder:

"@
    
    foreach ($Missing in $MissingLocally) {
        $MissingSummary += "❌ $($Missing.Name)`n   Type: $($Missing.Type)`n   ID: $($Missing.Id)`n`n"
    }
    
    $MissingSummary += @"

ACTION REQUIRED:
-----------------
1. Review the generated file: missing-resources.bicep
2. Copy the resource definitions you need to your modules folder
3. Customize the properties according to your requirements
4. Re-run this script to verify

NOTE: Child resources (like network interfaces for private endpoints) may be
automatically managed by their parent resources and don't need separate files.
"@
    
    $MissingSummary | Out-File $MissingResourcesFile -Encoding utf8
    Write-Host "📋 Missing resources summary: $MissingResourcesFile" -ForegroundColor Cyan
}
Write-Host "`n📄 Drift summary written to: $SummaryFile" -ForegroundColor Yellow
if ($MissingLocally.Count -gt 0) {
    Write-Host "📋 Missing resources list: $MissingResourcesFile" -ForegroundColor Yellow
    Write-Host "📝 Missing resources Bicep: $MissingResourcesBicepFile" -ForegroundColor Yellow
}
Write-Host "`nDone. Script is safe and does NOT delete or modify resources."
