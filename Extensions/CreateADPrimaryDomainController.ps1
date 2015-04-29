
try {
    Set-ExecutionPolicy -ExecutionPolicy Unrestricted 
}
catch{
    Write-Verbose 'An exception occurred setting Execution Policy - Trying to Continue -:'
    if ($Error) {
        Write-Verbose ($Error|fl * -Force|Out-String) 
    }
}
  


configuration ADDSForest
{
	param
	(
		[Parameter(Mandatory)] [String]$DomainName,	
		[Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [PSCredential] $DomainAdminAccount,
		[Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [PSCredential] $SQLServiceAccount,
        [Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [PSCredential] $FarmAccount,
        [Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [PSCredential] $InstallAccount,
        [Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [PSCredential] $WebPoolManagedAccount,
        [Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [PSCredential] $ServicePoolManagedAccount,

		[String]$DomainNetbiosName=$(Get-NetBIOSName($DomainName))

	)


    Import-DscResource -ModuleName xActiveDirectory
	 Import-DscResource -ModuleName xDisk
	 Import-DscResource -ModuleName xNetworking
	 [System.Management.Automation.PSCredential ]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($DomainAdminAccount.UserName)", $DomainAdminAccount.Password)


    Node localhost
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
            DomainAdministratorCredential = $DomainAdminAccount
            DomainName = $DomainName
            DomainNetbiosName = $DomainNetbiosName
            SafemodeAdministratorPassword = $DomainAdminAccount
            DatabasePath = "F:\NTDS"
            LogPath = "F:\NTDS"
            SysvolPath = "F:\SYSVOL"
            DependsOn = "[xDisk]ADDataDisk", "[WindowsFeature]ADDS"
        }

        xADUser SPFarm 
        {
            DomainName = $DomainName
            DomainAdministratorCredential = $DomainAdminAccount
            UserName = $FarmAccount.UserName.Split('`\')[1]
            Password = $FarmAccount
            Ensure = "Present" 
            DependsOn = "[xADDomain]PrimaryDC" 
        }

		xADUser WebPoolManagedAccount 
        {
            DomainName = $DomainName
            DomainAdministratorCredential = $DomainAdminAccount
            UserName = $WebPoolManagedAccount.UserName.Split('`\')[1]
            Password = $WebPoolManagedAccount
            Ensure = "Present" 
            DependsOn = "[xADDomain]PrimaryDC" 
        }

		xADUser ServicePoolManagedAccount 
        {
            DomainName = $DomainName
            DomainAdministratorCredential = $DomainAdminAccount
            UserName = $ServicePoolManagedAccount.UserName.Split('`\')[1]
            Password = $ServicePoolManagedAccount
            Ensure = "Present" 
            DependsOn = "[xADDomain]PrimaryDC" 
        }

        xADUser SPSetup 
        {
            DomainName = $DomainName
            DomainAdministratorCredential = $DomainAdminAccount
            UserName = $InstallAccount.UserName.Split('`\')[1]
            Password = $InstallAccount
            Ensure = "Present" 
            DependsOn = "[xADDomain]PrimaryDC" 
        }


        xADUser SQLService 
        {
            DomainName = $DomainName
            DomainAdministratorCredential = $DomainAdminAccount
            UserName = $SQLServiceAccount.UserName.Split('`\')[1]
            Password = $SQLServiceAccount
            Ensure = "Present" 
            DependsOn = "[xADDomain]PrimaryDC" 
        }


        LocalConfigurationManager
        {
            RebootNodeIfNeeded = $true
        }
    }
}
function Get-NetBIOSName([string]$DomainName)
{ 
    [string]$NetBIOSName
    if ($DomainName.Contains('.')) {
        $length=$DomainName.IndexOf('.')
        if ( $length -ge 16) {
            $length=15
        }
        $NetBIOSName=$DomainName.Substring(0,$length)
    }
    else {
        if ($DomainName.Length -gt 15) {
            $NetBIOSName=$DomainName.Substring(0,15)
        }
        else {
            $NetBIOSName=$DomainName
        }
    }
    return $NetBIOSName
}

