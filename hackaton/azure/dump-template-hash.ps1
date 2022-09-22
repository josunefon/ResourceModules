<#
.DESCRIPTION
    This PowerShell script retrieves all deployments from Azure Tenant, Subscriptions and Resource Groups. After that, an hash using SHA-256 algorithm
    is generated per each deployment using the resources block from the template used. The hashes will be stored in a Storage Account Table.

    Script is intended to be used within Azure Fuction App and requires the following app settings
    - storageAccountResourceGroup: The name of the Azure Resource Group where Storage Account is deployed.
    - storageAccountName: The name of the Storage Account which will be used to store the data/table.
    - storageAccountSubscriptionId: The Azure Subscription Id linked to the Storage Account where the data will be stored.
    - noTenantLevelTracking: Flag used when Tenant Level deployments are not needed.
    - noSubscriptionsLevelTracking: Flag used when Subscriptions Level deployments are not needed.
    - noResourceGroupsLevelTracking: Flag used when Resource Groups Level deployments are not needed.
#>

# Input bindings are passed in via param block.
param($Timer)

#region Helper functions

function Get-Subscriptions ($scope) {
    Write-Host "[Processing $scope] Starting" -Verbose
    $subscriptions = Get-AzSubscription -WarningAction SilentlyContinue
    return $subscriptions
}

function Invoke-StorageAccountDataAdd {

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)]
        [object] $StorageAccountSubscriptionId,
        [Parameter(Mandatory = $true)]
        [object] $TableObject,
        [Parameter(Mandatory = $true)]
        [array] $TableRows,
        [Parameter(Mandatory = $true)]
        [string] $Scope
    )

    Select-AzSubscription -SubscriptionId $StorageAccountSubscriptionId -WarningAction SilentlyContinue | Out-Null
    Write-Host "[Processing $Scope] Adding $($TableRows.Count) rows to Storage Account" -Verbose
    foreach ($row in $TableRows) {
        if (($row.hash).Length -ne 0) {
            New-StorageAccountTableRow -Table $TableObject -PartitionKey $row.deploymentId -DeploymentName $row.deploymentName -Hash $row.hash -Scope $Scope
        }
    }
}

#endregion

#region Init

Write-Host '[Preparation] Reading script parameters from env variables' -Verbose

$storageAccountName = $env:storageAccountName
$storageAccountResourceGroup = $env:storageAccountResourceGroup
$storageAccountSubscriptionId = $env:storageAccountSubscriptionId
$noTenantLevelTracking = [System.Convert]::ToBoolean($env:noTenantLevelTrackingString)
$noSubscriptionsLevelTracking = [System.Convert]::ToBoolean($env:noSubscriptionsLevelTracking)
$noResourceGroupsLevelTracking = [System.Convert]::ToBoolean($env:noResourceGroupsLevelTracking)

Write-Host '[Preparation] Parameters:' -Verbose
Write-Host "[Preparation]  - storageAccountName: $storageAccountName" -Verbose
Write-Host "[Preparation]  - storageAccountResourceGroup: $storageAccountResourceGroup" -Verbose
Write-Host "[Preparation]  - storageAccountSubscriptionId: $noTenantLevelTracking" -Verbose
Write-Host "[Preparation]  - noTenantLevelTracking: $noTenantLevelTracking" -Verbose
Write-Host "[Preparation]  - noSubscriptionsLevelTracking: $noSubscriptionsLevelTracking" -Verbose
Write-Host "[Preparation]  - noResourceGroupsLevelTracking: $noResourceGroupsLevelTracking" -Verbose

if ($noTenantLevelTracking -eq $true -and $noSubscriptionsLevelTracking -eq $true -and $noResourceGroupsLevelTracking -eq $true) {
    Write-Host '[Preparation] Please set the flags for tracking purposes. Exiting...' -Verbose
    return
}

#endregion

#region Importing modules

Write-Host '[Preparation] Loading modules' -Verbose

Import-Module module-tracker

#endregion

#region Create the Storage Table

Write-Host '[Preparation] Creating/retrieving storage account table object' -Verbose
Select-AzSubscription -SubscriptionId $storageAccountSubscriptionId -WarningAction SilentlyContinue | Out-Null
$tableObject = New-StorageAccountTable -StorageAccountName $storageAccountName -ResourceGroup $storageAccountResourceGroup -TableName 'AzureDeployments'

if (-not $tableObject) {
    Write-Host '[Preparation] storage account table object not available!' -Verbose
    return;
}
#endregion

#region Getting all Tenant deployments

if ($noTenantLevelTracking -eq $false) {
    $StartTime = $(Get-Date)

    $processedDeployments = 0
    try {
        Write-Host '[Processing tenant] Start' -Verbose
        $azDeployments = Get-AzTenantDeployment
        Write-Host "[Processing tenant] Processing $($azDeployments.Count) deployments" -Verbose

        foreach ($deployment in $azDeployments) {
            try {
                Save-AzTenantDeploymentTemplate -DeploymentName $deployment.DeploymentName -Force | Out-Null
            } catch {
                continue
            }
            $hash = Get-TemplateHash -TemplatePath "./$($deployment.DeploymentName).json"
            $tableRows += [PSCustomObject]@{
                deploymentName = $deployment.DeploymentName
                deploymentId   = $deployment.Id
                hash           = $hash
            }
            Remove-Item "./$($deployment.DeploymentName).json"
            $processedDeployments++
        }
    } catch {
        Write-Output "Error: $($_.Exception.Message)"
        continue
    }
    if ($tableRows.Count -gt 0) {
        Invoke-StorageAccountDataAdd -StorageAccountSubscriptionId $storageAccountSubscriptionId -TableObject $tableObject -TableRows $tableRows -Scope 'tenant'
    }
    $elapsedTime = $(Get-Date) - $StartTime
    $totalTime = '{0:HH:mm:ss}' -f ([datetime]$elapsedTime.Ticks)
    Write-Host "[Processing tenant] Done, Time spent $($totalTime)" -Verbose
} else {
    Write-Host '[Processing tenant] Tenant level tracking is disabled by selected flags' -Verbose
}

#endregion

#region Getting all Subscriptions deployments

if ($noSubscriptionsLevelTracking -eq $false) {
    $StartTime = $(Get-Date)
    $subscriptions = Get-Subscriptions -Scope 'subscription'
    $tableRows = @()

    $subCount = 0
    foreach ($sub in $subscriptions) {
        $subCount++
        Write-Host "[Processing subscription] Processing subscription $subCount/$($subscriptions.Count)" -Verbose
        Select-AzSubscription -SubscriptionId $sub -WarningAction SilentlyContinue | Out-Null

        $processedDeployments = 0
        try {
            $azDeployments = Get-AzDeployment
            Write-Host "[Processing subscription] Processing $($azDeployments.Count) deployments" -Verbose

            foreach ($deployment in $azDeployments) {
                try {
                    Save-AzDeploymentTemplate -DeploymentName $deployment.DeploymentName -Force | Out-Null
                } catch {
                    continue
                }
                $hash = Get-TemplateHash -TemplatePath "./$($deployment.DeploymentName).json"
                $tableRows += [PSCustomObject]@{
                    deploymentName = $deployment.DeploymentName
                    deploymentId   = $deployment.Id
                    hash           = $hash
                }
                Remove-Item "./$($deployment.DeploymentName).json"
                $processedDeployments++
            }
        } catch {
            Write-Output "Error: $($_.Exception.Message)"
            continue
        }
        break
    }
    if ($tableRows.Count -gt 0) {
        Invoke-StorageAccountDataAdd -StorageAccountSubscriptionId $storageAccountSubscriptionId -TableObject $tableObject -TableRows $tableRows -Scope 'subscription'
    }
    $elapsedTime = $(Get-Date) - $StartTime
    $totalTime = '{0:HH:mm:ss}' -f ([datetime]$elapsedTime.Ticks)

    Write-Host "[Processing subscription] Done, Time spent $($totalTime)" -Verbose
} else {
    Write-Host '[Processing subscription] Subscriptions level tracking is disabled by selected flags'
}

#endregion

#region Getting all Resource Group deployments per each Subscription

if ($noResourceGroupsLevelTracking -eq $false) {
    $StartTime = $(Get-Date)
    $subscriptions = Get-Subscriptions -Scope 'resourceGroup'
    $tableRows = @()
    $subCount = 0

    foreach ($sub in $subscriptions) {
        $subCount++
        Write-Host "[Processing resourceGroup] Processing subscription $subCount/$($subscriptions.Count)" -Verbose
        $resourceGroups = Get-AzResourceGroup
        Select-AzSubscription -SubscriptionId $sub -WarningAction SilentlyContinue | Out-Null

        $processedDeployments = 0
        $rgCount = 0
        foreach ($rg in $resourceGroups) {
            try {
                $rgCount++
                Write-Host "[Processing resourceGroup] Processing resoucre group $rgCount/$($resourceGroups.Count)" -Verbose
                $azDeployments = Get-AzResourceGroupDeployment -ResourceGroupName $rg.ResourceGroupName
                Write-Host "[Processing resourceGroup] Processing $($azDeployments.Count) deployments" -Verbose

                foreach ($deployment in $azDeployments) {
                    try {
                        Save-AzResourceGroupDeploymentTemplate -ResourceGroupName $rg.ResourceGroupName -DeploymentName $deployment.DeploymentName -Force -ErrorAction Stop | Out-Null
                    } catch {
                        continue
                    }
                    $hash = Get-TemplateHash -TemplatePath "./$($deployment.DeploymentName).json"
                    $tableRows += [PSCustomObject]@{
                        deploymentName = $deployment.DeploymentName
                        deploymentId   = $rg.ResourceId
                        hash           = $hash
                    }
                    Remove-Item "./$($deployment.DeploymentName).json"
                    $processedDeployments++
                }
            } catch {
                Write-Output "Error: $($_.Exception.Message)"
                continue
            }
        }
    }
    if ($tableRows.Count -gt 0) {
        Invoke-StorageAccountDataAdd -StorageAccountSubscriptionId $storageAccountSubscriptionId -TableObject $tableObject -TableRows $tableRows -Scope 'resourceGroup'
    }
    $elapsedTime = $(Get-Date) - $StartTime
    $totalTime = '{0:HH:mm:ss}' -f ([datetime]$elapsedTime.Ticks)

    Write-Host "[Processing resourceGroup] Done, Time spent $($totalTime)" -Verbose
} else {
    Write-Host '[Processing resourcGroup] Resource Groups level tracking is disabled by selected flags' -Verbose
}
#endregion
