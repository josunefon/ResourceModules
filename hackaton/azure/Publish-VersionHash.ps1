<#
.SYNOPSIS
    This script will create a filehash from all modules that are within CARML and upload the result to a storage account. 
.DESCRIPTION
    This script will use a json file to store the hashes. It can update that file as well. The json file has to be located on a storage account.
    The script only works with a release package from GitHub. 
    Changes in between releases are not tracked.
.PARAMETER ReleaseTag

.PARAMETER StorageAccountName

.PARAMETER StorageAccountContainerName

.PARAMETER StorageAccountSasToken

.EXAMPLE
#>


[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [String]$ReleaseTag,

    [Parameter(Mandatory = $true)]
    [String]$StorageAccountName,

    [Parameter(Mandatory = $true)]
    [String]$StorageAccountContainerName,

    [Parameter(Mandatory = $true)]
    [String]$StorageAccountSasToken
)

$ErrorActionPreference = "Stop"

# declare where the hash file will be stored.
$storageUri = "https://$StorageAccountName.blob.core.windows.net/$StorageAccountContainerName/fileHashes.json?$StorageAccountSasToken"

# import local module that does the hashing.
Import-Module ./hackaton/azure/module-tracker.psm1

Write-Verbose "Trying to download existing hash file" -Verbose
try {
    $null = Get-AzStorageBlobContent -AbsoluteUri $storageUri -Destination "$PSScriptRoot/fileHashes.json" -Force
}
catch {
    Write-Error "Was not able to find file 'fileHashes.json' on storage account '$StorageAccountName' in container '$StorageAccountContainerName'"
}
    
Write-Verbose "Creating folder structure" -Verbose
if (!(Get-ChildItem -Path "$PSScriptRoot/fileHashes.json" -Erroraction SilentlyContinue)) {
    $null = New-Item -Path "$PSScriptRoot/fileHashes.json"
}
if (!(Get-Content -Path "$PSScriptRoot/fileHashes.json")) {
    Add-Content -Path "$PSScriptRoot/fileHashes.json" -Value "{}"
}

$null = New-Item "$PSScriptRoot/Publish-VersionHash-temp" -ItemType Directory
Set-Location "$PSScriptRoot/Publish-VersionHash-temp"

Write-Verbose "Get GitHub release info" -Verbose
$response = Invoke-RestMethod -Method GET -Uri https://api.github.com/repos/Azure/ResourceModules/releases
Write-Output "Found the following release tags:"
$response.tag_name

# switch which enables the user to either run the script only for a certain release tag or for all releases
if ($ReleaseTag) {
    Write-Verbose "Release tag '$ReleaseTag' has been provided, only processing this release." -Verbose
    $response = Invoke-RestMethod -Method GET -Uri https://api.github.com/repos/Azure/ResourceModules/releases/tags/$ReleaseTag
}
else {
    Write-Verbose "No specific release tag has been provided, processing all available releases." -Verbose
}

foreach ($release in $response[1..10]) {

    ls
    $PSScriptRoot
    # load the hash file
    $existingHashes = Get-Content -Path "$PSScriptRoot/fileHashes.json" | ConvertFrom-Json

    # if an existing release tag has been detected in the loaded file, the script will skip that release
    if ($existingHashes."$($release.tag_name)") {
        Write-Verbose "Found existing release in fileHashes.json. Skipping..." -Verbose
        continue
    }

    Write-Verbose "Download release zip for version '$($release.tag_name)' and unpack it" -Verbose
    Invoke-RestMethod -Uri $release.zipball_url -OutFile "$($release.tag_name).zip"
    Expand-Archive -LiteralPath "$($release.tag_name).zip" -DestinationPath "$($release.tag_name)"
    Set-Location "$($release.tag_name)\Azure-ResourceModules-*\"

    Write-Verbose "Get all bicep files" -Verbose
    $filter = Get-ChildItem -Recurse -Filter "deploy.bicep"

    Write-Verbose "Create folder to store compiled ARM templates and respective hashes" -Verbose
    $null = New-Item "../Azure-ResourceModules-ARM" -ItemType Directory

    # initialize the hashtable
    $moduleHashes = @{}

    # counter to display the hashing progress
    $totalModuleCount = $filter.Count
    $count = 0

    foreach ($module in $filter) {
        $count++

        # the newer CARML versions have constructs in addition to modules, we will not include those
        if ($module.FullName -match 'constructs') {
            Write-Verbose "Detected construct. Skipping..." -Verbose
            continue
        }

        # get the providername
        # split the full file path on a spot that is always the same
        $splitPath = ($module.FullName).split("Microsoft.")

        # add the splitted-off "Microsoft." back in and remove the "\deploy.bicep" from the end to get the full name of the module
        $path = ("Microsoft." + $splitPath[-1]).split("\deploy.bicep")[0].replace("\", "/")

        # since "\" are no good in file names we replace them with a "-" to receive the full name of the comipled ARM-json file
        $jsonPath = $path.Replace("/", "-")

        Write-Verbose "[$($release.tag_name)] - [$count/$totalModuleCount] - Building '$path'.." -Verbose

        # if the file was compiled before, skip the compilation process
        if (Get-Content "../Azure-ResourceModules-ARM/$jsonPath-deploy.json" -ErrorAction SilentlyContinue) {
            Write-Verbose "ARM file already exists. Skipping" -Verbose
            continue
        }

        # compilation step. does not print any linter warnings
        az bicep build --file $module.FullName --outfile "../Azure-ResourceModules-ARM/$jsonPath-deploy.json" --no-restore --only-show-errors

        # do the hashing if the ARM-json exists
        if (Get-Content -Path "../Azure-ResourceModules-ARM/$jsonPath-deploy.json" -ErrorAction SilentlyContinue) {
            $encodedText = Get-TemplateHash -TemplatePath "../Azure-ResourceModules-ARM/$jsonPath-deploy.json"
        }
        else {
            Write-Warning "File '$jsonPath-deploy.json' could not be found."
        }

        # add the full modulename and the hash to the existing hashtable 
        $moduleHashes.Add($path, $encodedText)
    }

    Write-Verbose "Trying to read 'fileHashes.json'" -Verbose
    $existingHashes = Get-Content -Path "$PSScriptRoot/fileHashes.json" | ConvertFrom-Json

    # write the hashtable that contains all modulenames + hashes for the specific version back to the json file that was loaded from the storage account
    $existingHashes | Add-Member "$($release.tag_name)" -Type "NoteProperty" -Value $moduleHashes
    "$PSScriptRoot/fileHashes.json"
    $existingHashes | ConvertTo-Json -Depth 100 | Out-File "$PSScriptRoot/fileHashes.json"

    Set-Location "$PSScriptRoot/hackaton/azure/Publish-VersionHash-temp"
}
# cleanup
Set-Location $PSScriptRoot
Remove-Item "$PSScriptRoot/hackaton/azure/Publish-VersionHash-temp" -Recurse -Force

# upload the local json file back to the storage account. The file on the storage account will be overwritten
Write-Verbose "Upload file to blob storage" -Verbose
$storageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -SasToken $StorageAccountSasToken
$null = Set-AzStorageBlobContent -File "$PSScriptRoot/fileHashes.json" -Container $StorageAccountContainerName -Context $storageContext -Force
