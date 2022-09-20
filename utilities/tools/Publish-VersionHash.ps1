[CmdletBinding()]
param (
)

$ErrorActionPreference = "Stop"

Write-Verbose "Creating folder structure" -Verbose

if (!(Get-ChildItem -Path "fileHashes.json" -Erroraction SilentlyContinue)) {
    New-Item -Path "fileHashes.json"
}
if (!(Get-Content -Path "fileHashes.json")) {
    Add-Content -Path "fileHashes.json" -Value "{}"
}

mkdir "Publish-VersionHash-temp"
Set-Location "./Publish-VersionHash-temp"

Write-Verbose "Get GitHub release info" -Verbose
$response = Invoke-RestMethod -Method GET -Uri https://api.github.com/repos/Azure/ResourceModules/releases

foreach ($release in $response) {

    $existingHashes = Get-Content -Path "$PSScriptRoot/fileHashes.json" | ConvertFrom-Json

    if ($existingHashes."$($release.name)") {
        Write-Verbose "Found existing release in fileHashes.json. Skipping..." -Verbose
        continue
    }

    Write-Verbose "Download release zip for version '$($release.tag_name)' and unpack it" -Verbose
    Invoke-RestMethod -Uri $release.zipball_url -OutFile "$($release.tag_name).zip"
    Expand-Archive -LiteralPath "$($release.tag_name).zip" -DestinationPath "$($release.tag_name)"
    Set-Location "$($release.name)\Azure-ResourceModules-*\"

    Write-Verbose "Get all bicep files" -Verbose
    $filter = Get-ChildItem -Recurse -Filter "deploy.bicep"

    Write-Verbose "Create folder to store compiled ARM templates and respective hashes" -Verbose
    mkdir "../Azure-ResourceModules-ARM"
    $moduleHashes = @{}

    foreach ($module in $filter) {

        if ($module.FullName -match 'constructs') {
            Write-Verbose "Detected construct. Skipping..." -Verbose
            continue
        }
        $splitPath = ($module.FullName).split("\")
        $moduleName = $splitPath -match "Microsoft."
        $subModuleName = $splitPath[-2]

        #TODO: Modulepath is not correct if there is a sub-sub-module existent. (see Microsoft.Web/sites)
        Write-Verbose "[$($release.name)] - Building '$moduleName-$subModuleName'.." -Verbose

        if (Get-Content "../Azure-ResourceModules-ARM/$moduleName-$subModuleName-deploy.json" -ErrorAction SilentlyContinue) {
            Write-Verbose "ARM file already exists. Skipping" -Verbose
            continue
        }

        az bicep build --file $module.FullName --outfile "../Azure-ResourceModules-ARM/$moduleName-$subModuleName-deploy.json" --no-restore

        #sort json alphabetically
        #lowercase json
        #remove trailing comma
        if (Get-Content -Path "../Azure-ResourceModules-ARM/$moduleName-$subModuleName-deploy.json" -ErrorAction SilentlyContinue) {
            $file = Get-Content -Path "../Azure-ResourceModules-ARM/$moduleName-$subModuleName-deploy.json" | ConvertFrom-Json
        }
        else {
            Write-Warning "File '$moduleName-$subModuleName-deploy.json' could not be found."
        }

        $resources = $file.resources | ConvertTo-Json -Depth 99

        # create stream from template content
        $stringAsStream = [System.IO.MemoryStream]::new()
        $writer = [System.IO.StreamWriter]::new($stringAsStream)
        $writer.write($resources)
        $writer.Flush()
        $stringAsStream.Position = 0
        # Get template hash
        $encodedText = (Get-FileHash -InputStream $stringAsStream -Algorithm SHA256).Hash

        $moduleHashes.Add("$moduleName/$subModuleName", $encodedText)

        $moduleHashes
    }

    Write-Verbose "Trying to read 'fileHashes.json'" -Verbose
    $existingHashes = Get-Content -Path "$PSScriptRoot/fileHashes.json" | ConvertFrom-Json

    $existingHashes
    $existingHashes | Add-Member "$($release.tag_name)" -Type "NoteProperty" -Value $moduleHashes
    "$PSScriptRoot/fileHashes.json"
    $existingHashes | ConvertTo-Json -Depth 99 | Out-File "$PSScriptRoot/fileHashes.json"

    Set-Location "$PSScriptRoot/Publish-VersionHash-temp"
}
