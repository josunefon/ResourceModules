targetScope = 'resourceGroup'

@description('Base name to be used in all resources')
param name string = 'hacktrack22'

@description('Base name to be used in all resources')
param resourceGroupName string = 'storageTableHackResourceGroup'

@description('Name of the sotrage account')
param staname string = 'hacktrack22sta'

@description('Location where resources should be deployed')
param location string = 'WestEurope'

var storageAccountKey = listKeys(resourceId(subscription().subscriptionId, resourceGroupName, storageAccountRef.type, storageAccountRef.name), storageAccountRef.apiVersion).keys[0].value

module appServicePlan '../../../../modules/Microsoft.Web/serverfarms/deploy.bicep' = {
  name: '${name}-sp-${deployment().name}'
  params: {
    name: '${name}-sp'
    location: location
    sku: {
      name: 'S1'
      capacity: 1
    }
  }
}

module appService '../../../../modules/Microsoft.Web/sites/deploy.bicep' = {
  name: '${name}-fa-${deployment().name}'
  params: {
    name: '${name}-fa'
    location: location
    kind: 'functionapp'
    systemAssignedIdentity: true
    clientAffinityEnabled: false
    httpsOnly: true
    serverFarmResourceId: appServicePlan.outputs.resourceId
    siteConfig: {
      numberOfWorkers: 1
      acrUseManagedIdentityCreds: false
      alwaysOn: true
      http20Enabled: false
      functionAppScaleLimit: 200
      minimumElasticInstanceCount: 1
      netFrameworkVersion: 'v4.0'
      phpVersion: '5.6'
      powerShellVersion: '~7'
    }
  }
}

module appServiceLogging '../../../../modules/Microsoft.Web/sites/config-appsettings/deploy.bicep' = {
  name: '${name}-falog-${deployment().name}'
  params: {
    appName: '${name}-fa'
    kind: 'functionapp'
    appSettingsKeyValuePairs: {
      APPINSIGHTS_INSTRUMENTATIONKEY: appInsights.outputs.instrumentationKey
      FUNCTIONS_EXTENSION_VERSION: '~3'
      FUNCTIONS_WORKER_RUNTIME: 'powershell'
      WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: 'DefaultEndpointsProtocol=https;AccountName=${storage.outputs.name};AccountKey=${storageAccountKey};EndpointSuffix=core.windows.net'
      WEBSITE_CONTENTSHARE: appService.name
      AzureWebJobsStorage: 'DefaultEndpointsProtocol=https;AccountName=${storage.outputs.name};AccountKey=${storageAccountKey};EndpointSuffix=core.windows.net'
    }
  }
  dependsOn: [
    appServiceSiteExtension
  ]
}

resource appServiceRef 'Microsoft.Web/sites@2021-03-01' existing = {
  name: '${name}-fa'
}

resource appServiceSiteExtension 'Microsoft.Web/sites/siteextensions@2021-02-01' = {
  parent: appServiceRef
  name: 'Microsoft.ApplicationInsights.AzureWebSites'
  dependsOn: [
    appInsights
  ]
}

module logAnalyticsWorkspace '../../../../modules/Microsoft.OperationalInsights/workspaces/deploy.bicep' = {
  name: '${name}-la-${deployment().name}'
  params: {
    name: '${name}-la'
    location: location
    serviceTier: 'PerGB2018'
    dataRetention: 120
    useResourcePermissions: true
  }
}

module appInsights '../../../../modules/Microsoft.Insights/components/deploy.bicep' = {
  name: '${name}-ai-${deployment().name}'
  params: {
    name: '${name}-ai'
    location: location
    kind: 'web'
    appInsightsType: 'web'
    workspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
  }
}

module storage '../../../../modules/Microsoft.Storage/storageAccounts/deploy.bicep' = {
  name: '${staname}-stg-${deployment().name}'
  params: {
    name: staname
    location: location
    roleAssignments: [
      {
        principalIds: [ appService.outputs.systemAssignedPrincipalId ]
        roleDefinitionIdOrName: 'Contributor'
      }
    ]
    allowBlobPublicAccess: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'AzureServices'
      virtualNetworkRules: []
      ipRules: []
      defaultAction: 'Allow'
    }
  }
}

resource storageAccountRef 'Microsoft.Storage/storageAccounts@2022-05-01' existing = {
  name: staname
}
