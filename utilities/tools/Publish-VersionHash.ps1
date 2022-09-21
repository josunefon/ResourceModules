[CmdletBinding()]
param (
)

$ErrorActionPreference = "Stop"

Write-Verbose "Creating folder structure" -Verbose

if (!(Get-ChildItem -Path "fileHashes.json" -Erroraction SilentlyContinue)) {
    $null = New-Item -Path "fileHashes.json"
}
if (!(Get-Content -Path "fileHashes.json")) {
    Add-Content -Path "fileHashes.json" -Value "{}"
}

$null = New-Item "Publish-VersionHash-temp"
Set-Location "./Publish-VersionHash-temp"

Write-Verbose "Get GitHub release info" -Verbose
$response = Invoke-RestMethod -Method GET -Uri https://api.github.com/repos/Azure/ResourceModules/releases

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
    $null = New-Item "../Azure-ResourceModules-ARM"
    $moduleHashes = @{}

    foreach ($module in $filter[1..10]) {

        if ($module.FullName -match 'constructs') {
            Write-Verbose "Detected construct. Skipping..." -Verbose
            continue
        }
        #get providername
        $splitPath = ($module.FullName).split("Microsoft.")
        $path = ("Microsoft." + $splitPath[-1]).split("\deploy.bicep")[0].replace("\", "/")
        $jsonPath = $path.Replace("/", "-")

        Write-Verbose "[$($release.tag_name)] - Building '$path'.." -Verbose

        if (Get-Content "../Azure-ResourceModules-ARM/$jsonPath-deploy.json" -ErrorAction SilentlyContinue) {
            Write-Verbose "ARM file already exists. Skipping" -Verbose
            continue
        }

        az bicep build --file $module.FullName --outfile "../Azure-ResourceModules-ARM/$jsonPath-deploy.json" --no-restore

        #sort json alphabetically
        #lowercase json
        #remove trailing comma
        if (Get-Content -Path "../Azure-ResourceModules-ARM/$jsonPath-deploy.json" -ErrorAction SilentlyContinue) {
            $file = Get-Content -Path "../Azure-ResourceModules-ARM/$jsonPath-deploy.json" | ConvertFrom-Json
        }
        else {
            Write-Warning "File '$jsonPath-deploy.json' could not be found."
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

        $moduleHashes.Add($path, $encodedText)
    }

    Write-Verbose "Trying to read 'fileHashes.json'" -Verbose
    $existingHashes = Get-Content -Path "$PSScriptRoot/fileHashes.json" | ConvertFrom-Json

    $existingHashes | Add-Member "$($release.tag_name)" -Type "NoteProperty" -Value $moduleHashes
    "$PSScriptRoot/fileHashes.json"
    $existingHashes | ConvertTo-Json -Depth 99 | Out-File "$PSScriptRoot/fileHashes.json"

    Set-Location "$PSScriptRoot/Publish-VersionHash-temp"
}
