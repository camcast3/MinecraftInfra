@description('Storage account to monitor. The alert scope is account-level (no service dimension).')
param storageAccountName string

@description('Resource ID of the action group to notify. Typically reuse budget.bicep\'s output.')
param actionGroupId string

@description('Environment tag (also used in the alert resource name).')
param environment string = 'prod'

@description('Ingress threshold per evaluation window, in bytes. Default 2 GiB ≈ 2.4× the worst plausible non-anomaly window (backup + modpack publish coincident).')
param ingressThresholdBytes int = 2147483648

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-08-01' existing = {
  name: storageAccountName
}

// Microsoft.Insights/metricAlerts is a global ARM resource — location MUST be
// 'global'. Deploying to the storage account's region will fail with an ARM
// validation error.
resource storageIngressAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-storage-ingress-${environment}'
  location: 'global'
  tags: {
    environment: environment
  }
  properties: {
    description: 'Fires when total ingress to the storage account exceeds the threshold over a 6h window. Catches runaway backups, accidentally-included world dirs in modpack publishes, or other anomalous write volume — long before the monthly budget alert would notice.'
    severity: 3
    enabled: true
    scopes: [
      storageAccount.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT6H'
    targetResourceType: 'Microsoft.Storage/storageAccounts'
    targetResourceRegion: storageAccount.location
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'IngressBytes'
          metricName: 'Ingress'
          metricNamespace: 'Microsoft.Storage/storageAccounts'
          operator: 'GreaterThanOrEqual'
          threshold: ingressThresholdBytes
          timeAggregation: 'Total'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    autoMitigate: true
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

output alertId string = storageIngressAlert.id
