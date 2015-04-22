#
# Copyright="© Microsoft Corporation. All rights reserved."
#

param
(
    [Parameter(Mandatory)]
    [String]$DomainName,

    [String]$DomainNetbiosName,

    [Parameter(Mandatory)]
    [String]$UserName,

    [Parameter(Mandatory)]
    [String]$Password,

    [String]$SafeModeAdministratorPassword = $Password,

    [String]$EncryptionCertificateThumbprint
)

. "$PSScriptRoot\Common.ps1"

Start-ScriptLog

if ($EncryptionCertificateThumbprint)
{
    Write-Verbose -Message "Decrypting parameters with certificate $EncryptionCertificateThumbprint..."

    $Password = Decrypt -Thumbprint $EncryptionCertificateThumbprint -Base64EncryptedValue $Password
    $SafeModeAdministratorPassword = Decrypt -Thumbprint $EncryptionCertificateThumbprint -Base64EncryptedValue $SafeModeAdministratorPassword

    Write-Verbose -Message "Successfully decrypted parameters."
}
else
{
    Write-Verbose -Message "No encryption certificate specified. Assuming cleartext parameters."
}

configuration ADDSForest
{
    Import-DscResource -ModuleName xComputerManagement, xActiveDirectory

    Node $env:COMPUTERNAME
    {
        Script PowerPlan
        {
            SetScript = { Powercfg -SETACTIVE SCHEME_MIN }
            TestScript = { return ( Powercfg -getactivescheme) -like "*High Performance*" }
            GetScript = { return @{ Powercfg = ( "{0}" -f ( powercfg -getactivescheme ) ) } }
        }

        xDisk ADDataDisk
        {
            DiskNumber = 2
            DriveLetter = "F"
        }

        WindowsFeature ADDS
        {
            Name = "AD-Domain-Services"
            Ensure = "Present"
        }

         WindowsFeature ADDSTools            
        {             
            Ensure = "Present"             
            Name = "RSAT-ADDS"             
        }  

        xADDomain PrimaryDC
        {
            DomainAdministratorCredential = New-Object System.Management.Automation.PSCredential ("$DomainName\$UserName", $(ConvertTo-SecureString $Password -AsPlainText -Force))
            DomainName = $DomainName
            DomainNetbiosName = $DomainNetbiosName
            SafemodeAdministratorPassword = New-Object System.Management.Automation.PSCredential ("$DomainName\$UserName", $(ConvertTo-SecureString $SafeModeAdministratorPassword -AsPlainText -Force))
            DatabasePath = "F:\NTDS"
            LogPath = "F:\NTDS"
            SysvolPath = "F:\SYSVOL"
            DependsOn = "[xDisk]ADDataDisk", "[WindowsFeature]ADDS"
        }

        xADUser SPFarm 
        {
            DomainName = $DomainName
            DomainAdministratorCredential = New-Object System.Management.Automation.PSCredential ("$DomainName\$UserName", $(ConvertTo-SecureString $Password -AsPlainText -Force))
            UserName = "SPFarm" 
            Password = New-Object System.Management.Automation.PSCredential ("$DomainName\$UserName", $(ConvertTo-SecureString $Password -AsPlainText -Force))
            Ensure = "Present" 
            DependsOn = "[xADDomain]PrimaryDC" 
        }

        xADUser SPSetup 
        {
            DomainName = $DomainName
            DomainAdministratorCredential = New-Object System.Management.Automation.PSCredential ("$DomainName\$UserName", $(ConvertTo-SecureString $Password -AsPlainText -Force))
            UserName = "SPSetup" 
            Password = New-Object System.Management.Automation.PSCredential ("$DomainName\$UserName", $(ConvertTo-SecureString $Password -AsPlainText -Force))
            Ensure = "Present" 
            DependsOn = "[xADDomain]PrimaryDC" 
        }


        xADUser SQLService 
        {
            DomainName = $DomainName
            DomainAdministratorCredential = New-Object System.Management.Automation.PSCredential ("$DomainName\$UserName", $(ConvertTo-SecureString $Password -AsPlainText -Force))
            UserName = "SQLService" 
            Password = New-Object System.Management.Automation.PSCredential ("$DomainName\$UserName", $(ConvertTo-SecureString $Password -AsPlainText -Force))
            Ensure = "Present" 
            DependsOn = "[xADDomain]PrimaryDC" 
        }


        xADUser SQLAgent 
        {
            DomainName = $DomainName
            DomainAdministratorCredential = New-Object System.Management.Automation.PSCredential ("$DomainName\$UserName", $(ConvertTo-SecureString $Password -AsPlainText -Force))
            UserName = "SQLAgent" 
            Password = New-Object System.Management.Automation.PSCredential ("$DomainName\$UserName", $(ConvertTo-SecureString $Password -AsPlainText -Force))
            Ensure = "Present" 
            DependsOn = "[xADDomain]PrimaryDC" 
        }

        LocalConfigurationManager
        {
            CertificateId = $node.Thumbprint
        }
    }
}

if ($EncryptionCertificateThumbprint)
{
    $certificate = dir Cert:\LocalMachine\My\$EncryptionCertificateThumbprint
    $certificatePath = Join-Path -path $PSScriptRoot -childPath "EncryptionCertificate.cer"
    Export-Certificate -Cert $certificate -FilePath $certificatePath | Out-Null
    $configData = @{
        AllNodes = @(
            @{
                Nodename = $env:COMPUTERNAME
                CertificateFile = $certificatePath
                Thumbprint = $EncryptionCertificateThumbprint
            }
        )
    }
}
else
{
    $configData = @{
        AllNodes = @(
            @{
                Nodename = $env:COMPUTERNAME
                PSDscAllowPlainTextPassword = $true
            }
        )
    }
}


WaitForPendingMof

ADDSForest -ConfigurationData $configData -OutputPath $PSScriptRoot

$cimSessionOption = New-CimSessionOption -SkipCACheck -SkipCNCheck -UseSsl
$cimSession = New-CimSession -SessionOption $cimSessionOption -ComputerName $env:COMPUTERNAME -Port 5986

if ($EncryptionCertificateThumbprint)
{
    Set-DscLocalConfigurationManager -CimSession $cimSession -Path $PSScriptRoot -Verbose
}

# Run Start-DscConfiguration in a loop to make it more resilient to network outages.
$Stoploop = $false
$MaximumRetryCount = 5
$Retrycount = 0
$SecondsDelay = 0

do
{
    try
    {
        $error.Clear()

        Write-Verbose -Message "Attempt $Retrycount of $MaximumRetryCount ..."
        Start-DscConfiguration -CimSession $cimSession -Path $PSScriptRoot -Force -Wait -Verbose *>&1 | Tee-Object -Variable output

        if (!$error)
        {
            $Stoploop = $true
        }
    }
    catch
    {
        # $_ in the catch block to include more details about the error that occured.
        Write-Warning ("CreatePrimaryDomainController failed. Error:" + $_)

        if ($Retrycount -ge $MaximumRetryCount)
        {
            Write-Warning ("CreatePrimaryDomainController operation failed all retries")
            $Stoploop = $true
        }
        else
        {
            $SecondsDelay  = Get-TruncatedExponentialBackoffDelay -PreviousBackoffDelay $SecondsDelay -LowerBackoffBoundSeconds 10 -UpperBackoffBoundSeconds 120 -BackoffMultiplier 2
            Write-Warning -Message "An error has occurred, retrying in $SecondsDelay seconds ..."
            Start-Sleep $SecondsDelay
            $Retrycount = $Retrycount + 1
        }
    }
}
while ($Stoploop -eq $false)

CheckForPendingReboot -Output $output

Stop-ScriptLog