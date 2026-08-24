@description('Dedicated backup storage account to monitor.')
param storageAccountName string

@description('Resource ID of the action group to notify. Typically reuse budget.bicep\'s output.')
param actionGroupId string

@description('Environment tag (also used in the alert resource name).')
param environment string = 'prod'

@description('Ingress threshold per one-hour evaluation window, in bytes.')
@minValue(1)
param ingressThresholdBytes int = 16106127360

@description('Storage write APIs included in the alert. PutBlock is used by current rclone uploads; PutBlob covers smaller/future uploads.')
param ingressApiNames string[] = [
  'PutBlock'
  'PutBlob'
]

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
    description: 'Fires when OAuth block/blob writes to primary game-backup storage exceed the configured threshold in one hour. The threshold is parameterized so the combined C2E2, Palworld, and Windrose baseline can be reviewed without changing this module.'
    severity: 3
    enabled: true
    scopes: [
      storageAccount.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT1H'
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
          dimensions: [
            {
              name: 'GeoType'
              operator: 'Include'
              values: [
                'Primary'
              ]
            }
            {
              name: 'Authentication'
              operator: 'Include'
              values: [
                'OAuth'
              ]
            }
            {
              name: 'ApiName'
              operator: 'Include'
              values: ingressApiNames
            }
          ]
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
