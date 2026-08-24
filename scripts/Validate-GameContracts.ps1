[CmdletBinding()]
param(
    [string]$RepositoryRoot = [System.IO.Path]::Combine($PSScriptRoot, '..'),
    [string]$ContractsRoot = [System.IO.Path]::Combine(
        $PSScriptRoot, '..', 'contracts'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
$ContractsRoot = [System.IO.Path]::GetFullPath($ContractsRoot)
$errors = [System.Collections.Generic.List[string]]::new()

function Add-ValidationError {
    param([string]$Message)
    $errors.Add($Message)
}

function Get-RequiredProperty {
    param(
        [object]$Object,
        [string]$Name,
        [string]$Context
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        Add-ValidationError "$Context is missing '$Name'."
        return $null
    }
    return $property.Value
}

function Test-Identifier {
    param(
        [object]$Value,
        [string]$Context
    )
    if ($Value -isnot [string] -or $Value -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        Add-ValidationError "$Context must be a lower-case kebab-case identifier."
        return $false
    }
    return $true
}

function Test-PortNumber {
    param(
        [object]$Value,
        [string]$Context,
        [switch]$AllowNull
    )
    if ($null -eq $Value -and $AllowNull) {
        return $true
    }
    if ($Value -isnot [int] -and $Value -isnot [long]) {
        Add-ValidationError "$Context must be an integer."
        return $false
    }
    if ($Value -lt 1 -or $Value -gt 65535) {
        Add-ValidationError "$Context must be between 1 and 65535."
        return $false
    }
    return $true
}

function Read-ContractFiles {
    param(
        [string]$Path,
        [string]$Kind,
        [string]$SchemaPath
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Add-ValidationError "$Kind contract directory not found: $Path"
        return @()
    }

    $result = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Filter '*.json' -File | Sort-Object Name)) {
        try {
            $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
            $contract = $content | ConvertFrom-Json -ErrorAction Stop
            $schemaErrors = @()
            $schemaValid = Test-Json -Json $content -SchemaFile $SchemaPath `
                -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
            if (-not $schemaValid) {
                $details = if ($schemaErrors.Count -gt 0) {
                    ': ' + (($schemaErrors | ForEach-Object { $_.Exception.Message }) -join '; ')
                } else {
                    ''
                }
                Add-ValidationError "$Kind contract '$($file.FullName)' does not match its schema$details"
            }
            $result += [pscustomobject]@{
                File     = $file
                Content  = $content
                Contract = $contract
            }
        } catch {
            Add-ValidationError "Could not parse $Kind contract '$($file.FullName)': $($_.Exception.Message)"
        }
    }

    if ($result.Count -eq 0) {
        Add-ValidationError "No $Kind contracts found in $Path."
    }
    return @($result)
}

function Test-NoSecretValues {
    param(
        [object]$Value,
        [string]$Context
    )

    if ($null -eq $Value) {
        return
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -match '(?i)^(?:secretValue|plaintext|literal|password|token|authKey|apiKey)$') {
                Add-ValidationError "$Context contains forbidden secret-value property '$($property.Name)'; store secret names only."
            }
            Test-NoSecretValues -Value $property.Value -Context "$Context.$($property.Name)"
        }
        return
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $index = 0
        foreach ($item in $Value) {
            Test-NoSecretValues -Value $item -Context "$Context[$index]"
            $index++
        }
        return
    }

    if ($Value -is [string] -and
        $Value -match '(?i)(?:-----BEGIN [A-Z ]+PRIVATE KEY-----|tskey-auth-|AKIA[0-9A-Z]{16})') {
        Add-ValidationError "$Context appears to contain a committed secret value."
    }
}

$nodeItems = Read-ContractFiles `
    -Path (Join-Path $ContractsRoot 'nodes') `
    -Kind 'node' `
    -SchemaPath (Join-Path $ContractsRoot 'node-contract.schema.json')
$gameItems = Read-ContractFiles `
    -Path (Join-Path $ContractsRoot 'games') `
    -Kind 'game' `
    -SchemaPath (Join-Path $ContractsRoot 'game-contract.schema.json')
$nodesById = @{}

foreach ($item in $nodeItems) {
    $contract = $item.Contract
    $context = "Node contract '$($item.File.Name)'"
    Test-NoSecretValues -Value $contract -Context $context

    $version = Get-RequiredProperty -Object $contract -Name 'contractVersion' -Context $context
    if ($null -ne $version -and $version -ne 1) {
        Add-ValidationError "$context has unsupported contractVersion '$version'."
    }

    $nodeId = Get-RequiredProperty -Object $contract -Name 'nodeId' -Context $context
    if (Test-Identifier -Value $nodeId -Context "$context nodeId") {
        if ($nodesById.ContainsKey($nodeId)) {
            Add-ValidationError "Duplicate nodeId '$nodeId'."
        } else {
            $nodesById[$nodeId] = $contract
        }
    }

    $lifecycle = Get-RequiredProperty -Object $contract -Name 'lifecycle' -Context $context
    if ($null -ne $lifecycle -and $lifecycle -notin @('production', 'planned')) {
        Add-ValidationError "$context lifecycle must be production or planned."
    }

    $provisioningPath = Get-RequiredProperty -Object $contract -Name 'provisioningPath' -Context $context
    if ($provisioningPath -isnot [string] -or [string]::IsNullOrWhiteSpace($provisioningPath)) {
        Add-ValidationError "$context provisioningPath must be a non-empty repository-relative path."
    } else {
        $resolvedPath = Join-Path $RepositoryRoot $provisioningPath
        if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
            Add-ValidationError "$context provisioningPath does not exist: $provisioningPath"
        }
    }

    $dataRoot = Get-RequiredProperty -Object $contract -Name 'dataRoot' -Context $context
    if ($dataRoot -isnot [string] -or -not $dataRoot.StartsWith('/')) {
        Add-ValidationError "$context dataRoot must be an absolute Linux path."
    }

    $managementEndpoints = Get-RequiredProperty -Object $contract -Name 'managementEndpoints' -Context $context
    if ($null -ne $managementEndpoints) {
        foreach ($endpoint in @($managementEndpoints)) {
            $exposure = Get-RequiredProperty -Object $endpoint -Name 'exposure' -Context "$context management endpoint"
            if ($exposure -eq 'public') {
                Add-ValidationError "$context exposes a management endpoint publicly."
            }
            $portProperty = $endpoint.PSObject.Properties['port']
            if ($null -ne $portProperty) {
                [void](Test-PortNumber -Value $portProperty.Value -Context "$context management endpoint port" -AllowNull)
            }
        }
    }
}

$instanceKeys = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
$publicPorts = @{}

foreach ($item in $gameItems) {
    $contract = $item.Contract
    $context = "Game contract '$($item.File.Name)'"
    Test-NoSecretValues -Value $contract -Context $context

    $version = Get-RequiredProperty -Object $contract -Name 'contractVersion' -Context $context
    if ($null -ne $version -and $version -ne 1) {
        Add-ValidationError "$context has unsupported contractVersion '$version'."
    }

    $gameId = Get-RequiredProperty -Object $contract -Name 'gameId' -Context $context
    $instanceId = Get-RequiredProperty -Object $contract -Name 'instanceId' -Context $context
    $gameIdValid = Test-Identifier -Value $gameId -Context "$context gameId"
    $instanceIdValid = Test-Identifier -Value $instanceId -Context "$context instanceId"
    if ($gameIdValid -and $instanceIdValid) {
        $instanceKey = "${gameId}/${instanceId}"
        if (-not $instanceKeys.Add($instanceKey)) {
            Add-ValidationError "Duplicate game/instance ID '$instanceKey'."
        }
    }

    $lifecycle = Get-RequiredProperty -Object $contract -Name 'lifecycle' -Context $context
    if ($null -ne $lifecycle -and $lifecycle -notin @('production', 'planned')) {
        Add-ValidationError "$context lifecycle must be production or planned."
    }

    $nodeId = Get-RequiredProperty -Object $contract -Name 'nodeId' -Context $context
    if ($nodeId -isnot [string] -or -not $nodesById.ContainsKey($nodeId)) {
        Add-ValidationError "$context references unknown nodeId '$nodeId'."
    } elseif ($lifecycle -eq 'production' -and $nodesById[$nodeId].lifecycle -ne 'production') {
        Add-ValidationError "$context production instance must run on a production node."
    }

    $image = Get-RequiredProperty -Object $contract -Name 'image' -Context $context
    if ($null -ne $image) {
        $tagRequired = Get-RequiredProperty -Object $image -Name 'tagRequired' -Context "$context image policy"
        $digestRequired = Get-RequiredProperty -Object $image -Name 'digestRequired' -Context "$context image policy"
        if ($tagRequired -ne $true -or $digestRequired -ne $true) {
            Add-ValidationError "$context image policy must require both tag and digest."
        }

        $reference = Get-RequiredProperty -Object $image -Name 'reference' -Context "$context image"
        if ($lifecycle -eq 'production') {
            if ($reference -isnot [string] -or
                $reference -notmatch '^[^@\s:]+(?:/[^@\s:]+)*:[^@\s]+@sha256:[0-9a-f]{64}$') {
                Add-ValidationError "$context production image must be pinned to a non-empty tag and sha256 digest."
            }
        } elseif ($null -ne $reference -and
            ($reference -isnot [string] -or
                $reference -notmatch '^[^@\s:]+(?:/[^@\s:]+)*:[^@\s]+@sha256:[0-9a-f]{64}$')) {
            Add-ValidationError "$context planned image, when set, must be pinned to a tag and sha256 digest."
        }
    }

    $deploymentPath = Get-RequiredProperty -Object $contract -Name 'deploymentPath' -Context $context
    if ($lifecycle -eq 'production' -and
        ($deploymentPath -isnot [string] -or [string]::IsNullOrWhiteSpace($deploymentPath))) {
        Add-ValidationError "$context production deploymentPath must be set."
    }
    if ($deploymentPath -is [string] -and -not [string]::IsNullOrWhiteSpace($deploymentPath)) {
        $resolvedDeploymentPath = Join-Path $RepositoryRoot $deploymentPath
        if (-not (Test-Path -LiteralPath $resolvedDeploymentPath -PathType Leaf)) {
            Add-ValidationError "$context deploymentPath does not exist: $deploymentPath"
        } elseif ($null -ne $image) {
            $reference = $image.PSObject.Properties['reference'].Value
            if ($reference -is [string]) {
                $deploymentContent = Get-Content -LiteralPath $resolvedDeploymentPath -Raw -Encoding UTF8
                if (-not $deploymentContent.Contains("image: $reference")) {
                    Add-ValidationError "$context image reference does not match deploymentPath '$deploymentPath'."
                }
            }
        }
    }

    $ports = Get-RequiredProperty -Object $contract -Name 'ports' -Context $context
    if ($null -ne $ports) {
        foreach ($port in @($ports)) {
            $name = Get-RequiredProperty -Object $port -Name 'name' -Context "$context port"
            $protocol = Get-RequiredProperty -Object $port -Name 'protocol' -Context "$context port '$name'"
            $exposure = Get-RequiredProperty -Object $port -Name 'exposure' -Context "$context port '$name'"
            $audience = Get-RequiredProperty -Object $port -Name 'audience' -Context "$context port '$name'"
            $publicPort = Get-RequiredProperty -Object $port -Name 'publicPort' -Context "$context port '$name'"
            $privatePort = Get-RequiredProperty -Object $port -Name 'privatePort' -Context "$context port '$name'"

            if ($protocol -notin @('tcp', 'udp')) {
                Add-ValidationError "$context port '$name' protocol must be tcp or udp."
            }
            [void](Test-PortNumber -Value $publicPort -Context "$context port '$name' publicPort" -AllowNull)
            [void](Test-PortNumber -Value $privatePort -Context "$context port '$name' privatePort")

            if ($exposure -eq 'public') {
                if ($null -eq $publicPort) {
                    Add-ValidationError "$context public port '$name' must set publicPort."
                }
                if ($audience -ne 'players') {
                    Add-ValidationError "$context publicly exposes admin or monitoring API '$name'."
                }
                if ($nodeId -is [string] -and $null -ne $publicPort -and $protocol -is [string]) {
                    $publicKey = "${nodeId}:${publicPort}/${protocol}"
                    if ($publicPorts.ContainsKey($publicKey)) {
                        Add-ValidationError "Duplicate public port '$publicPort/$protocol' on node '$nodeId' in $context and $($publicPorts[$publicKey])."
                    } else {
                        $publicPorts[$publicKey] = $context
                    }
                }
            } elseif ($null -ne $publicPort) {
                Add-ValidationError "$context non-public port '$name' must set publicPort to null."
            }
        }
    }

    $edgeRoutesProperty = $contract.PSObject.Properties['edgeRoutes']
    if ($null -ne $edgeRoutesProperty) {
        foreach ($route in @($edgeRoutesProperty.Value)) {
            $routeName = Get-RequiredProperty -Object $route -Name 'name' -Context "$context edge route"
            $edgeNodeId = Get-RequiredProperty -Object $route -Name 'edgeNodeId' -Context "$context edge route '$routeName'"
            $publicPort = Get-RequiredProperty -Object $route -Name 'publicPort' -Context "$context edge route '$routeName'"
            $backendPort = Get-RequiredProperty -Object $route -Name 'backendPort' -Context "$context edge route '$routeName'"
            $protocol = Get-RequiredProperty -Object $route -Name 'protocol' -Context "$context edge route '$routeName'"
            $routeSecret = Get-RequiredProperty -Object $route -Name 'backendKeyVaultSecretName' -Context "$context edge route '$routeName'"

            [void](Test-PortNumber -Value $publicPort -Context "$context edge route '$routeName' publicPort")
            [void](Test-PortNumber -Value $backendPort -Context "$context edge route '$routeName' backendPort")
            if ($protocol -notin @('tcp', 'udp')) {
                Add-ValidationError "$context edge route '$routeName' protocol must be tcp or udp."
            }
            if ($edgeNodeId -isnot [string] -or -not $nodesById.ContainsKey($edgeNodeId)) {
                Add-ValidationError "$context edge route '$routeName' references unknown edgeNodeId '$edgeNodeId'."
            } elseif ($nodesById[$edgeNodeId].platform -ne 'azure-vm' -or
                $nodesById[$edgeNodeId].lifecycle -ne 'production') {
                Add-ValidationError "$context edge route '$routeName' must use a production Azure edge node."
            }
            if ($routeSecret -isnot [string] -or
                $routeSecret -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
                Add-ValidationError "$context edge route '$routeName' backendKeyVaultSecretName must be lower-case kebab-case."
            }

            $matchingBackendPort = @($ports | Where-Object {
                $_.privatePort -eq $backendPort -and
                $_.protocol -eq $protocol -and
                $_.exposure -eq 'tailnet' -and
                $_.audience -eq 'players'
            })
            if ($matchingBackendPort.Count -eq 0) {
                Add-ValidationError "$context edge route '$routeName' must target a declared tailnet player port."
            }

            if ($edgeNodeId -is [string] -and $null -ne $publicPort -and $protocol -is [string]) {
                $publicKey = "${edgeNodeId}:${publicPort}/${protocol}"
                if ($publicPorts.ContainsKey($publicKey)) {
                    Add-ValidationError "Duplicate public port '$publicPort/$protocol' on node '$edgeNodeId' in $context and $($publicPorts[$publicKey])."
                } else {
                    $publicPorts[$publicKey] = "$context edge route '$routeName'"
                }
            }
        }
    }

    $persistentPaths = Get-RequiredProperty -Object $contract -Name 'persistentPaths' -Context $context
    if ($null -eq $persistentPaths -or @($persistentPaths).Count -eq 0) {
        Add-ValidationError "$context must declare at least one persistent path."
    } else {
        foreach ($path in @($persistentPaths)) {
            $hostPath = Get-RequiredProperty -Object $path -Name 'hostPath' -Context "$context persistent path"
            if ($hostPath -isnot [string] -or -not $hostPath.StartsWith('/')) {
                Add-ValidationError "$context persistent hostPath must be an absolute Linux path."
            }
        }
    }

    $limits = Get-RequiredProperty -Object $contract -Name 'limits' -Context $context
    if ($null -ne $limits) {
        $cpus = Get-RequiredProperty -Object $limits -Name 'cpus' -Context "$context limits"
        $memory = Get-RequiredProperty -Object $limits -Name 'memory' -Context "$context limits"
        if ($cpus -isnot [int] -and $cpus -isnot [long] -and $cpus -isnot [double] -or $cpus -le 0) {
            Add-ValidationError "$context limits.cpus must be greater than zero."
        }
        if ($memory -isnot [string] -or $memory -notmatch '^[1-9][0-9]*(?:M|G)$') {
            Add-ValidationError "$context limits.memory must use a positive M or G value."
        }
    }

    $probes = Get-RequiredProperty -Object $contract -Name 'probes' -Context $context
    if ($null -eq $probes -or @($probes).Count -eq 0) {
        Add-ValidationError "$context must declare at least one probe."
    }

    $backupPolicy = Get-RequiredProperty -Object $contract -Name 'backupPolicy' -Context $context
    if ($null -eq $backupPolicy) {
        Add-ValidationError "$context must declare a backup policy."
    } else {
        foreach ($field in @('strategy', 'targets', 'retention')) {
            [void](Get-RequiredProperty -Object $backupPolicy -Name $field -Context "$context backupPolicy")
        }
        if ($null -eq $backupPolicy.PSObject.Properties['targets'] -or @($backupPolicy.targets).Count -eq 0) {
            Add-ValidationError "$context backupPolicy.targets must not be empty."
        }
    }

    $updatePolicy = Get-RequiredProperty -Object $contract -Name 'updatePolicy' -Context $context
    if ($null -eq $updatePolicy) {
        Add-ValidationError "$context must declare an update policy."
    } else {
        foreach ($field in @('imageUpdates', 'deployment', 'automatic')) {
            [void](Get-RequiredProperty -Object $updatePolicy -Name $field -Context "$context updatePolicy")
        }
    }

    $secrets = Get-RequiredProperty -Object $contract -Name 'requiredSecretNames' -Context $context
    if ($null -ne $secrets) {
        foreach ($secretName in @($secrets)) {
            if ($secretName -isnot [string] -or $secretName -notmatch '^[A-Z][A-Z0-9_]*$') {
                Add-ValidationError "$context requiredSecretNames entries must be upper snake case names."
            }
        }
    }
}

foreach ($relativePath in @(
    'docker/azure/docker-compose.yml',
    'docker/proxmox/docker-compose.yml',
    'docker/palworld/docker-compose.yml',
    'docker/windrose/docker-compose.yml'
)) {
    $composePath = Join-Path $RepositoryRoot $relativePath
    if (-not (Test-Path -LiteralPath $composePath -PathType Leaf)) {
        Add-ValidationError "Production compose file not found: $relativePath"
        continue
    }

    $lineNumber = 0
    foreach ($line in @(Get-Content -LiteralPath $composePath -Encoding UTF8)) {
        $lineNumber++
        if ($line -match '^\s*image:\s*(?<reference>\S+)\s*$') {
            $reference = $Matches.reference
            if ($reference -notmatch '^[^@\s:]+(?:/[^@\s:]+)*:[^@\s]+@sha256:[0-9a-f]{64}$') {
                Add-ValidationError "$relativePath`:$lineNumber production image '$reference' is not pinned to tag and sha256 digest."
            }
        }

        if ($line -match '^\s*(?<name>[A-Z][A-Z0-9_]*):\s*(?<value>.+?)\s*$') {
            $settingName = $Matches.name
            $settingValue = $Matches.value.Trim('"', "'")
            if ($settingName -match '(?:PASSWORD|SECRET|TOKEN|AUTHKEY|API_KEY|PRIVATE_KEY)' -and
                $settingValue -notmatch '^\$\{[A-Z][A-Z0-9_]*(?::[-?][^}]*)?\}$' -and
                $settingValue -notmatch '^file:/' -and
                $settingValue -notmatch '^/run/secrets/') {
                Add-ValidationError "$relativePath`:$lineNumber commits a value for secret setting '$settingName'; use interpolation or a secret file."
            }
        }
    }
}

$trackedEnvFiles = @(
    & git -C $RepositoryRoot ls-files -- '*.env' '.env' 2>$null |
        Where-Object { $_ -and $_ -notlike 'old/*' }
)
if ($LASTEXITCODE -eq 0 -and $trackedEnvFiles.Count -gt 0) {
    foreach ($envFile in $trackedEnvFiles) {
        Add-ValidationError "Tracked environment file may contain committed secret values: $envFile"
    }
}

if ($errors.Count -gt 0) {
    $message = "Game contract validation failed with $($errors.Count) error(s):`n - " +
        ($errors -join "`n - ")
    throw $message
}

Write-Host "Validated $($nodeItems.Count) node contracts and $($gameItems.Count) game contracts."
Write-Host "Production images, public ports, admin exposure, persistence, backup/update policy, and secret handling are valid."
