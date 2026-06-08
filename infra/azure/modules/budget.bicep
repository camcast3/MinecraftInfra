@description('Email address to send budget alerts to (stored in Key Vault — PII)')
@secure()
param alertEmail string

@description('Monthly budget amount in USD')
param budgetAmount int = 80

@description('Environment tag')
param environment string = 'prod'

// ── Action Group ─────────────────────────────────────────────────────────────
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-budget-email-${environment}'
  location: 'global'
  tags: {
    environment: environment
  }
  properties: {
    groupShortName: 'budget-mail'
    enabled: true
    emailReceivers: [
      {
        name: 'budget-alerts'
        emailAddress: alertEmail
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
        contactEmails: [
          alertEmail
        ]
        contactGroups: [
          actionGroup.id
        ]
        locale: 'en-us'
      }
      eightySevenPointFivePercent: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: json('87.5')
        thresholdType: 'Actual'
        contactEmails: [
          alertEmail
        ]
        contactGroups: [
          actionGroup.id
        ]
        locale: 'en-us'
      }
    }
  }
}

// Exposed so sibling alert modules (e.g. metric-alerts.bicep) can reuse the
// same email action group — no second contact, no extra action-group cost.
output actionGroupId string = actionGroup.id
