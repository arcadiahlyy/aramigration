# These scripts are for exporting user disks from Azure RemoteApp collections. 
# ExportUserDisks.ps1 exports user disks of a collection to a user given Azure storage account. A SAS url of the destination storage account will be returned for further use.
# ImportUserDisks.ps1 converts exported ARA user disks (.vhd) to the format that RDS can use. New created user disks (.vhdx) will be moved to user defined SMB share for storing user disks in RDS.
# ARAMigrationUserDisk.ps1 runs ExportUserDisks.ps1 and ImportUserDisks.ps1 in order. 
