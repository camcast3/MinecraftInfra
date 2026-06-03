@description('ntfy webhook URL for budget alerts (stored in Key Vault)')
@secure()
param ntfyWebhookUrl string

@description('Monthly budget amount in USD')
param budgetAmount int = 80

@description('Environment tag')
param environment string = 'prod'

// ── Action Group ─────────────────────────────────────────────────────────────
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-budget-ntfy-${environment}'
  location: 'global'
  tags: {
    environment: environment
  }
  properties: {
    groupShortName: 'ntfy-budget'
    enabled: true
    webhookReceivers: [
      {
        name: 'ntfy-mc-ops'
        serviceUri: '${ntfyWebhookUrl}/mc-ops'
        useCommonAlertSchema: false
      }
      {
        name: 'ntfy-mc-alerts'
        serviceUri: '${ntfyWebhookUrl}/mc-alerts'
        useCommonAlertSchema: false
      }
    ]
  }
}

// ── Budget ───────────────────────────────────────────────────────────────────
resource budget 'Microsoft.Consumption/budgets@2024-08-01' = {
  name: 'budget-minecraft-${environment}'
  properties: {
    category: 'Cost'
    amount: budgetAmount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: '2026-07-01'
    }
    notifications: {
      seventyFivePercent: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 75
        thresholdType: 'Actual'
        contactGroups: [
          actionGroup.id
        ]
        locale: 'en-us'
      }
      eightySevenPointFivePercent: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 87.5
        thresholdType: 'Actual'
        contactGroups: [
          actionGroup.id
        ]
        locale: 'en-us'
      }
    }
  }
}
