[cmdletbinding()]
param(
    [parameter(mandatory = $true)][ValidateNotNullOrEmpty()] [string]$fsName,
    [parameter(mandatory = $true)][ValidateNotNullOrEmpty()] [string]$adminUsername,
    [parameter(mandatory = $true)][ValidateNotNullOrEmpty()] [string]$adminPassword,
    [parameter(mandatory = $true)][ValidateNotNullOrEmpty()] [string]$adDomainName,
    [parameter(mandatory = $true)][ValidateNotNullOrEmpty()] [string]$vhdFileShareName,

    [Parameter(ValueFromRemainingArguments = $true)]
    $extraParameters
)

function log
{
    param([string]$message)

    "`n`n$(get-date -f o)  $message" 
}

function SetFSACLs
{
    param
    (
    )

    log "Setting fileshare ACLs"

    $adDomainName = ($adDomainName.Split('.'))[0]
    
    Grant-SmbShareAccess -Name $vhdFileShareName -AccountName $adDomainName\rdsh-0$ -accessright full -confirm:$false
    Grant-SmbShareAccess -Name $vhdFileShareName -AccountName $adDomainName\broker$ -accessright full -confirm:$false

    set-smbpathacl -ShareName $vhdFileShareName
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


try
{
    SetFSACLs
}
catch
{
    $retVal = 1
    log "ERROR: Failed in ScriptS2D.ps1"
    throw
}
finally
{
}


log "done."

exit $retVal
