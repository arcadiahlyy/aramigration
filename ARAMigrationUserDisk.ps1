<#
.SYNOPSIS
    Script to migrate user disk out of Azure RemoteApp

.DESCRIPTION
    This script migrates user disk out of Azure RemoteApp, converts it to a format that can be used by RDS on premise deployment and populates them in a SMB share.
    It must be executed by a domain user who is an admin on the Azure subscription where Azure RemoteApp is deployed and must have write permission to the target SMB share.
    Only user disk belonging to domain users will be migrated.

.PARAMETER AzureSubscriptionName
    Name of the Azure Subscription to target.

.PARAMETER CollectionName
    Azure RemoteApp Collection Name from which user disks will be migrated out.

.PARAMETER SMBShare
    Destination SMB Share where user disks will be put.

.PARAMETER StorageAccountName
    Azure Storage Account Name where exported disks will be temporary stored.
#>
Param (
    [parameter(Mandatory=$true, ValueFromPipeline=$true,HelpMessage="Name of Azure Subscription to use")] [String]$AzureSubscriptionName = "",
    [parameter(Mandatory=$true, ValueFromPipeline=$true,HelpMessage="Azure RemoteApp Collection Name")] [String]$CollectionName = "",
    [parameter(Mandatory=$true, ValueFromPipeline=$true,HelpMessage="Destination SMB Share")] [String]$SMBShare = "",
    [parameter(Mandatory=$false, ValueFromPipeline=$true,HelpMessage="Storage Account Name (default = araexport)")] [String]$StorageAccountName = ""
    )

# Export user disks of a domain joined collection to the specified Azure Storage Account
$sasKey = ""
try {
    $sasKey = .\ExportUserDisks.ps1 -AzureSubscriptionName $AzureSubscriptionName -CollectionName $CollectionName -storageAccountName $StorageAccountName
}
catch {
    Write-Host "running ExportUserDisks.ps1 failed"
    throw
}
if($sasKey -eq $null) {
    Write-Host "running ExportUserDisks.ps1 failed"
    return
}
# Convert exported ARA user disks into vhdx format that can be used by RDS and populate them in a SMB share.
.\ImportUserDisks.ps1 -SMBShare $SMBShare -storageAccountName $StorageAccountName -sasKey $sasKey