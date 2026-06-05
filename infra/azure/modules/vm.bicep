@description('Azure region for all resources')
param location string

@description('NIC resource ID from network module')
param nicId string

@description('Admin username for the VM — resolved from Key Vault by ARM')
@secure()
param adminUsername string

@description('SSH public key — resolved from Key Vault by ARM at deploy time, never visible to the GitHub Actions runner')
@secure()
param adminSshPublicKey string

@description('TailScale auth key — resolved from Key Vault by ARM at deploy time')
@secure()
param tailscaleAuthKey string

@description('GitHub repo URL to clone on first boot')
param repoUrl string = 'https://github.com/camcast3/MinecraftInfra'

@description('VM size')
param vmSize string = 'Standard_B4s_v2'

@description('Environment tag')
param environment string = 'prod'

@description('Whether to send osProfile.customData. Only true on initial VM creation — Azure rejects changes to this property on an existing VM (PropertyChangeNotAllowed). Subsequent runs must leave this false so the key is omitted entirely from the request payload.')
param setCustomData bool = false

var vmName = 'vm-minecraft-${environment}'
var osDiskName = 'osdisk-minecraft-${environment}'
var dataDiskName = 'datadisk-minecraft-${environment}'

var cloudInitScript = '''
#cloud-config
package_update: true
package_upgrade: true

packages:
  - curl
  - git
  - ufw
  - unattended-upgrades
  - apt-listchanges
  - gettext-base

write_files:
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
      APT::Periodic::AutocleanInterval "7";
  - path: /etc/apt/apt.conf.d/51unattended-upgrades-minecraft
    content: |
      Unattended-Upgrade::Automatic-Reboot "true";
      Unattended-Upgrade::Automatic-Reboot-Time "03:00";

runcmd:
  - curl -fsSL https://aka.ms/InstallAzureCLIDeb | bash
  - curl -fsSL https://get.docker.com | sh
  - systemctl enable --now docker
  - curl -fsSL https://tailscale.com/install.sh | sh
  - tailscale up --authkey=__TAILSCALE_AUTH_KEY__ --ssh
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow 25565/tcp comment 'Minecraft TCP'
  - ufw allow 25565/udp comment 'Minecraft UDP'
  - ufw allow in on tailscale0 comment 'TailScale'
  - ufw --force enable
  # Add the admin user to the docker group so SSH deploy commands work without sudo
  - usermod -aG docker __ADMIN_USERNAME__
  # Format and mount the data disk (LUN 0 → stable Azure symlink)
  - mkdir -p /data
  - mkfs.ext4 /dev/disk/azure/scsi1/lun0
  - DATA_UUID=$(blkid -s UUID -o value /dev/disk/azure/scsi1/lun0)
  - echo "UUID=${DATA_UUID}  /data  ext4  defaults,nofail  0  2" >> /etc/fstab
  - mount /data
  - mkdir -p /data/minecraft/velocity
  - chown -R __ADMIN_USERNAME__:__ADMIN_USERNAME__ /data
  # Clone the repo
  - git clone __REPO_URL__ /opt/minecraft
  - chown -R __ADMIN_USERNAME__:__ADMIN_USERNAME__ /opt/minecraft
  # Fetch secrets from Key Vault and write .env + velocity config.
  # Retry loop handles the brief delay before the Managed Identity is available.
  - |
    export HOME=/root
    for i in 1 2 3 4 5; do
      bash /opt/minecraft/docker/azure/refresh-env.sh && break
      echo "refresh-env.sh attempt $i failed, retrying in 15s..."
      sleep 15
    done
  # Start the Docker stack
  - docker compose -f /opt/minecraft/docker/azure/docker-compose.yml up -d
'''

var cloudInitRendered = replace(
  replace(
    replace(cloudInitScript, '__TAILSCALE_AUTH_KEY__', tailscaleAuthKey),
    '__REPO_URL__', repoUrl
  ),
  '__ADMIN_USERNAME__', adminUsername
)

resource dataDisk 'Microsoft.Compute/disks@2025-01-02' = {
  name: dataDiskName
  location: location
  tags: { environment: environment }
  sku: { name: 'Premium_LRS' }
  properties: {
    diskSizeGB: 64
    creationData: { createOption: 'Empty' }
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2025-11-01' = {
  name: vmName
  location: location
  tags: { environment: environment }
  // System-assigned Managed Identity — lets the VM authenticate to Azure services
  // (Key Vault, Storage) without any stored credentials.
  // The principalId is outputted below so main.bicep can wire role assignments.
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: {
        publisher: 'debian'
        offer: 'debian-13'
        sku: '13'
        version: 'latest'
      }
      osDisk: {
        name: osDiskName
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
        diskSizeGB: 32
        deleteOption: 'Delete'
      }
      dataDisks: [
        {
          lun: 0
          name: dataDiskName
          createOption: 'Attach'
          managedDisk: { id: dataDisk.id }
          deleteOption: 'Detach'
        }
      ]
    }
    // customData is only emitted on initial provisioning (setCustomData=true).
    // Azure rejects ANY change to osProfile.customData on an existing VM with
    // PropertyChangeNotAllowed — even if the decoded payload is identical, any
    // drift in inputs (e.g. tailscaleAuthKey rotation) re-renders the base64
    // string and trips the check. union() keeps the key entirely absent from
    // the request on subsequent runs (not null, not empty).
    osProfile: union({
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              // Azure writes this key to the admin user's authorized_keys on first boot
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }, setCustomData ? { customData: base64(cloudInitRendered) } : {})
    networkProfile: {
      networkInterfaces: [
        { id: nicId }
      ]
    }
  }
}

output vmId string = vm.id
output vmName string = vm.name
// principalId of the system-assigned Managed Identity — used by main.bicep to
// assign roles on Key Vault and Storage without storing any credentials.
output principalId string = vm.identity.principalId
