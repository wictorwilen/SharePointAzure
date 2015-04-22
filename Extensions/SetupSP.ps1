
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

configuration SPServerSoftware
{
    Import-DscResource -ModuleName xComputerManagement, xSQLServer

    Node $env:COMPUTERNAME
    {
        

        Group Administrators
        {
            Ensure = 'Present'
            GroupName = 'Administrators'
            MembersToInclude = @("$domainNetBiosName\SPSetup")
            Credential = New-Object System.Management.Automation.PSCredential ("$domainNetBiosName\$DomainAdministratorUserName", $(ConvertTo-SecureString $DomainAdministratorPassword -AsPlainText -Force))
        }

        WindowsFeature installdotNet
        {            
            Ensure = "Present"
            Name = "Net-Framework-Core"
            Source = "c:\software\sxs"
        }
            
        xSQLServerSetup installSqlServer
        {

            SourcePath = "c:\ConfigureDeveloperDesktop\Software"
            SourceFolder = "\SQLServer_x64_ENU_2012SP1_Developer"
            Features= "SQLENGINE"
            InstanceName="MSSQLSERVER"
            InstanceID="MSSQLSERVER"
            SQLSysAdminAccounts="BUILTIN\ADMINISTRATORS" 
            SQLSvcAccount= New-Object System.Management.Automation.PSCredential ("$domainNetBiosName\$ServiceUserName", $(ConvertTo-SecureString $DomainAdministratorPassword -AsPlainText -Force))
            AgtSvcAccount= New-Object System.Management.Automation.PSCredential ("$domainNetBiosName\$ServiceUserName", $(ConvertTo-SecureString $DomainAdministratorPassword -AsPlainText -Force))
            SQMReporting  = "1"
            InstallSQLDataDir="F:\SQL\"
            SQLUserDBDir= "F:\Dbs\"
            SQLUserDBLogDir="F:\Logs\"
            SQLTempDBDir="F:\TempDb\"
            SQLTempDBLogDir="F:\TempDbLog\"
            SQLBackupDir="F:\Backup\"
            PID = "YQWTX-G8T4R-QW4XX-BVH62-GP68Y"
            UpdateEnabled = "False"
            UpdateSource = "." # Must point to an existing folder, even though UpdateEnabled is set to False - otherwise it will fail
            SetupCredential = New-Object System.Management.Automation.PSCredential ("$domainNetBiosName\$DomainAdministratorUserName", $(ConvertTo-SecureString $DomainAdministratorPassword -AsPlainText -Force))

            DependsOn = "[WindowsFeature]installdotNet"
        }


        

        Script installSharePoint 
        {
            SetScript = 
@"              
`$cred = New-Object System.Management.Automation.PSCredential ("$domainNetBiosName\$DomainAdministratorUserName", (ConvertTo-SecureString -String $DomainAdministratorPassword -AsPlainText -Force))
`$session = New-PSSession -ComputerName $env:COMPUTERNAME -Credential `$cred -Authentication CredSSP
invoke-Command -Session `$session {
    C:\ConfigureDeveloperDesktop\Scripts\ConfigureSharePointFarmInDomain.ps1 -domainSPFarmAccountName SPFarm -domainSPFarmAccountPassword $DomainAdministratorPassword
}
           
"@                   
            GetScript = {
                Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction 0
                try {
                    $spfarm = Get-SPFarm 
                } catch {
                    return @{SharePointInstalled = $false}
                }
                return @{SharePointInstalled = $true}
            }
            TestScript = {
                Add-PSSnapin Microsoft.SharePoint.PowerShell -ErrorAction 0
                try {
                    $spfarm = Get-SPFarm 
                } catch {
                    return $false
                }
                return $true
            }

            Credential = New-Object System.Management.Automation.PSCredential ("$domainNetBiosName\$DomainAdministratorUserName", (ConvertTo-SecureString $DomainAdministratorPassword -AsPlainText -Force))
         
            DependsOn = "[xSQLServerSetup]installSqlServer","[Group]Administrators"
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

SPServerSoftware -ConfigurationData $configData -OutputPath $PSScriptRoot

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
        Write-Warning ("SPServerSoftware failed. Error:" + $_)

        if ($Retrycount -ge $MaximumRetryCount)
        {
            Write-Warning ("SPServerSoftware operation failed all retries")
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
