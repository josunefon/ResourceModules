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

Import-Module -Name ./module-tracker.psm1

if($noTenantLevelTracking -eq $true -and $noSubscriptionsLevelTracking -eq $true -and $noResourceGroupsLevelTracking -eq $true)
{
    Write-Output "Please remove the flags for tracking purposes."
}else{
    #region Create the Storage Table
    Select-AzSubscription -SubscriptionId $storageSubscriptionId
    $tableObject = New-StorageAccountTable -StorageAccountName $storageAccount -ResourceGroup $resourceGroup -TableName 'AzureDeployments'
    #endregion

    #region Getting all Tenant deployments
    if($noTenantLevelTracking -eq $false){
        $StartTime = $(Get-Date)

        $processedDeployments = 0
        try {
            $azDeployments = Get-AzTenantDeployment

            foreach ($deployment in $azDeployments) {
                Save-AzDeploymentTemplate -DeploymentName $deployment.DeploymentName -Force | Out-Null
                $hash = Get-TemplateHash -TemplatePath "./$($deployment.DeploymentName).json"
                New-StorageAccountTableRow -Table $tableObject -PartitionKey $deployment.Id -DeploymentName $deployment.deploymentName -Hash $hash
                Remove-Item "./$($deployment.DeploymentName).json"
                $processedDeployments++
            }
        } catch {
            Write-Output "Error: $($_.Exception.Message)"
            continue
        }
        $elapsedTime = $(Get-Date) - $StartTime
        $totalTime = '{0:HH:mm:ss}' -f ([datetime]$elapsedTime.Ticks)

        Write-Output 'Processed Tenant deployments: ' + $processedDeployments 'Time spent '+$totalTime ''
    }else{
        Write-Output "Tenant level tracking is disabled by selected flags"
    }
    #endregion

    #region Getting all Subscriptions deployments
    if($noSubscriptionsLevelTracking -eq $false){
        $StartTime = $(Get-Date)
        $subscriptions = Get-AzSubscription
        $tableRows = @()

        foreach ($sub in $subscriptions) {
            Select-AzSubscription -SubscriptionId $sub.Id

            $processedDeployments = 0
            try {
                $azDeployments = Get-AzDeployment

                foreach ($deployment in $azDeployments) {
                    Save-AzDeploymentTemplate -DeploymentName $deployment.DeploymentName -Force | Out-Null
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
            New-StorageAccountTableRow -Table $tableObject -PartitionKey $row.deploymentId -DeploymentName $row.deploymentName -Hash $row.hash
        }
        $elapsedTime = $(Get-Date) - $StartTime
        $totalTime = '{0:HH:mm:ss}' -f ([datetime]$elapsedTime.Ticks)

        Write-Output 'Processed Subscriptions deployments: ' + $processedDeployments 'Time spent '+$totalTime ''
    }else{
        Write-Output "Subscriptions level tracking is disabled by selected flags"
    }
    #endregion

    #region Getting all Resource Group deployments per each Subscription
    if($noResourceGroupsLevelTracking -eq $false){
        $StartTime = $(Get-Date)
        $tableRows = @()

        foreach ($sub in $subscriptions) {
            Select-AzSubscription -SubscriptionId $sub.Id
            $resourceGroups = Get-AzResourceGroup

            $processedDeployments = 0
            foreach ($rg in $resourceGroups) {
                try {
                    $azDeployments = Get-AzResourceGroupDeployment

                    foreach ($deployment in $azDeployments) {
                        #exporting the deployment template object
                        Save-AzDeploymentTemplate -DeploymentName $deployment.DeploymentName -Force | Out-Null
                        #Generating hash value
                        $hash = Get-TemplateHash -TemplatePath "./$($deployment.DeploymentName).json"
                        #Adding results to object
                        $tableRows += [PSCustomObject]@{
                            deploymentName = $deployment.DeploymentName
                            deploymentId   = $rg
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
            New-StorageAccountTableRow -Table $tableObject -PartitionKey $row.deploymentId -DeploymentName $row.deploymentName -Hash $row.hash
        }
        $elapsedTime = $(Get-Date) - $StartTime
        $totalTime = '{0:HH:mm:ss}' -f ([datetime]$elapsedTime.Ticks)

        Write-Output 'Processed Resource Group deployments: ' + $processedDeployments 'Time spent '+$totalTime ''
    }else{
        Write-Output "Resource Groups level tracking is disabled by selected flags"
    }
    #endregion
}
