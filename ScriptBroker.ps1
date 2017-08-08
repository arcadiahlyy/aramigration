[cmdletbinding()]
param(
    [parameter(mandatory = $true)][ValidateNotNullOrEmpty()] [string]$fsName,
    [parameter(mandatory = $true)][ValidateNotNullOrEmpty()] [string]$s2dPrefix,
    [parameter(mandatory = $true)][ValidateNotNullOrEmpty()] [string]$sasKey,
    [parameter(mandatory = $true)][ValidateNotNullOrEmpty()] [string]$storageAccountName,
    [parameter(mandatory = $true)][ValidateNotNullOrEmpty()] [string]$adminUsername,
    [parameter(mandatory = $true)][ValidateNotNullOrEmpty()] [string]$adminPassword,

    [parameter(mandatory = $true)][ValidateNotNullOrEmpty()] [string]$adDomainName,
    [parameter(mandatory = $true)][ValidateNotNullOrEmpty()] [string]$vhdFileShareName,
    [parameter(mandatory = $true)][ValidateNotNullOrEmpty()] [string]$collectionName,

    [Parameter(ValueFromRemainingArguments = $true)]
    $extraParameters
)

function log
{
    param([string]$message)

    "`n`n$(get-date -f o)  $message" 
}

function ConfigureExternalFQDN
{
    param
    (
        [string]$gatewayName,
        [string]$brokerName
    )

    log "Current Gateway settings:"
    Get-RDDeploymentGatewayConfiguration | fl

    log "Setting broker external FQDN name..."
    Set-RDDeploymentGatewayConfiguration `
        -GatewayMode Custom `
        -GatewayExternalFqdn $gatewayName `
        -LogonMethod Password `
        -UseCachedCredentials $true `
        -BypassLocal $false `
        -Force

    log "New Gateway settings:"
    Get-RDDeploymentGatewayConfiguration | fl

    log "Setting Broker name..."
    .\Set-RDPublishedName.ps1 -ClientAccessName $brokerName
}


function EnableUserDisks
{
    param
    (
        [string]$fileshareName,
        [string]$fileserverName,
        [string]$vhdFileShareName
    )

    log "Userdisk fileshare: '$fileshareName'"
    log "S2D fileserver name: '$fileserverName'"

    $DiskPath = "\\" + $fileshareName + $vhdFileShareName

    $retries = 5
    $pathAvailable = $false

    while (($retries -gt 0) -and (-not $pathAvailable))
    {
        $pathAvailable = (Test-Path $DiskPath)
        if (-not $pathAvailable)
        {
            $errMsg = "Failed to call Test-Path on share: " + $DiskPath
            log $errMsg
            $retries--
            Sleep (60)
        }
    }

    if (-not $pathAvailable)
    {
        throw "All calls to Test-Path failed"
    }
	else
	{
		log "Success calling Test-Path on share"
	}


    # Enable Userdisks
    log "Calling Set-RDSessionCollectionConfiguration..."

    $retries = 20
    $setUserdisks = $false
	$UVHDFile = $DiskPath + "\UVHD-template.vhdx"

    while (($retries -gt 0) -and (-not $setUserdisks))
    {
        try
        {
			# $TODO Collection Name hardcoded
            Set-RDSessionCollectionConfiguration -CollectionName $collectionName -EnableUserProfileDisk -MaxUserProfileDiskSizeGB 10 -DiskPath $DiskPath

            # Above API is not returning error on failure, so check manually
            if (Test-Path -Path $UVHDFile)
            {
                $setUserdisks = $true
            }
            else
            {
                log "Error in Set-RDSessionCollectionConfiguration even though it returned success!"
                $retries--
                Sleep (60 * 2)
            }
        }
        catch
        {
            log "Failed to call Set-RDSessionCollectionConfiguration"
			$error[0].Exception
            $retries--
            Sleep (60 * 2)
        }
    }

    if (-not $setUserdisks)
    {
        throw "All calls to Set-RDSessionCollectionConfiguration failed"
    }
    else
    {
        log "Success calling Set-RDSessionCollectionConfiguration!"
    }
}


$retVal = 0


log "script running..."
whoami

if ($extraParameters) 
{
	log "any extra parameters:"
	$extraParameters
}

#  requires WMF 5.0

#  verify NuGet package
$nuget = get-packageprovider nuget
if (-not $nuget -or ($nuget.Version -lt 2.8.5.22))
{
	log "installing nuget package..."
	install-packageprovider -name NuGet -minimumversion 2.8.5.201 -force
}

#  install AzureRM module
#
if (-not (get-module AzureRM))
{
	log "installing AzureRm powershell module..."
	install-module AzureRM -force
}

install-module Azure -force
import-module RemoteDesktop


#  impersonate as admin 
#
log "impersonating as '$adminUsername'..."
$admincreds = New-Object System.Management.Automation.PSCredential (($adminUsername + "@" + $adDomainName), (ConvertTo-SecureString $adminPassword -AsPlainText -Force))

.\New-ImpersonateUser.ps1 -Credential $admincreds
whoami

try
{
    $gatewayName = "gateway." + $adDomainName
    $brokerName = "broker." + $adDomainName
    ConfigureExternalFQDN -gatewayName $gatewayName -brokerName $brokerName

    $fileserverName = $s2dPrefix + "-s2d-0"
    EnableUserDisks -fileshareName $fsName -fileserverName $fileserverName -vhdFileShareName $vhdFileShareName

    $SMBShare = "\\" + $fsName + "\" + $vhdFileShareName
    .\ImportUserDisks.ps1 `
        -SMBShare $SMBShare `
        -storageAccountName $storageAccountName `
        -sasKey $sasKey
	if ($LastExitCode -ne 0)
	{
		throw "Error in ImportUserDisks.ps1"
	}
}
catch
{
    $retVal = 1
    log "ERROR: Failed in ScriptBroker.ps1"
    $error[0].Exception
}
finally
{
    log "remove impersonation..."
	Remove-ImpersonateUser
	whoami
}


log "done."


exit $retVal
