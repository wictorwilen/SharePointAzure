#
# Copyright="© Microsoft Corporation. All rights reserved."
#

[CmdletBinding()]
param
(
    [Parameter(Mandatory)]
    [String[]]$Modules,

    [Switch]$Force
)

function DownloadFile
{
    param
    (
        [Parameter(Mandatory)]
        [String]$Uri
    )

    $retryCount = 1
    while ($retryCount -le 3)
    {
        try
        {
            Write-Verbose  "Downloading file from '$($Uri)', attempt $retryCount of 3 ..."
            $file = "$env:TEMP\$([System.IO.Path]::GetFileName((New-Object System.Uri $Uri).LocalPath))"
            Invoke-WebRequest -Uri $Uri -OutFile $file
            break
        }
        catch
        {
            if ($retryCount -eq 3)
            {
                Write-Error -Message "Error downloading file from '$($Uri)".
                throw $_
            }

            Write-Warning -Message "Failed to download file from '$($Uri)', retrying in 30 seconds ..."
            Start-Sleep -Seconds 30
            $retryCount++
        }
    }

    Write-Verbose "Successfully downloaded file from '$($Uri)' to '$($file)'."
    return $file
}

function InstallDSCModule
{
    param
    (
        [Parameter(Mandatory)]
        [String]$ModuleSourcePath,

        [Bool]$Force
    )

    $moduleInstallPath = "$env:ProgramFiles\WindowsPowerShell\Modules"

    $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($ModuleSourcePath)
    Write-Verbose "Installing module '$($moduleName)' ..."
    $module = Get-Module -ListAvailable -Verbose:$false | Where-Object { $_.Name -eq $moduleName }
    if (!$module -or $Force)
    {
        # System.IO.Compression.ZipFile is only available in .NET 4.5. We
        # prefer it over shell.application since the former is available in
        # Server Core.
        if (![System.Reflection.Assembly]::LoadWithPartialName("System.IO.Compression.FileSystem"))
        {
            Write-Verbose "Installing the 'Net-Framework-45-Core' feature ..."
            $featureResult = Install-WindowsFeature -Name "Net-Framework-45-Core"
            if (-not $featureResult.Success)
            {
                throw "Failed to install the 'Net-Framework-45-Core' feature: $($featureResult.ExitCode)."
            }
            Write-Verbose  "Successfully installed the 'Net-Framework-45-Core' feature."
            [System.Reflection.Assembly]::LoadWithPartialName("System.IO.Compression.FileSystem")
        }
        Remove-Item -Path "$moduleInstallPath\$moduleName" -Recurse -Force -ErrorAction Ignore
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ModuleSourcePath, $moduleInstallPath)
        Write-Verbose "Successfully installed module '$($moduleName)' to '$("$moduleInstallPath\$moduleName")'."
    }
    else
    {
        Write-Verbose "Module '$($moduleName)' is already installed at '$($module.Path)', skipping."
    }
}

# This function starts script logging and saves it to a local file
# Logging is under the current SystemDrive under DeploymentLogs folder.
# If the folder does not exists, then it is created.
function Start-ScriptLog
{
    $logDirectory = $env:SystemDrive + "\DeploymentLogs"
    $logFilePath = $logDirectory + "\log.txt"

    if(!(Test-Path -Path $logDirectory ))
    {
        New-Item -ItemType Directory -Path $logDirectory
    }

    try
    {
       Start-Transcript -Path $logFilePath -Append -Force
    }
    catch
    {
      Stop-Transcript
      Start-Transcript -Path $logFilePath -Append -Force
    }

    Set-PSDebug -Trace 0;
}


function Stop-ScriptLog
{
    Stop-Transcript
}



Start-ScriptLog

$VerbosePreference = 'Continue'


# Download the required DSC modules for this node.
foreach ($module in $Modules)
{
    # We support fetching the DSC modules ourselves...
    if (($module -as [System.Uri]).AbsoluteURI)
    {
        $module = DownloadFile -Uri $module
    }
    #... or having the Custom Script extension do it for us.
    else
    {
        $module = "$PSScriptRoot\$module"

        # Coalesce the module name in case the extension was omitted.
        if (-not $module.EndsWith(".zip"))
        {
            $module = "$module.zip"
        }
    }

    InstallDSCModule -ModuleSourcePath $module -Force $Force
}

# WMF 4.0 is a prerequisite. We install this last since it will reboot the node.
if ($PSVersionTable.PSVersion.Major -lt 4)
{
    # Check to see if the Custom Script extension has already downloaded
    #   WMF 4.0 for us.
    $msu = "$PSScriptRoot\Windows8-RT-KB2799888-x64.msu"
    if (-not (Test-Path $msu))
    {
        # If not, we fetch it ourselves.
        Write-Verbose -Message "Downloading WMF 4.0 ..."
        $msu = DownloadFile -Uri "http://download.microsoft.com/download/3/D/6/3D61D262-8549-4769-A660-230B67E15B25/Windows8-RT-KB2799888-x64.msu"
        Write-Verbose -Message "Successfully downloaded WMF 4.0."
    }

    Write-Verbose -Message "Installing WMF 4.0 (KB2799888) ..."
    Start-Process -FilePath "$env:SystemRoot\System32\wusa.exe" -ArgumentList "$msu /quiet /norestart" -Wait
    Write-Verbose "Successfully installed WMF 4.0, restarting the computer ..."

    # Installing WMF 4.0 always requires a restart.
    Start-Sleep -Seconds 5
    Restart-Computer -Force
}

Stop-ScriptLog