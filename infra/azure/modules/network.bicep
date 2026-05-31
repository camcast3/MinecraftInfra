@description('Azure region for all resources')
param location string

@description('Environment tag (e.g. prod)')
param environment string = 'prod'

var vnetName = 'vnet-minecraft-${environment}'
var subnetName = 'subnet-minecraft'
var nsgName = 'nsg-minecraft-${environment}'
var publicIpName = 'pip-minecraft-${environment}'
var nicName = 'nic-minecraft-${environment}'

resource nsg 'Microsoft.Network/networkSecurityGroups@2025-07-01' = {
  name: nsgName
  location: location
  tags: { environment: environment }
  properties: {
    securityRules: [
      {
        name: 'Allow-Minecraft-TCP'
        properties: {
          priority: 100
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '25565'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          direction: 'Inbound'
        }
      }
      {
        name: 'Allow-Minecraft-UDP'
        properties: {
          priority: 110
          protocol: 'Udp'
          sourcePortRange: '*'
          destinationPortRange: '25565'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          direction: 'Inbound'
        }
      }
      {
        name: 'Deny-SSH-Internet'
        properties: {
          priority: 200
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
          access: 'Deny'
          direction: 'Inbound'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2025-07-01' = {
  name: vnetName
  location: location
  tags: { environment: environment }
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.1.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2025-07-01' = {
  name: publicIpName
  location: location
  tags: { environment: environment }
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: 'minecraft-lobby-${environment}'
    }
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2025-07-01' = {
  name: nicName
  location: location
  tags: { environment: environment }
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${vnet.id}/subnets/${subnetName}'
          }
          publicIPAddress: { id: publicIp.id }
        }
      }
    ]
  }
}

output nicId string = nic.id
output publicIpAddress string = publicIp.properties.ipAddress
output publicIpFqdn string = publicIp.properties.dnsSettings.fqdn
