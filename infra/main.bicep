// main.bicep — the Azure footprint for the NBKI Db2 -> Fabric demo.
//
// Two VMs in one VNet:
//   vm-db2      Ubuntu, runs Db2 11.5.9.0 Community Edition in Docker
//   vm-gateway  Windows Server, runs the on-premises data gateway
//
// The gateway VM is not optional and not a convenience. Every capability of the
// Fabric IBM Db2 connector -- Dataflow Gen2, Copy activity, Lookup, Copy job --
// is documented as requiring an *on-premises* gateway, even when Db2 is in
// Azure and publicly addressable. A VNet data gateway cannot be used.
//
// Things here that look arbitrary but are not:
//
//   * Standard_D4s_v5 (4 vCPU / 16 GiB) matches the Db2 Community Edition
//     entitlement exactly. A larger VM buys nothing; Db2 CE will not use it.
//
//   * The Db2 NIC takes a STATIC private address. The Fabric connection string
//     and an NSG rule both name it, so "whatever Azure assigns" is not good
//     enough -- it has to be a contract.
//
//   * Each NSG carries an explicit deny above the platform's default
//     AllowVNetInBound rule (priority 65000). Without it, listing three allow
//     rules does NOT mean everything else is denied: the two subnets could still
//     reach each other on every port. AzureLoadBalancer is re-allowed above the
//     deny so platform probes are not collateral damage.
//
//   * Db2 is reached on 50001 (TLS), never 50000. The cleartext port is bound to
//     the container host's loopback and is not published, so there is nothing to
//     firewall. See db2_up.sh.
//
//   * Azure Bastion, Developer SKU (free, no subnet, no public IP), is how you
//     actually get an interactive session. This tenant runs an automated control
//     that DELETES any NSG rule exposing a management port -- 22 or 3389 -- to
//     the internet, even when the rule is pinned to a single /32. It removed both
//     within about 45 minutes of the first deployment and left the Db2 TLS rule
//     alone. The `allow-*-operator` rules for 22 and 3389 are declared here
//     anyway, because the initial bulk rsync needs real SSH and Bastion Developer
//     does not support native-client tunnelling -- but treat them as temporary
//     and expect to re-create them. Anything interactive should go through
//     Bastion, which nothing deletes.

targetScope = 'resourceGroup'

@description('Azure region. Sweden Central pairs with the F8 capacity momof8sweden.')
param location string = resourceGroup().location

@description('Public IP allowed to reach SSH, RDP and Db2 TLS. A single address, not a range.')
param operatorIp string

@description('Admin/operator username on both VMs.')
param adminUsername string = 'nbkiadmin'

@description('SSH public key for vm-db2. Password authentication is disabled.')
param sshPublicKey string

@description('Administrator password for vm-gateway. Windows has no SSH key equivalent here.')
@secure()
param windowsAdminPassword string

@description('Static private address for vm-db2. Named by the Fabric connection and an NSG rule.')
param db2PrivateIp string = '10.20.1.4'

@description('Deploy the point-to-site VPN gateway. Takes 30-45 minutes and cannot be deallocated, so set false for a cheaper, Bastion-only build.')
param deployVpnGateway bool = true

@description('Address pool handed to VPN clients. Must not overlap the VNet.')
param vpnClientPool string = '172.16.201.0/24'

@description('Entra tenant ID for VPN authentication.')
param tenantId string = subscription().tenantId

@description('Once the VPN is confirmed working, set true to drop every inbound rule sourced from the public internet. Leave false until you have connected successfully at least once, or you will lock yourself out of everything except Bastion.')
param lockToVpnOnly bool = false

@description('Allow the gateway NIC to reach Db2 on cleartext 50000, inside the VNet only. Needed only if the pipeline Copy path turns out not to negotiate TLS; see docs/runbook-phase1.md. Never exposes 50000 to the internet.')
param allowGatewayCleartext bool = false

// The Microsoft-registered Azure VPN Client application, Azure Public cloud.
// Using this value means there is NO app registration to create and NO admin
// consent to grant -- that requirement belongs to the older, manually-registered
// audience values. Do not "helpfully" register an app; it is not needed.
var azureVpnClientAppId = 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8'

var vnetName = 'vnet-nbki'
var db2SubnetName = 'snet-db2'
var gwSubnetName = 'snet-gateway'
var operatorCidr = '${operatorIp}/32'

// ---------------------------------------------------------------------------
// Inbound rules are assembled rather than listed, because which sources are
// legitimate depends on how you reach the environment.
//
//   * publicDb2Rules / publicRdpRules -- sourced from the operator's current
//     public address. These are the compromise: convenient, but they put a
//     banking-shaped database on a public address, and this tenant deletes the
//     management-port ones on a schedule anyway. `lockToVpnOnly` removes them.
//
//   * vpnDb2Rules / vpnRdpRules -- sourced from the VPN client pool. Once the
//     workstation holds an address inside the VNet these are all that is needed,
//     and nothing is reachable from the internet at all.
//
// Flip lockToVpnOnly only AFTER connecting over the VPN successfully once.
// ---------------------------------------------------------------------------
// Guarded deliberately: removing the public rules only makes sense if the VPN
// rules exist to replace them. lockToVpnOnly with deployVpnGateway=false would
// empty BOTH blocks at once, leaving Bastion as the only way in -- and Bastion's
// Developer SKU cannot carry SSH for any script in this repo, so the environment
// would become browser-only with no route back except a redeploy. Requiring both
// makes that combination harmless rather than relying on deploy.sh never
// exposing the flag.
var lockedDown = lockToVpnOnly && deployVpnGateway

var publicDb2Rules = lockedDown ? [] : [
  {
    name: 'allow-ssh-operator'
    properties: {
      priority: 100
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: operatorCidr
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '22'
      description: 'SSH from the operator workstation. Expect the tenant control to delete this; see infra/_ensure_ssh_access.sh.'
    }
  }
  {
    name: 'allow-db2-tls-operator'
    properties: {
      priority: 110
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: operatorCidr
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '50001'
      description: 'Db2 DRDA over TLS from the operator workstation, over the public internet.'
    }
  }
]

var vpnDb2Rules = deployVpnGateway ? [
  {
    name: 'allow-ssh-vpn'
    properties: {
      priority: 150
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: vpnClientPool
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '22'
      description: 'SSH from a point-to-site VPN client. Immune to the tenant control and to the operator IP moving.'
    }
  }
  {
    name: 'allow-db2-tls-vpn'
    properties: {
      priority: 160
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: vpnClientPool
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '50001'
      description: 'Db2 DRDA over TLS from a point-to-site VPN client. This is the path that lets Db2 come off the public internet.'
    }
  }
] : []

var publicRdpRules = lockedDown ? [] : [
  {
    name: 'allow-rdp-operator'
    properties: {
      priority: 100
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: operatorCidr
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '3389'
      description: 'RDP from the operator workstation. The tenant control deletes this; prefer Bastion or the VPN.'
    }
  }
]

var vpnRdpRules = deployVpnGateway ? [
  {
    name: 'allow-rdp-vpn'
    properties: {
      priority: 150
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: vpnClientPool
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '3389'
      description: 'RDP from a point-to-site VPN client, for the gateway registration step.'
    }
  }
] : []

// Shared tail: Bastion (break-glass, always kept), platform probes, and the
// catch-all deny that makes the allows above actually exhaustive.
// Cleartext DRDA, gateway NIC only, never the internet. This exists because the
// Power Query path (connection test, Dataflow Gen2) demonstrably speaks TLS to
// Db2 while a pipeline Copy activity was observed sending an unencrypted message
// to the TLS port. If that turns out to be a property of the Copy path rather
// than of a hand-authored pipeline, this is the mitigation: the workstation keeps
// TLS on 50001, and only the gateway -- one NIC, inside the VNet, scoped by
// application security group -- is allowed to use 50000.
var gatewayCleartextRules = allowGatewayCleartext ? [
  {
    name: 'allow-db2-cleartext-gateway'
    properties: {
      priority: 130
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceApplicationSecurityGroups: [ { id: gatewayAsg.id } ]
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '50000'
      description: 'Cleartext DRDA from the gateway NIC only. Enabled deliberately; see docs/runbook-phase1.md.'
    }
  }
] : []

var db2TailRules = [
  {
    name: 'allow-db2-tls-gateway'
    properties: {
      priority: 120
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceApplicationSecurityGroups: [ { id: gatewayAsg.id } ]
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '50001'
      description: 'Db2 DRDA over TLS from the gateway NIC. This is the Fabric path.'
    }
  }
  {
    name: 'allow-ssh-bastion'
    properties: {
      priority: 200
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '22'
      description: 'SSH via Azure Bastion. Kept as break-glass even when locked to VPN only.'
    }
  }
  {
    name: 'allow-azure-lb'
    properties: {
      priority: 3900
      direction: 'Inbound'
      access: 'Allow'
      protocol: '*'
      sourceAddressPrefix: 'AzureLoadBalancer'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
      description: 'Re-allow platform probes above the catch-all deny below.'
    }
  }
  {
    name: 'deny-all-inbound'
    properties: {
      priority: 4000
      direction: 'Inbound'
      access: 'Deny'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
      description: 'Overrides the default AllowVNetInBound (65000). Without this, the allows above are not exhaustive.'
    }
  }
]

var gatewayTailRules = [
  {
    name: 'allow-rdp-bastion'
    properties: {
      priority: 200
      direction: 'Inbound'
      access: 'Allow'
      protocol: 'Tcp'
      sourceAddressPrefix: 'VirtualNetwork'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '3389'
      description: 'RDP via Azure Bastion. Kept as break-glass even when locked to VPN only.'
    }
  }
  {
    name: 'allow-azure-lb'
    properties: {
      priority: 3900
      direction: 'Inbound'
      access: 'Allow'
      protocol: '*'
      sourceAddressPrefix: 'AzureLoadBalancer'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
    }
  }
  {
    name: 'deny-all-inbound'
    properties: {
      priority: 4000
      direction: 'Inbound'
      access: 'Deny'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRange: '*'
      description: 'Overrides the default AllowVNetInBound (65000).'
    }
  }
]

// ---------------------------------------------------------------------------
// Application security group. The Db2 rule targets the gateway's NIC through
// this, rather than the gateway subnet's CIDR, so that adding anything else to
// that subnet later does not silently hand it database access.
// ---------------------------------------------------------------------------
resource gatewayAsg 'Microsoft.Network/applicationSecurityGroups@2023-11-01' = {
  name: 'asg-gateway'
  location: location
}

resource db2Nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-db2'
  location: location
  properties: {
    securityRules: concat(publicDb2Rules, vpnDb2Rules, gatewayCleartextRules, db2TailRules)
  }
}

resource gatewayNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-gateway'
  location: location
  properties: {
    securityRules: concat(publicRdpRules, vpnRdpRules, gatewayTailRules)
    // Outbound is deliberately left at the platform default (allow to Internet).
    // The gateway needs 443 plus Service Bus 5671/5672 and 9350-9354, and the VM
    // agent needs DNS and certificate-revocation endpoints. Restricting this is a
    // real piece of work and belongs in a hardening pass, not here -- recorded in
    // docs/runbook-phase1.md rather than claimed and not done.
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.20.0.0/16' ] }
    subnets: [
      {
        name: db2SubnetName
        properties: {
          addressPrefix: '10.20.1.0/24'
          networkSecurityGroup: { id: db2Nsg.id }
        }
      }
      {
        name: gwSubnetName
        properties: {
          addressPrefix: '10.20.2.0/24'
          networkSecurityGroup: { id: gatewayNsg.id }
        }
      }
      // The VPN gateway's own subnet. The name is fixed by Azure -- it must be
      // exactly 'GatewaySubnet' -- and it deliberately carries no NSG, because
      // attaching one to a gateway subnet is unsupported and breaks the control
      // traffic the gateway needs.
      {
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: '10.20.255.0/27'
        }
      }
    ]
  }
}

// A static public IP on each VM. Besides being predictable for the NSG rules and
// RDP, an instance-level public IP is an explicit outbound path -- which matters
// now that default outbound access for new VMs is retired.
resource db2Pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-db2'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource gatewayPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-gateway'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource db2Nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'nic-db2'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: db2PrivateIp
          subnet: { id: '${vnet.id}/subnets/${db2SubnetName}' }
          publicIPAddress: { id: db2Pip.id }
        }
      }
    ]
  }
}

resource gatewayNic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'nic-gateway'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: '${vnet.id}/subnets/${gwSubnetName}' }
          publicIPAddress: { id: gatewayPip.id }
          applicationSecurityGroups: [ { id: gatewayAsg.id } ]
        }
      }
    ]
  }
}

resource db2Vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-db2'
  location: location
  properties: {
    hardwareProfile: { vmSize: 'Standard_D4s_v5' }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        // 128 GB is measured, not guessed: Db2 image 1.6 + prepared CSVs 1.7 +
        // the copy staged inside the container 1.7 + the loaded /database volume
        // 4.2 + a transient 1.1 GB header-stripped .del file. Comfortable margin,
        // and no second disk to mount and get wrong.
        diskSizeGB: 128
        // storageAccountType is deliberately NOT asserted here.
        //
        // A governance automation in this subscription downgrades idle OS disks
        // from Premium_LRS to Standard_LRS while the VM is deallocated -- observed
        // happening to both VMs during a stop/start test. ARM then refuses the next
        // deployment outright:
        //   OperationNotAllowed: Managed disk storage account type change through
        //   Virtual Machine 'vm-db2' is not allowed.
        // A template that names the SKU therefore breaks permanently the first time
        // the environment is stopped overnight. Leaving it unset lets Azure pick a
        // sensible default at create time and leaves the disk alone thereafter.
      }
    }
    osProfile: {
      computerName: 'vm-db2'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
      // No customData. The Db2 password is handed over after boot on the SSH
      // channel instead: cloud-init user-data is readable from inside the VM and
      // is retained in the VM model, which is not where an instance-owner
      // credential belongs.
    }
    networkProfile: {
      networkInterfaces: [ { id: db2Nic.id } ]
    }
  }
}

resource gatewayVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-gateway'
  location: location
  properties: {
    hardwareProfile: { vmSize: 'Standard_D4s_v5' }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        // Desktop Experience. The on-premises data gateway is not supported on
        // Server Core, and registration needs an interactive sign-in anyway.
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 128
        // Not asserted -- see the note on vm-db2's OS disk.
      }
    }
    osProfile: {
      computerName: 'vm-gateway'
      adminUsername: adminUsername
      adminPassword: windowsAdminPassword
    }
    networkProfile: {
      networkInterfaces: [ { id: gatewayNic.id } ]
    }
  }
}

// Azure Bastion, Developer SKU. Free, needs no AzureBastionSubnet and no public
// IP, and gives browser RDP/SSH from the portal. This is the durable interactive
// path in a tenant that deletes internet-facing management-port rules.
//
// Its one relevant limitation: the Developer SKU does not support native-client
// tunnelling, so it cannot carry an rsync. Bulk transfer uses the temporary
// allow-ssh-operator rule; everything interactive uses this.
resource bastion 'Microsoft.Network/bastionHosts@2023-11-01' = {
  name: 'bst-nbki'
  location: location
  sku: { name: 'Developer' }
  properties: {
    virtualNetwork: { id: vnet.id }
  }
}

// ---------------------------------------------------------------------------
// Point-to-site VPN.
//
// This is what takes Db2 off the public internet. With the workstation holding
// an address inside the VNet, nothing needs an inbound allow rule from the
// internet -- which restores the posture docs/feasibility.md specified ("no
// public IP, NSG-restricted") and removes both of the operational problems this
// environment kept producing: a tenant control that deletes internet-facing
// management-port rules, and a home IP address that moves.
//
// SKU choice is forced, not preferred. The Basic SKU supports only SSTP, which
// is Windows-only; a Mac needs IKEv2 or OpenVPN, and the lowest SKU offering
// those is VpnGw1AZ. Budget roughly $153/month plus ~$7/month per connection,
// and note that a VPN gateway CANNOT be deallocated -- infra/stop.sh saves the
// VM compute but this keeps billing until it is deleted. Set deployVpnGateway
// to false if that is not worth it for a given build.
// ---------------------------------------------------------------------------
resource vpnPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = if (deployVpnGateway) {
  name: 'pip-vgw'
  location: location
  sku: { name: 'Standard' }
  zones: [ '1', '2', '3' ]
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2023-11-01' = if (deployVpnGateway) {
  name: 'vgw-nbki'
  location: location
  properties: {
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    vpnGatewayGeneration: 'Generation1'
    sku: { name: 'VpnGw1AZ', tier: 'VpnGw1AZ' }
    enableBgp: false
    activeActive: false
    ipConfigurations: [
      {
        name: 'vnetGatewayConfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: '${vnet.id}/subnets/GatewaySubnet' }
          publicIPAddress: { id: vpnPip.id }
        }
      }
    ]
    vpnClientConfiguration: {
      vpnClientAddressPool: { addressPrefixes: [ vpnClientPool ] }
      // OpenVPN is required for Entra ID authentication; IKEv2 cannot carry it.
      vpnClientProtocols: [ 'OpenVPN' ]
      vpnAuthenticationTypes: [ 'AAD' ]
      aadAudience: azureVpnClientAppId
      // No trailing slash on the tenant URL, but the issuer MUST have one.
      // Microsoft documents that an issuer without it may simply fail to
      // connect, and the error does not point at the cause.
      //
      // These are spelled out rather than taken from environment(), which the
      // Bicep linter would prefer: environment().authentication.loginEndpoint
      // returns the URL *with* a trailing slash, and the difference is exactly
      // what breaks here. Azure Public only -- Government and China use
      // different hosts (login.microsoftonline.us, login.chinacloudapi.cn).
      #disable-next-line no-hardcoded-env-urls
      aadTenant: 'https://login.microsoftonline.com/${tenantId}'
      aadIssuer: 'https://sts.windows.net/${tenantId}/'
    }
  }
}

output db2PublicIp string = db2Pip.properties.ipAddress
output db2PrivateIpOut string = db2PrivateIp
output gatewayPublicIp string = gatewayPip.properties.ipAddress
output adminUsernameOut string = adminUsername
output vpnClientPoolOut string = vpnClientPool
output vpnGatewayName string = deployVpnGateway ? vpnGateway.name : ''
