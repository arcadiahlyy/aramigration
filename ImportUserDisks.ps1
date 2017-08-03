Param (
    [parameter(Mandatory=$true, ValueFromPipeline=$true,HelpMessage="Destination SMB Share")] [String]$SMBShare,
    [parameter(Mandatory=$true, ValueFromPipeline=$true,HelpMessage="Storage Account Name")] [String]$storageAccountName,
    [parameter(Mandatory=$true, ValueFromPipeline=$true,HelpMessage="SAS key for accessing UserDisks")] [String]$sasKey
    )


function log
{
    param([string]$message)

    "`n`n$(get-date -f o)  $message"
}


function GetDriveLetterForImage
{
    param
    (
        [string]$ImagePathFull
    )

    (get-diskimage $ImagePathFull | get-disk | Get-Partition | Get-Volume).DriveLetter
}

function Unzip
{
    param([string]$ZipFile, [string]$Destination)
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipFile, $Destination)
}

function InstallXDrive
{
    $StorageAccountName = "hostxdrive"
    $sasToken = "?sv=2015-04-05&sr=c&si=aravhdexport&sig=ieNdXenW0uEleuBwNmMrAIgbCRn3fTHk4Tk0ayFiYIw%3D"
    $containerName = "remoteappmigration"
    $destinationPath = ".\XDriveBinaries"

    if (-not (Test-Path -Path $destinationPath))
    {
        # Get storage account context using the SAS Token
        $context = New-AzureStorageContext -StorageAccountName $StorageAccountName -SasToken $sasToken -ErrorAction Stop

        # Create a directory to download setup files for RemoteApp migration
        if(-not (Test-Path -Path $destinationPath)) 
        { 
            New-Item -ItemType Directory -Path $destinationPath | Out-Null
        } 

        $blobs = Get-AzureStorageBlob -Container $containerName -Context $context
        log "Downloading XDrive binaries..."

        foreach ($blob in $blobs)
        {
            Get-AzureStorageBlobContent -Blob $blob.Name -Container $containerName -Destination $destinationPath -Context $context -Force -ErrorAction Stop | Out-Null
        }

        # Unzip the XDrive binaries
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        unzip ($destinationPath + "\xdrive.zip") "XDrive"

        # Install driver
        pushd XDrive\Debug
        
        try
        {
            $result = (.\Xdrives.exe /driver)[3]

            $installedTxt = "Device Driver service already exists"

            if (($result -ne "Successfully installed XDrive Drivers") -and
                ($result -notmatch $installedTxt))
            {
                $ErrMsg = "Failed to install XDrive driver: " + $result
                throw $ErrMsg
            }
            else
            {
                if ($result -match $installedTxt)
                {
                    Write-Host "Enabling previously-installed XDrive driver..."
                    $ser = Get-PnpDevice -FriendlyName "WA Drive Miniport"
                    Enable-PnpDevice -InstanceId $ser.InstanceId -Confirm:$false -ErrorAction Stop | Out-Null
                }

                log "XDrive driver installed"
            }
        }
        catch
        {
            throw
        }
        finally
        {
            popd
        }
    }
    else
    {
        log "Skipping install of XDrive driver since already installed"
    }
}

function ConstructXDISKURL
{
    param
    (
        [string]$storageAccountName,
        [string]$containerName,
        [string]$blobName,
        [string]$sasToken
    )

    $storageURL = $storageAccountName + ".blob.core.windows.net"
    $ip = ([System.Net.Dns]::GetHostAddresses($storageURL)).IPAddressToString

    $xdiskURL = "XDISK:" + $ip + "/" + $storageAccountName + "/" + $containerName + "/" + $blobName + $sasToken + ",,0,blob.core.windows.net"

    $xdiskURL
}

function MountXDrive
{
    param
    (
        [string]$xdiskURL
    )

    $beforeMount = (Get-Volume).DriveLetter

    $result = (.\XDrive\Debug\Xdrives.exe /attach $xdiskURL)[3]

    if ($result -ne "Attaching returned: 0x0")
    {
        $ErrMsg = "Failed to mount UserDisk: " + $result
        throw $ErrMsg
    }

    $afterMount = (Get-Volume).DriveLetter
    if($afterMount.Count - $beforeMount.Count -ne 1) 
    {
        throw "Unable to figure out the mounted drive letter!"
    }

    $setuppath = ""
    foreach($vol in $afterMount) {
        if(-not $beforeMount.Contains($vol)) 
        {
            $setuppath = $vol + ":\"
        }
    }

    $setuppath
}

function UnmountXDrive
{
    param
    (
        [string]$xdiskURL,
        [string]$driveLetter
    )

    try
    {
        $result = .\XDrive\Debug\Xdrives.exe /detach $xdiskURL
        $result[3]
    }
    catch
    {
        log "Error unmounting XDrive"
    }
}


function CopyDocumentsIntoNewVHDX
{
    param
    (
        [string]$srcXDiskURL,
        [string]$targetFileNamePath
    )

    try
    {
        $mountedDest = $false

        # Mount source disk
        $src = MountXDrive -xdiskURL $srcXDiskURL

        log("Drive letter: " + $src)

        # Mount target disk
        $currDir = (get-item -path ".\" -Verbose).FullName
        $targetFileNamePathFull = $currDir + "\" + $targetFileNamePath

        Mount-DiskImage -ImagePath $targetFileNamePathFull
        $mountedDest = $true
        $dest = (GetDriveLetterForImage -ImagePathFull $targetFileNamePathFull) + ":\"

        log("Mounted target VHD: " + $targetFileNamePath)

        # Wait for disks to be ready
        Sleep 5

        log "Starting Robocopy..."
        $excludeFiles = $src + "System Volume Information"
        robocopy $src $dest *.* /mir /sec /copyall /xd $excludeFiles /nfl /ndl /np /V /XJ

        if ($LASTEXITCODE -gt 7)
        {
            $ErrMsg = "Robocopy error: " + $LASTEXITCODE
            throw $ErrMsg
        }
        else
        {
            log "Completed Robocopy"
        }
    }
    catch
    {
        log "Failed to migrate userdisk"
        $error[0].Exception
        throw
    }
    finally
    {
        # Note that we ALWAYS unmount XDrive - avoid cases where XDrive actually mounts a disk, but returned error
        UnmountXDrive -xdiskURL $xdiskURL -driveLetter $src

        if ($mountedDest)
        {
            Dismount-DiskImage -ImagePath $targetFileNamePathFull
        }
    }
}


$retVal = 0


$DestinationFolder = ".\UVHDExport"
$templateFilename = "UVHD-template.vhdx"
$templateSrcPath = $SMBShare + "\" + $templateFilename
$ContainerName = "uvhds"

$oldCurrentDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
try
{
    [Environment]::CurrentDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
    InstallXDrive
}
catch
{
    log "Failed to install XDrive driver"
    $error[0].Exception
    throw
}
finally {
    [Environment]::CurrentDirectory = $oldCurrentDirectory
}


New-Item -Path $DestinationFolder -ItemType Directory -Force | out-null

log "Copying template VHDX from fileshare"
Copy-Item -Path $templateSrcPath $DestinationFolder | Out-Null

$Ctx = new-azurestoragecontext -StorageAccountName $storageAccountName -SasToken $sasKey
$blobs = Get-AzureStorageblob -context $Ctx -Container $ContainerName


# Download, convert and move user disks
log("Processing " + $blobs.Count + " user disks")

foreach ($blob in $blobs)
{
    $upn= $blob.Name

    try {
        $objUser = New-Object System.Security.Principal.NTAccount($upn)
        $strSID = $objUser.Translate([System.Security.Principal.SecurityIdentifier])

        $vhdxFileName = "UVHD-" + $strSID.Value + ".vhdx"
        $vhdxPath = $DestinationFolder + "\" + $vhdxFileName

        if (-not (Test-Path -Path ($SMBShare + "\" + $vhdxFileName)))
        {
		    # Copy the template VHD, to create an empty VHDx UserDisk
		    Copy-Item -Path ($DestinationFolder + "\" + $templateFilename) -Destination $vhdxPath

            log("Migrating documents in blob " + $upn + " to destination " + $vhdxFileName)

            $xdiskURL = ConstructXDISKURL `
                    -storageAccountName $storageAccountName `
                    -containerName $ContainerName `
                    -blobName $upn `
                    -sasToken $sasKey

            CopyDocumentsIntoNewVHDX `
                    -srcXDiskURL $xdiskURL `
                    -targetFileNamePath $vhdxPath

            log("Copying " + $vhdxPath + " to " + $SMBShare)

            Copy-Item $vhdxPath $SMBShare -ErrorAction Stop
            Remove-Item -Path $vhdxPath -Force

            $time = (get-date).ToShortTimeString();
            log($time + ": Done processing user disks with upn: " +  $upn)
        }
        else
        {
            log("Skipping since vhdx already exists for " + $upn)
        }
    }
    catch {
		$retVal = 1
        log "Failed to process user disk for user: $upn with user id: $strSID"
        $error[0].Exception
    }
}

log("Removing folder: " + $DestinationFolder)
Remove-Item -Path $DestinationFolder -Force -Recurse

# Disable XDrive
if (Get-Module -ListAvailable -Name PnpDevice) {
    Write-Host "Disabling XDrive driver..."
    $ser = Get-PnpDevice -FriendlyName "WA Drive Miniport"
    Disable-PnpDevice -InstanceId $ser.InstanceId -Confirm:$false -ErrorAction Stop | Out-Null
} else {
    Write-Host "Please manually disable XDrive driver from device manager if needed"
    $retVal = 1
}



exit $retVal
