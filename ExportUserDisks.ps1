<#
.SYNOPSIS
    Script to export user disk out of Azure RemoteApp, into an Azure storage account.

.DESCRIPTION
    This script migrates user disk out of Azure RemoteApp, into an Azure storage account.
    This script requires the target collection to be domain joined, otherwise although the UPDs will be still migrated out, it won't usable in RDS on premise deployment.

.PARAMETER AzureSubscriptionName
    Name of the Azure Subscription to target.

.PARAMETER CollectionName
    Azure RemoteApp Collection Name from which user disks will be migrated out.

.PARAMETER storageAccountName
    Azure Storage Account Name where exported disks will be temporary stored.
#>
Param (
    [parameter(Mandatory=$true, ValueFromPipeline=$true,HelpMessage="Name of Azure Subscription to use")] [String]$AzureSubscriptionName = "",
    [parameter(Mandatory=$true, ValueFromPipeline=$true,HelpMessage="Azure RemoteApp Collection Name")] [String]$CollectionName = "",
    [parameter(Mandatory=$true, ValueFromPipeline=$true,HelpMessage="Storage Account Name")] [String]$storageAccountName = ""
    )


# trackingItemId - the trackingId of the item
# timeoutSeconds - timeout in seconds
# return: status of the operation result
Function WaitForWorkItemComplete($trackingItemId, $timeoutSeconds)
{
    $startTime = Get-Date
    while($true) {
        try {
            $res = Get-AzureRemoteAppOperationResult -TrackingId $trackingItemId
  
        } catch {
            Write-Host "Get-AzureRemoteAppOperationResult failed, tracking id: " $trackingItemId
            return "Exception"
        }

        if($res.Status -ne "InProgress"){
            return $res.Status
        }
        $now = Get-Date
        if ( $now -gt $startTime.AddSeconds($timeoutSeconds) ) {
            return "TimedOut"
        }
        Start-Sleep -Seconds 60
    }
}

Function CreateSASForUserVHDContainer
{
    param
    (
        [string]$StorageAccountName,
        [string]$StorageAccountKey,
        [string]$ContainerName
    )

    $Ctx = New-AzureStorageContext $StorageAccountName -StorageAccountKey $StorageAccountKey

    $expiryTime = (Get-Date).AddDays(5)
    $PolicyName = "aravhdexport"

    $policyList = Get-AzureStorageContainerStoredAccessPolicy -Container $ContainerName -Context $Ctx
    if(($policyList.Policy -eq $null) -or ($policyList.Policy.Contains("aravhdexport") -eq $false))
    {
        New-AzureStorageContainerStoredAccessPolicy -Container $ContainerName -Policy $PolicyName -Context $Ctx -ExpiryTime $expiryTime -Permission rwl | Out-Null
    }
    else {
        Set-AzureStorageContainerStoredAccessPolicy -Container $ContainerName -Policy $PolicyName -Context $Ctx -ExpiryTime $expiryTime -Permission rwl | Out-Null
    }
    $sastoken = New-AzureStorageContainerSASToken -Name $ContainerName -Policy $PolicyName -Context $Ctx

    $sastoken
}



if ($AzureSubscriptionName -eq "")
{
    Write-Host "No Azure Subscription specified!"
    return
}

if ($CollectionName -eq "")
{
    Write-Host "No collection name specified!"
    return
}

if ($storageAccountName -eq "")
{
    Write-Host "No storage account name specified!"
    return
}

# Select the subscription to use
try {
    Select-AzureSubscription -SubscriptionName $AzureSubscriptionName -Current | Out-Null
}
catch
{
    $error[0].Exception
    return
}

# Check collection exists and get location
try
{
    $collection = Get-AzureRemoteAppCollection -CollectionName $CollectionName -ErrorAction Stop
    if( $collection.AdInfo -eq $null ) {
        Write-Host "Collection is NOT domain joined!"
        return
    }
    $Location = $collection.Region
}
catch
{
    $error[0].Exception
    return
}

[bool] $StorageAccountCreated = $false
# Create a new storagea account if it doesn't exist
try{

    Get-AzureStorageAccount -StorageAccountName $storageAccountName -ErrorAction Stop | Out-Null
    Write-Host "Storage account $storageAccountName in $Location location already exists, skipping creation"

    }
catch{

    try{

        New-AzureStorageAccount -StorageAccountName $storageAccountName -Location $Location -ErrorAction Stop | Out-Null
        $StorageAccountCreated = $true
    }
    catch
    {
        Write-Host "Creating storage account $storageAccountName in $Location location failed!"
        $error[0].Exception
    }    
}

# Storage account creation sometime takes time
[int] $repeatCount = 4
$StorageAccountKey = ""
try
{
    $StorageAccountKey = (Get-AzureStorageKey -StorageAccountName $storageAccountName  -ErrorAction Stop).Primary
}
catch
{
    if($repeatCount -eq 0)
    {
        $error[0].Exception
        return
    }
    else
    {
        $repeatCount--
        Start-Sleep -m 1
    }
}

# export user disks to destination storage account
$ContainerName = "uvhds"
Write-Host "Migrating user disks to destination storage account"

$trackingId = Export-AzureRemoteAppUserDisk -CollectionName $CollectionName -DestinationStorageAccountContainerName $ContainerName -DestinationStorageAccountKey $StorageAccountKey  -DestinationStorageAccountName $storageAccountName
$migrationStatus = WaitForWorkItemComplete -trackingItemId $trackingId.TrackingId -timeoutSeconds 14400
# $migrationStatus = "Success"
if($migrationStatus -eq "Failed")
{
    Write-Host "User disk migration failed, tracking id:" $trackingId.TrackingId
    Write-Host "Here're two potential issues you may hit:"
    Write-Host "    1.	At least one UPD is locked, please make sure all end users are logged off.
    2.	Export limit of 3 times has been reached, please contact us to bump it up."
    return    
}
if($migrationStatus -eq "TimedOut")
{
    Write-Host "User disk migration timed out, tracking id:" $trackingId.TrackingId
    return    
}
Write-Host "Migrating user disks to destination storage account is done with status: " $migrationStatus

$result = CreateSASForUserVHDContainer `
        -StorageAccountName $storageAccountName `
        -StorageAccountKey $StorageAccountKey `
        -ContainerName $ContainerName
[string]$resultString = $result


$resultString
