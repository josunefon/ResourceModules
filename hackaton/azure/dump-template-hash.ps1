<#
.DESCRIPTION
    This PowerShell script retrieves all deployments from Azure Tenant, Subscriptions and Resource Groups. After that, an hash using SHA-256 algorithm
    is generated per each deployment using the resources block from the template used. The hashes will be stored in a Storage Account Table.

.PARAMETER resourceGroup
    The name of the Azure Resource Group where Storage Account is deployed.

.PARAMETER storageAccount
    The name of the Storage Account which will be used to store the data/table.

.PARAMETER storageSubscriptionId
    The Azure Subscription Id linked to the Storage Account where the data will be stored.

.PARAMETER noTenantLevelTracking
    Flag used when Tenant Level deployments are not needed.

.PARAMETER noSubscriptionsLevelTracking
    Flag used when Subscriptions Level deployments are not needed.

.PARAMETER noResourceGroupsLevelTracking
    Flag used when Resource Groups Level deployments are not needed.

.EXAMPLE
    $parameters = @{
        resourceGroup = "wiki"
        storageAccount = "Welcome"
        storageSubscriptionId = "https://github.com/isd-product-innovation/azure-landing-zone-platform.wiki.git"
        GitHubRepositoryName = "azure-landing-zone-platform"
    }

    .\dump-template-hash.ps1 @parameters
#>

[CmdletBinding()]
Param (
    [Parameter(Mandatory = $true)]
    [String] $resourceGroup,

    [Parameter(Mandatory = $true)]
    [String] $storageAccount,

    [Parameter(Mandatory = $true)]
    [String] $storageSubscriptionId,

    [Parameter(Mandatory = $false)]
    [Switch] $noTenantLevelTracking,

    [Parameter(Mandatory = $false)]
    [Switch] $noSubscriptionsLevelTracking,

    [Parameter(Mandatory = $false)]
    [Switch] $noResourceGroupsLevelTracking
)

#region Importing modules
Remove-Module -Name module-tracker -Force -ErrorAction SilentlyContinue
Import-Module -Name ./module-tracker.psm1

if (Get-Module | Where-Object { $_.Name -eq 'AzTable' }) {
    Write-Host 'Module AzTable is already imported.'
} else {
    # If module is not imported, but available on disk then import
    if (Get-Module -ListAvailable | Where-Object { $_.Name -eq 'AzTable' }) {
        Import-Module 'AzTable' -Verbose
    } else {
        # If module is not imported, not available on disk, but is in online gallery then install and import
        if (Find-Module -Name 'AzTable' | Where-Object { $_.Name -eq 'AzTable' }) {
            Install-Module -Name 'AzTable' -Force -Verbose -Scope CurrentUser -Repository PSGallery
            Import-Module 'AzTable' -Verbose
        } else {
            # If the module is not imported, not available and not in the online gallery then abort
            Write-Host 'Module AzTable not imported, not available and not in an online gallery, exiting.'
            EXIT 1
        }
    }
}
#endregion

if ($noTenantLevelTracking -eq $true -and $noSubscriptionsLevelTracking -eq $true -and $noResourceGroupsLevelTracking -eq $true) {
    Write-Output 'Please remove the flags for tracking purposes.'
} else {
    #region Create the Storage Table
    Select-AzSubscription -SubscriptionId $storageSubscriptionId
    $tableObject = New-StorageAccountTable -StorageAccountName $storageAccount -ResourceGroup $resourceGroup -TableName 'AzureDeployments'
    #endregion

    #region Getting all Tenant deployments
    if ($noTenantLevelTracking -eq $false) {
        $StartTime = $(Get-Date)

        $processedDeployments = 0
        try {
            $azDeployments = Get-AzTenantDeployment

            foreach ($deployment in $azDeployments) {
                try {
                    Save-AzDeploymentTemplate -DeploymentName $deployment.DeploymentName -Force | Out-Null
                } catch {
                    continue
                }
                $hash = Get-TemplateHash -TemplatePath "./$($deployment.DeploymentName).json"
                New-StorageAccountTableRow -Table $tableObject -PartitionKey $deployment.Id -DeploymentName $deployment.deploymentName -Hash $hash -Scope 'tenant'
                Remove-Item "./$($deployment.DeploymentName).json"
                $processedDeployments++
            }
        } catch {
            Write-Output "Error: $($_.Exception.Message)"
            continue
        }
        $elapsedTime = $(Get-Date) - $StartTime
        $totalTime = '{0:HH:mm:ss}' -f ([datetime]$elapsedTime.Ticks)

        Write-Output "Processed Tenant deployments: $($processedDeployments), Time spent $($totalTime)"
    } else {
        Write-Output 'Tenant level tracking is disabled by selected flags'
    }
    #endregion

    #region Getting all Subscriptions deployments
    if ($noSubscriptionsLevelTracking -eq $false) {
        $StartTime = $(Get-Date)
        #$subscriptions = Get-AzSubscription
        $subscriptions = @('ed29c799-3b06-4306-971a-202c3c2d29a9', 'ad17e0fd-d65e-4c34-9c69-aeb86ae4c671')
        $tableRows = @()

        foreach ($sub in $subscriptions) {
            #Select-AzSubscription -SubscriptionId $sub.Id
            Select-AzSubscription -SubscriptionId $sub

            $processedDeployments = 0
            try {
                $azDeployments = Get-AzDeployment

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
        }
        Select-AzSubscription -SubscriptionId $storageSubscriptionId
        foreach ($row in $tableRows) {
            if (($row.hash).Length -ne 0) {
                New-StorageAccountTableRow -Table $tableObject -PartitionKey $row.deploymentId -DeploymentName $row.deploymentName -Hash $row.hash -Scope 'subscription'
            } else {
                Write-Output "Hash is null for $($row.deploymentName)"
            }
        }
        $elapsedTime = $(Get-Date) - $StartTime
        $totalTime = '{0:HH:mm:ss}' -f ([datetime]$elapsedTime.Ticks)

        Write-Output "Processed Subscriptions deployments: $($processedDeployments), Time spent $($totalTime)"
    } else {
        Write-Output 'Subscriptions level tracking is disabled by selected flags'
    }
    #endregion

    #region Getting all Resource Group deployments per each Subscription
    if ($noResourceGroupsLevelTracking -eq $false) {
        $StartTime = $(Get-Date)
        $subscriptions = @('ed29c799-3b06-4306-971a-202c3c2d29a9', 'ad17e0fd-d65e-4c34-9c69-aeb86ae4c671')
        $tableRows = @()

        foreach ($sub in $subscriptions) {
            #Select-AzSubscription -SubscriptionId $sub.Id
            $resourceGroups = Get-AzResourceGroup
            Select-AzSubscription -SubscriptionId $sub

            $processedDeployments = 0
            foreach ($rg in $resourceGroups) {
                try {
                    $azDeployments = Get-AzResourceGroupDeployment -ResourceGroupName $rg.ResourceGroupName

                    foreach ($deployment in $azDeployments) {
                        #exporting the deployment template object
                        try {
                            Save-AzResourceGroupDeploymentTemplate -ResourceGroupName $rg.ResourceGroupName -DeploymentName $deployment.DeploymentName -Force -ErrorAction Stop | Out-Null
                        } catch {
                            continue
                        }
                        #Generating hash value
                        $hash = Get-TemplateHash -TemplatePath "./$($deployment.DeploymentName).json"
                        #Adding results to object
                        $tableRows += [PSCustomObject]@{
                            deploymentName = $deployment.DeploymentName
                            deploymentId   = $rg.ResourceId
                            hash           = $hash
                        }
                        #Removing temporal json file
                        Remove-Item "./$($deployment.DeploymentName).json"
                        $processedDeployments++
                    }
                } catch {
                    Write-Output "Error: $($_.Exception.Message)"
                    continue
                }
            }
        }
        Select-AzSubscription -SubscriptionId $storageSubscriptionId
        foreach ($row in $tableRows) {
            New-StorageAccountTableRow -Table $tableObject -PartitionKey $row.deploymentId -DeploymentName $row.deploymentName -Hash $row.hash -Scope 'resourceGroup'
        }
        $elapsedTime = $(Get-Date) - $StartTime
        $totalTime = '{0:HH:mm:ss}' -f ([datetime]$elapsedTime.Ticks)

        Write-Output "Processed Resource Groups deployments: $($processedDeployments), Time spent $($totalTime)"
    } else {
        Write-Output 'Resource Groups level tracking is disabled by selected flags'
    }
    #endregion
}
