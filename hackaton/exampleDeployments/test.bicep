targetScope = 'subscription'
module rg '../../modules/Microsoft.Resources/resourceGroups/deploy.bicep' = {
  name: 'engine-rg-${deployment().name}'
  params: {
    name: 'engineResourceGroupName'
    location: 'WestEurope'
  }
}
module storage '../../modules/Microsoft.Storage/storageAccounts/deploy.bicep' = {
  name: 'storage-${deployment().name}'
  scope: resourceGroup('engineResourceGroupName')
  params: {
    name: 'storageaccountname435'
  }
  dependsOn: [
    rg
  ]
}
