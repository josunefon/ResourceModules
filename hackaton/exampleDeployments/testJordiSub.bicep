targetScope = 'subscription'
module rg '../../modules/Microsoft.Resources/resourceGroups/deploy.bicep' = {
  name: 'hacking-rg-${deployment().name}'
  params: {
    name: 'hackaton22ResourceGroup'
    location: 'WestEurope'
  }
}
module logic '../../modules/Microsoft.Logic/workflows/deploy.bicep' = {
  name: 'hacking-wf-${deployment().name}'
  scope: resourceGroup('hackaton22ResourceGroup')
  params: {
    name: 'workflowhack22'
  }
  dependsOn: [
    rg
  ]
}
