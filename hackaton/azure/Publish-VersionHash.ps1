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

$storageUri = "https://$StorageAccountName.blob.core.windows.net/$StorageAccountContainerName/fileHashes.json?$StorageAccountSasToken"

Import-Module ./hackaton/azure/module-tracker.psm1

Write-Verbose "Trying to download existing hash file" -Verbose
if (Get-AzStorageBlobContent -AbsoluteUri $storageUri -Destination "fileHashes.json" -Force) {
    <# Action to perform if the condition is true #>
}
$null = Get-AzStorageBlobContent -AbsoluteUri $storageUri -Destination "fileHashes.json" -Force

Write-Verbose "Creating folder structure" -Verbose

if (!(Get-ChildItem -Path "fileHashes.json" -Erroraction SilentlyContinue)) {
    $null = New-Item -Path "fileHashes.json"
}
if (!(Get-Content -Path "fileHashes.json")) {
    Add-Content -Path "fileHashes.json" -Value "{}"
}

$null = New-Item "Publish-VersionHash-temp" -ItemType Directory
Set-Location "./Publish-VersionHash-temp"

Write-Verbose "Get GitHub release info" -Verbose
$response = Invoke-RestMethod -Method GET -Uri https://api.github.com/repos/Azure/ResourceModules/releases
Write-Output "Found the following release tags:"
$response.tag_name


if ($ReleaseTag) {
    Write-Verbose "Release tag '$ReleaseTag' has been provided, only processing this release." -Verbose
    $response = Invoke-RestMethod -Method GET -Uri https://api.github.com/repos/Azure/ResourceModules/releases/tags/$ReleaseTag
}
else {
    Write-Verbose "No specific release tag has been provided, processing all available releases." -Verbose
}

foreach ($release in $response) {

    $existingHashes = Get-Content -Path "$PSScriptRoot/fileHashes.json" | ConvertFrom-Json

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
    $moduleHashes = @{}

    $totalModuleCount = $filter.Count
    $count = 0

    foreach ($module in $filter) {
        $count++

        if ($module.FullName -match 'constructs') {
            Write-Verbose "Detected construct. Skipping..." -Verbose
            continue
        }
        #get providername
        $splitPath = ($module.FullName).split("Microsoft.")
        $path = ("Microsoft." + $splitPath[-1]).split("\deploy.bicep")[0].replace("\", "/")
        $jsonPath = $path.Replace("/", "-")

        Write-Verbose "[$($release.tag_name)] - [$count/$totalModuleCount] - Building '$path'.." -Verbose
        if (Get-Content "../Azure-ResourceModules-ARM/$jsonPath-deploy.json" -ErrorAction SilentlyContinue) {
            Write-Verbose "ARM file already exists. Skipping" -Verbose
            continue
        }
        az bicep build --file $module.FullName --outfile "../Azure-ResourceModules-ARM/$jsonPath-deploy.json" --no-restore --only-show-errors
        if (Get-Content -Path "../Azure-ResourceModules-ARM/$jsonPath-deploy.json" -ErrorAction SilentlyContinue) {
            $encodedText = Get-TemplateHash -TemplatePath "../Azure-ResourceModules-ARM/$jsonPath-deploy.json"
        }
        else {
            Write-Warning "File '$jsonPath-deploy.json' could not be found."
        }
        $moduleHashes.Add($path, $encodedText)
    }

    Write-Verbose "Trying to read 'fileHashes.json'" -Verbose
    $existingHashes = Get-Content -Path "$PSScriptRoot/fileHashes.json" | ConvertFrom-Json

    $existingHashes | Add-Member "$($release.tag_name)" -Type "NoteProperty" -Value $moduleHashes
    "$PSScriptRoot/fileHashes.json"
    $existingHashes | ConvertTo-Json -Depth 100 | Out-File "$PSScriptRoot/fileHashes.json"

    Set-Location "$PSScriptRoot/Publish-VersionHash-temp"
}
Set-Location $PSScriptRoot
Remove-Item "./Publish-VersionHash-temp" -Recurse -Force

Write-Verbose "Upload file to blob storage" -Verbose
$storageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -SasToken $StorageAccountSasToken
$null = Set-AzStorageBlobContent -File "./fileHashes.json" -Container $StorageAccountContainerName -Context $storageContext -Force
