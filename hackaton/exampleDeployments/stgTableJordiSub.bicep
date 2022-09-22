targetScope = 'subscription'
module rg '../../modules/Microsoft.Resources/resourceGroups/deploy.bicep' = {
  name: 'stg-table-rg-${deployment().name}'
  params: {
    name: 'storageTableHackResourceGroup'
    location: 'WestEurope'
  }
}
module storage '../../modules/Microsoft.Storage/storageAccounts/deploy.bicep' = {
  name: 'storage-table-${deployment().name}'
  scope: resourceGroup('storageTableHackResourceGroup')
  params: {
    name: 'storagetablehack22'
  }
  dependsOn: [
    rg
  ]
}
