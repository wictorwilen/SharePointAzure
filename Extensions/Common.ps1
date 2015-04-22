#
# Copyright="© Microsoft Corporation. All rights reserved."
#

function Decrypt
{
    param
    (
        [Parameter(Mandatory)]
        [String]$Thumbprint,

        [Parameter(Mandatory)]
        [String]$Base64EncryptedValue
    )

    # Decode Base64 string
    $encryptedBytes = [System.Convert]::FromBase64String($Base64EncryptedValue)

    # Get certificate from store
    $store = new-object System.Security.Cryptography.X509Certificates.X509Store([System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
    $store.open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    $certificate = $store.Certificates | %{if($_.thumbprint -eq $Thumbprint){$_}}

    # Decrypt
    $decryptedBytes = $certificate.PrivateKey.Decrypt($encryptedBytes, $false)
    $decryptedValue = [System.Text.Encoding]::UTF8.GetString($decryptedBytes)

    return $decryptedValue
}

function WaitForPendingMof
{
    # Check to see if there is a Pending.mof file to avoid a conflict with an
    # already in-progress SendConfigurationApply invocation.
    while ($true)
    {
        try
        {
            Get-Item -Path "$env:windir\System32\Configuration\Pending.mof" -ErrorAction Stop
            Start-Sleep -Seconds 5
        }
        catch
        {
            break
        }
    }
}

function CheckForPendingReboot
{
    param
    (
        [Parameter(Mandatory)]
        [Object[]]$Output
    )

    # The LCM doesn't notify us when there's a pending reboot, so we have to check
    # for it ourselves.
    if ($Output -match "A reboot is required to progress further. Please reboot the system.")
    {
        Start-Sleep -Seconds 5
        Restart-Computer -Force
    }
}

function WaitForSqlSetup
{
    # Wait for SQL Server Setup to finish before proceeding.
    while ($true)
    {
        try
        {
            Get-ScheduledTaskInfo "\ConfigureSqlImageTasks\RunConfigureImage" -ErrorAction Stop
            Start-Sleep -Seconds 5
        }
        catch
        {
            break
        }
    }
}

# This function implement backoff retry algorithm based
# on exponential backoff. The backoff value is truncated
# using the upper value after advancing it using the
# multiplier to govern the maximum backoff internal.
# The initial value is picked randomly between the minimum
# and upper limit with a bias towards the minimum.
function Get-TruncatedExponentialBackoffDelay([int]$PreviousBackoffDelay, [int]$LowerBackoffBoundSeconds, [int]$UpperBackoffBoundSeconds, [int]$BackoffMultiplier)
{
   [int]$delay = "0"

   if($PreviousBackoffDelay -eq 0)
   {
      $PreviousBackoffDelay = Get-Random -Minimum $LowerBackoffBoundSeconds -Maximum ($LowerBackoffBoundSeconds + ($UpperBackoffBoundSeconds / 2))
      $delay = $PreviousBackoffDelay
   }
   else
   {
       $delay = ($PreviousBackoffDelay * $BackoffMultiplier);

       if($delay -ge $UpperBackoffBoundSeconds)
       {
           $delay = $UpperBackoffBoundSeconds
       }
       elseif($delay -le $LowerBackoffBoundSeconds)
       {
           $delay = $LowerBackoffBoundSeconds
       }
   }

   return $Result = $delay
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