# suppress warnings that we need to use
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost', ""
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', ""
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseApprovedVerbs', ""
)]
param()

# TODO: we need to work with the offsets and limits

$_VERSION = "0.0.3"

$ErrorActionPreference = "Stop"

# fail fast
if ($null -eq $env:PLATFORM_CLIENT_ID) {
    Write-Host -ForegroundColor Red "PLATFORM_CLIENT_ID not set"
    throw "PLATFORM_CLIENT_ID not set"
}

if ($null -eq $env:PLATFORM_CLIENT_SECRET) {
    Write-Host -ForegroundColor Red "PLATFORM_CLIENT_SECRET not set"
    throw "PLATFORM_CLIENT_SECRET not set"
}

# check if the TorizonPlatformAPI module is installed
$_mod = Get-Module -ListAvailable -Name "TorizonPlatformAPI"

if (
    -not ($_mod) -or 
    ($_mod.Version[0].ToString().Contains("0.0.3") -eq $false)
) {
    Install-Module `
        -Name "TorizonPlatformAPI" `
        -RequiredVersion 0.0.3 `
        -Confirm:$false `
        -Force | Out-Null
}

Import-Module -Name "TorizonPlatformAPI" -RequiredVersion 0.0.3  | Out-Null
#Write-Host -ForegroundColor DarkGreen "✅ TorizonPlatformAPI loaded"

# get the bearer token
function _getJonOsterToken () {
    $_headers = @{
        "Content-Type" = "application/x-www-form-urlencoded"
    }
    
    $_payload = @{
        "grant_type" = "client_credentials"
        "client_id" = "$env:PLATFORM_CLIENT_ID"
        "client_secret" = "$env:PLATFORM_CLIENT_SECRET"
    }
    
    $_ret = Invoke-RestMethod `
        -Method Post `
        -Uri "https://kc.torizon.io/auth/realms/ota-users/protocol/openid-connect/token" `
        -Headers $_headers `
        -Body $_payload `
        -ContentType "application/x-www-form-urlencoded" `
        -ErrorAction Stop
    
    # and we have the AWESOME JonOster Token 🦪
    return $_ret.access_token
}

# configure the API client
$_token = _getJonOsterToken
Set-TorizonPlatformAPIConfiguration `
    -BaseUrl "https://app.torizon.io/api/v2beta" `
    -DefaultHeaders @{ "Authorization" = "Bearer $_token" } `
    -ErrorAction Stop

function _getTargetByHash ($_hash) {
    $_targets = Get-TorizonPlatformAPITargets

    Get-Member `
        -InputObject $_targets.signed.targets `
        -MemberType NoteProperty |
            ForEach-Object {
                $_propVal = $_targets.signed.targets.($_.Name)

                if ($_propVal.hashes.sha256 -eq $_hash) {
                    return $_propVal
                }
            }

    return $null
}

function _getFleetDevices ($_fleetName) {
    $_fleets = Get-TorizonPlatformAPIFleets

    $_fleetId = (
        $_fleets.values |
            Where-Object { $_.name -eq $_fleetName }
    ).id

    $_devices = 
        Get-TorizonPlatformAPIFleetsFleetidDevices `
            -FleetId $_fleetId
    
    return $_devices.values
}

function _resolvePlatformWrongMetadata () {
    $_targets = $args[0]
    $_latestV = 0
    $_hash = $null

    $_ret = [PSCustomObject]@{
        "hash" = $null
        "version" = $null
    }

    Get-Member `
        -InputObject $_targets.signed.targets `
        -MemberType NoteProperty |
            ForEach-Object {
                $_propVal = $_targets.signed.targets.($_.Name)

                if ($_propVal.custom.name -eq $_targetName) {
                    $_actualV = $_propVal.custom.commitSubject
                    if ($null -eq $_actualV) {
                        # packages are ok
                        $_actualV = [int]$_propVal.custom.version
                    } else {
                        # ostree packages are not ok
                        $_actualV = [int]$_actualV
                    }

                    if ($_latestV -lt $_actualV) {
                        $_latestV = $_actualV
                    }

                    $_hash = $_propVal.hashes.sha256
                }
            }

    $_ret.hash = $_hash
    $_ret.version = $_latestV

    return $_ret
}

function target-latest-hash () {
    $_targetName = $args[0]
    $_targets = Get-TorizonPlatformAPITargets
    $_latestV = 0
    $_hash = $null

    $_ret = _resolvePlatformWrongMetadata $_targets
    $_latestV = $_ret.version
    $_hash = $_ret.hash

    if ($null -eq $_hash) {
        Write-Host -ForegroundColor Red "target not found"
        exit 404
    }

    return $_hash
}

function target-latest-version () {
    $_targetName = $args[0]
    $_targets = Get-TorizonPlatformAPITargets
    $_latestV = 0

    $_ret = _resolvePlatformWrongMetadata $_targets

    # it's return 0 if not found (we can publish the version 1)
    return $_ret.version
}

function update-fleet-latest () {
    $_targetName = $args[0]
    $_fleetName = $args[1]

    $_targetHash = target-latest-hash $_targetName
    $_target = _getTargetByHash($_targetHash)
    $_targetVersion = $_target.custom.version
    $_hardwareId = $_target.custom.hardwareIds[0]

    $_devices = _getFleetDevices($_fleetName)

    $Checksum = 
        Initialize-TorizonPlatformAPIChecksum -Method "sha256" -Hash $_targetHash
    
    $TargetDescription = 
        Initialize-TorizonPlatformAPITargetDescription `
            -Target "$_targetName-$_targetVersion" `
            -Checksum $Checksum `
            -TargetLength 0 `
            -Uri $Null `
            -UserDefinedCustom "From ApolloX"

    $TargetUpdateRequest = 
        Initialize-TorizonPlatformAPITargetUpdateRequest -To $TargetDescription

    $MultiTargetUpdateRequest = 
        Initialize-TorizonPlatformAPIMultiTargetUpdateRequest `
            -Targets @{ "$_hardwareId" = $TargetUpdateRequest }

    $CreateUpdateRequest = 
        Initialize-TorizonPlatformAPICreateUpdateRequest `
            -Updates $MultiTargetUpdateRequest `
            -Devices $_devices
    Write-Host ($CreateUpdateRequest | ConvertTo-Json -Depth 100)

    $Result = 
        Submit-TorizonPlatformAPIUpdate `
            -CreateUpdateRequest $CreateUpdateRequest

    return $Result
}

# check if the command exists
$_cmd = $args[0]
$_sub = $args[1]
$_third = $args[2]

# is duple
if (Get-Command "$_cmd-$_sub" -ErrorAction SilentlyContinue) {
    $_args = $args[2..$args.Length] -join " "

    (Invoke-Expression "$_cmd-$_sub $_args")
# is triple
} elseif (
    Get-Command "$_cmd-$_sub-$_third" -ErrorAction SilentlyContinue
) {
    $_args = $args[3..$args.Length] -join " "

    (Invoke-Expression "$_cmd-$_sub-$_third $_args")
} else {
    Write-Host ""
    Write-Host "usage:"
    Write-Host ""
    Write-Host "    Get the latest hash pushed by target name:"
    Write-Host "        target latest hash <target name>"
    Write-Host "    Get the latest version pushed by target name:"
    Write-Host "        target latest version <target name>"
    Write-Host ""
    Write-Host "    Update a fleet with a defined target:"
    Write-Host "        update fleet latest <target name> <fleet name>"
    Write-Host ""

    exit 69
}
