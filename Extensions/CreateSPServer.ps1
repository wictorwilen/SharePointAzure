
param
(
    [Parameter(Mandatory)]
    [String]$DomainName,

    [Parameter(Mandatory)]
    [String]$domainNetBiosName,

    [Parameter(Mandatory)]
    [String]$DomainAdministratorUserName,

    [Parameter(Mandatory)]
    [String]$DomainAdministratorPassword,

    [Parameter(Mandatory)]
    [String]$ServiceUserName,

    [Parameter(Mandatory)]
    [String]$ServicePassword,

    [String]$EncryptionCertificateThumbprint
)

. "$PSScriptRoot\Common.ps1"

Start-ScriptLog

if ($EncryptionCertificateThumbprint)
{
    Write-Verbose -Message "Decrypting parameters with certificate $EncryptionCertificateThumbprint..."

    $DomainAdministratorPassword = Decrypt -Thumbprint $EncryptionCertificateThumbprint -Base64EncryptedValue $DomainAdministratorPassword

    Write-Verbose -Message "Successfully decrypted parameters."
}
else
{
    Write-Verbose -Message "No encryption certificate specified. Assuming cleartext parameters."
}

configuration SPServer
{
    Import-DscResource -ModuleName xComputerManagement, xSQLServer

    Node $env:COMPUTERNAME
    {
        Script PowerPlan
        {
            SetScript = { Powercfg -SETACTIVE SCHEME_MIN }
            TestScript = { return ( Powercfg -getactivescheme) -like "*High Performance*" }
            GetScript = { return @{ Powercfg = ( "{0}" -f ( powercfg -getactivescheme ) ) } }
        }

        xDisk DataDisk
        {
            DiskNumber = 2
            DriveLetter = "F"
        }

        xDisk SqlDisk
        {
            DiskNumber = 3
            DriveLetter = "S"
        }

        Script configureWS {
            SetScript =
@"
# https://powertoe.wordpress.com/2011/04/29/enable-credssp-from-a-windows-7-home-client/  
Enable-WSManCredSSP -Role Client -DelegateComputer '*.$DomainName' -Force
Enable-WSManCredSSP Server
`$allowed = @('WSMAN/*.$DomainName','WSMAN/$($env:COMPUTERNAME)')  

`$key = 'hklm:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation'
if (!(Test-Path `$key)) {
    md `$key
}
New-ItemProperty -Path `$key -Name AllowFreshCredentials -Value 1 -PropertyType Dword -Force            

`$key = Join-Path `$key 'AllowFreshCredentials'
if (!(Test-Path `$key)) {
    md `$key
}
`$i = 1
`$allowed |% {
    New-ItemProperty -Path `$key -Name `$i -Value `$_ -PropertyType String -Force
    `$i++
}
# We need to restart WinRM, but restarting the service just makes it stuck in stopping
# Since we're doing the BEFORE joining the domain, that will happen automagically
"@
            GetScript = {
                 return @{WinRM = "something"}
            }
            TestScript ={
                return -not (Get-WSManCredSSP)[1].Contains("not configured")
            }
        }


        xComputer DomainJoin
        {
            Name = $env:COMPUTERNAME
            DomainName = $DomainName
            Credential = New-Object System.Management.Automation.PSCredential ("$domainNetBiosName\$DomainAdministratorUserName", $(ConvertTo-SecureString $DomainAdministratorPassword -AsPlainText -Force))
            DependsOn = "[Script]configureWS"
        }


        WindowsFeature ADPS
        {
            Name = "RSAT-AD-PowerShell"
            Ensure = "Present"
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

SPServer -ConfigurationData $configData -OutputPath $PSScriptRoot

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
        Write-Warning ("CreateSPServer failed. Error:" + $_)

        if ($Retrycount -ge $MaximumRetryCount)
        {
            Write-Warning ("CreateSPServer operation failed all retries")
            $Stoploop = $true
        }
        else
        {
            $SecondsDelay = Get-TruncatedExponentialBackoffDelay -PreviousBackoffDelay $SecondsDelay -LowerBackoffBoundSeconds 10 -UpperBackoffBoundSeconds 120 -BackoffMultiplier 2
            Write-Warning -Message "An error has occurred, retrying in $SecondsDelay seconds ..."
            Start-Sleep $SecondsDelay
            $Retrycount = $Retrycount + 1
        }
    }
}
while ($Stoploop -eq $false)

CheckForPendingReboot -Output $output

Stop-ScriptLog
