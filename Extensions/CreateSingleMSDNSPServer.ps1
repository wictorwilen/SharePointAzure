Configuration SingleMSDNServer
{
    param (
		[Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [PSCredential] $DomainAdminAccount,
		[Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [string]       $DomainNameFQDN,
		[Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [string]       $DomainName,
		[Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [PSCredential] $SQLServiceAccount,
        [Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [PSCredential] $FarmAccount,
        [Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [PSCredential] $InstallAccount,
        [Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [string]       $ProductKey,
        [Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [string]       $FarmPassPhrase,
        [Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [PSCredential] $WebPoolManagedAccount,
        [Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [PSCredential] $ServicePoolManagedAccount,
        [Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [string]       $WebAppUrl,
        [Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [string]       $TeamSiteUrl,
		[Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [string]       $DevSiteUrl,
        [Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [string]       $MySiteHostUrl
    )
    Import-DscResource -ModuleName xSharePoint
	Import-DscResource -ModuleName xComputerManagement
    Import-DscResource -ModuleName xWebAdministration
    Import-DscResource -ModuleName xCredSSP
    Import-DscResource -ModuleName xDisk
	Import-DscResource -ModuleName xSQLServer

    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($DomainAdminAccount.UserName)", $DomainAdminAccount.Password)


    node "localhost"
    {
        #**********************************************************
        # Server configuration
        #
        # This section of the configuration includes details of the
        # server level configuration, such as disks, registry
        # settings etc.
        #********************************************************** 

		Script HighPerformancePowerPlan
        {
            SetScript = { Powercfg -SETACTIVE SCHEME_MIN }
            TestScript = { return ( Powercfg -getactivescheme) -like "*High Performance*" }
            GetScript = { return @{ Powercfg = ( "{0}" -f ( powercfg -getactivescheme ) ) } }
        }

        xDisk LogsDisk { DiskNumber = 2; DriveLetter = "l" }
        xDisk IndexDisk { DiskNumber = 3; DriveLetter = "i" }
		xDisk SqlDisk { DiskNumber = 4; DriveLetter = "s" }
        xCredSSP CredSSPServer { Ensure = "Present"; Role = "Server" } 
        xCredSSP CredSSPClient { Ensure = "Present"; Role = "Client"; DelegateComputers = '*.$DomainNameFQDN','$env:COMPUTERNAME', 'localhost' }
        
        Script configureWS {
            SetScript =
@"
`$allowed = @('WSMAN/*.$DomainNameFQDN','WSMAN/$($env:COMPUTERNAME)')  

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
                return (Get-Item WSMan:\localhost\Client\TrustedHosts).Value -ne ""
            }
        }

		xComputer DomainJoin
        {
            Name = $env:COMPUTERNAME
            DomainName = $DomainNameFQDN
            Credential = $DomainCreds
            DependsOn =  @("[xCredSSP]CredSSPServer","[xCredSSP]CredSSPClient","[Script]configureWS")
        }


        WindowsFeature ADPS
        {
            Name = "RSAT-AD-PowerShell"
            Ensure = "Present"
        }


		Group Administrators
        {
            Ensure = 'Present'
            GroupName = 'Administrators'
            MembersToInclude = @($InstallAccount.UserName)
            Credential = $DomainCreds
			DependsOn = "[xComputer]DomainJoin"
        }
		
        WindowsFeature installdotNet
        {            
            Ensure = "Present"
            Name = "Net-Framework-Core"
            Source = "c:\software\sxs"
        }
		#**********************************************************
        # SQL Server
        #
        #********************************************************** 
            
        xSQLServerSetup xSQLServerSetup
        {
            SourcePath = "c:\ConfigureDeveloperDesktop\Software"
            SourceFolder = "\SQLServer_x64_ENU_2012SP1_Developer"
            Features= "SQLENGINE"
            InstanceName="MSSQLSERVER"
            InstanceID="MSSQLSERVER"
            SQLSysAdminAccounts="BUILTIN\ADMINISTRATORS" 
            SQLSvcAccount= $SQLServiceAccount
            AgtSvcAccount= $SQLServiceAccount
            SQMReporting  = "1"
            InstallSQLDataDir="S:\SQL\"
            SQLUserDBDir= "S:\Dbs\"
            SQLUserDBLogDir="S:\Logs\"
            SQLTempDBDir="S:\TempDb\"
            SQLTempDBLogDir="S:\TempDbLog\"
            SQLBackupDir="S:\Backup\"
            PID = "YQWTX-G8T4R-QW4XX-BVH62-GP68Y"
            UpdateEnabled = "False"
            UpdateSource = "." # Must point to an existing folder, even though UpdateEnabled is set to False - otherwise it will fail
            SetupCredential = $InstallAccount

            DependsOn = @("[xComputer]DomainJoin","[WindowsFeature]installdotNet","[xDisk]SqlDisk","[Group]Administrators")
        }

        #**********************************************************
        # Binary installation
        #
        # This section triggers installation of both SharePoint
        # as well as the prerequisites required
        #********************************************************** 
        xSPClearRemoteSessions ClearRemotePowerShellSessions
        {
            ClearRemoteSessions = $true
        }
        
        #**********************************************************
        # IIS clean up
        #
        # This section removes all default sites and application
        # pools from IIS as they are not required
        #**********************************************************

        xWebAppPool RemoveDotNet2Pool         { Name = ".NET v2.0";            Ensure = "Absent"; DependsOn = "[xSQLServerSetup]xSQLServerSetup" }
        xWebAppPool RemoveDotNet2ClassicPool  { Name = ".NET v2.0 Classic";    Ensure = "Absent"; DependsOn = "[xSQLServerSetup]xSQLServerSetup" }
        xWebAppPool RemoveDotNet45Pool        { Name = ".NET v4.5";            Ensure = "Absent"; DependsOn = "[xSQLServerSetup]xSQLServerSetup"; }
        xWebAppPool RemoveDotNet45ClassicPool { Name = ".NET v4.5 Classic";    Ensure = "Absent"; DependsOn = "[xSQLServerSetup]xSQLServerSetup"; }
        xWebAppPool RemoveClassicDotNetPool   { Name = "Classic .NET AppPool"; Ensure = "Absent"; DependsOn = "[xSQLServerSetup]xSQLServerSetup" }
        xWebAppPool RemoveDefaultAppPool      { Name = "DefaultAppPool";       Ensure = "Absent"; DependsOn = "[xSQLServerSetup]xSQLServerSetup" }
        xWebSite    RemoveDefaultWebSite      { Name = "Default Web Site";     Ensure = "Absent"; PhysicalPath = "C:\inetpub\wwwroot"; DependsOn = "[xSQLServerSetup]xSQLServerSetup" }
        

        #**********************************************************
        # Basic farm configuration
        #
        # This section creates the new SharePoint farm object, and
        # provisions generic services and components used by the
        # whole farm
        #**********************************************************

        xSPCreateFarm CreateSPFarm
        {
            DatabaseServer           = "localhost"
            FarmConfigDatabaseName   = "SP_Config"
            Passphrase               = $FarmPassPhrase
            FarmAccount              = $FarmAccount
            InstallAccount           = $InstallAccount
            AdminContentDatabaseName = "SP_AdminContent"
			CentralAdministrationPort = 21000
            DependsOn                = @("[xSQLServerSetup]xSQLServerSetup","[xDisk]LogsDisk","[xDisk]IndexDisk")
        }
        xSPManagedAccount ServicePoolManagedAccount
        {
            AccountName    = $ServicePoolManagedAccount.UserName
            Account        = $ServicePoolManagedAccount
            Schedule       = ""
            InstallAccount = $InstallAccount
            DependsOn      = "[xSPCreateFarm]CreateSPFarm"
        }
        xSPManagedAccount WebPoolManagedAccount
        {
            AccountName    = $WebPoolManagedAccount.UserName
            Account        = $WebPoolManagedAccount
            Schedule       = ""
            InstallAccount = $InstallAccount
            DependsOn      = "[xSPCreateFarm]CreateSPFarm"
        }
        xSPDiagnosticLoggingSettings ApplyDiagnosticLogSettings
        {
            InstallAccount                              = $InstallAccount
            LogPath                                     = "L:\ULSLogs"
            LogSpaceInGB                                = 10
            AppAnalyticsAutomaticUploadEnabled          = $false
            CustomerExperienceImprovementProgramEnabled = $true
            DaysToKeepLogs                              = 7
            DownloadErrorReportingUpdatesEnabled        = $false
            ErrorReportingAutomaticUploadEnabled        = $false
            ErrorReportingEnabled                       = $false
            EventLogFloodProtectionEnabled              = $true
            EventLogFloodProtectionNotifyInterval       = 5
            EventLogFloodProtectionQuietPeriod          = 2
            EventLogFloodProtectionThreshold            = 5
            EventLogFloodProtectionTriggerPeriod        = 2
            LogCutInterval                              = 15
            LogMaxDiskSpaceUsageEnabled                 = $true
            ScriptErrorReportingDelay                   = 30
            ScriptErrorReportingEnabled                 = $true
            ScriptErrorReportingRequireAuth             = $true
            DependsOn                                   = @("[xSPCreateFarm]CreateSPFarm", "[xDisk]LogsDisk")
        }
        xSPUsageApplication UsageApplication 
        {
            Name                  = "Usage Service Application"
            DatabaseName          = "SP_Usage"
            UsageLogCutTime       = 5
            UsageLogLocation      = "L:\UsageLogs"
            UsageLogMaxFileSizeKB = 1024
            InstallAccount        = $InstallAccount
            DependsOn             = "[xSPCreateFarm]CreateSPFarm"
        }
        xSPStateServiceApp StateServiceApp
        {
            Name           = "State Service Application"
            DatabaseName   = "SP_State"
            InstallAccount = $InstallAccount
            DependsOn      = "[xSPCreateFarm]CreateSPFarm"
        }
        xSPDistributedCacheService EnableDistributedCache
        {
            Name           = "AppFabricCachingService"
            Ensure         = "Present"
            CacheSizeInMB  = 512
			CreateFirewallRules = $true
            ServiceAccount = $ServicePoolManagedAccount.UserName
            InstallAccount = $InstallAccount
            DependsOn      = @('[xSPCreateFarm]CreateSPFarm','[xSPManagedAccount]ServicePoolManagedAccount')
        }

        #**********************************************************
        # Web applications
        #
        # This section creates the web applications in the 
        # SharePoint farm, as well as managed paths and other web
        # application settings
        #**********************************************************

        xSPWebApplication HostNameSiteCollectionWebApp
        {
            Name                   = "SharePoint Sites"
            ApplicationPool        = "SharePoint Sites"
            ApplicationPoolAccount = $WebPoolManagedAccount.UserName
            AllowAnonymous         = $false
            AuthenticationMethod   = "NTLM"
            DatabaseName           = "SP_Content_01"
            DatabaseServer         = "localhost"
            Url                    = $WebAppUrl
            Port                   = 80
            InstallAccount         = $InstallAccount
            DependsOn              = "[xSPManagedAccount]WebPoolManagedAccount"
        }
        xSPManagedPath TeamsManagedPath 
        {
            WebAppUrl      = "http://$WebAppUrl"
            InstallAccount = $InstallAccount
            RelativeUrl    = "teams"
            Explicit       = $false
            HostHeader     = $true
            DependsOn      = "[xSPWebApplication]HostNameSiteCollectionWebApp"
        }
        xSPManagedPath PersonalManagedPath 
        {
            WebAppUrl      = "http://$WebAppUrl"
            InstallAccount = $InstallAccount
            RelativeUrl    = "personal"
            Explicit       = $false
            HostHeader     = $true
            DependsOn      = "[xSPWebApplication]HostNameSiteCollectionWebApp"
        }
        

        #**********************************************************
        # Service instances
        #
        # This section describes which services should be running
        # and not running on the server
        #**********************************************************

        xSPServiceInstance ClaimsToWindowsTokenServiceInstance
        {  
            Name           = "Claims to Windows Token Service"
            Ensure         = "Present"
            InstallAccount = $InstallAccount
            DependsOn      = "[xSPCreateFarm]CreateSPFarm"
        } 
        xSPServiceInstance UserProfileServiceInstance
        {  
            Name           = "User Profile Service"
            Ensure         = "Present"
            InstallAccount = $InstallAccount
            DependsOn      = "[xSPCreateFarm]CreateSPFarm"
        }        
        xSPServiceInstance SecureStoreServiceInstance
        {  
            Name           = "Secure Store Service"
            Ensure         = "Present"
            InstallAccount = $InstallAccount
            DependsOn      = "[xSPCreateFarm]CreateSPFarm"
        }
        xSPServiceInstance ManagedMetadataServiceInstance
        {  
            Name           = "Managed Metadata Web Service"
            Ensure         = "Present"
            InstallAccount = $InstallAccount
            DependsOn      = "[xSPCreateFarm]CreateSPFarm"
        }
        
        xSPUserProfileSyncService UserProfileSyncService
        {  
            UserProfileServiceAppName   = "User Profile Service Application"
            Ensure                      = "Present"
            FarmAccount                 = $FarmAccount
            InstallAccount              = $InstallAccount
            DependsOn                   = "[xSPUserProfileServiceApp]UserProfileServiceApp"
        }

        #**********************************************************
        # Service applications
        #
        # This section creates service applications and required
        # dependencies
        #**********************************************************

        xSPServiceAppPool MainServiceAppPool
        {
            Name           = "SharePoint Service Applications"
            ServiceAccount = $ServicePoolManagedAccount.UserName
            InstallAccount = $InstallAccount
            DependsOn      = "[xSPCreateFarm]CreateSPFarm"
        }
        xSPUserProfileServiceApp UserProfileServiceApp
        {
            Name                = "User Profile Service Application"
            ApplicationPool     = "SharePoint Service Applications"
            MySiteHostLocation  = "http://$MySiteHostUrl"
            ProfileDBName       = "SP_UserProfiles"
            ProfileDBServer     = "localhost"
            SocialDBName        = "SP_Social"
            SocialDBServer      = "localhost"
            SyncDBName          = "SP_ProfileSync"
            SyncDBServer        = "localhost"
            FarmAccount         = $FarmAccount
            InstallAccount      = $InstallAccount
            DependsOn           = @('[xSPServiceAppPool]MainServiceAppPool', '[xSPManagedPath]PersonalManagedPath', '[xSPSite]MySiteHost', '[xSPManagedMetaDataServiceApp]ManagedMetadataServiceApp', '[xSPSearchServiceApp]SearchServiceApp')
        }
        xSPSecureStoreServiceApp SecureStoreServiceApp
        {
            Name            = "Secure Store Service Application"
            ApplicationPool = "SharePoint Service Applications"
            AuditingEnabled = $true
            AuditlogMaxSize = 30
            DatabaseName    = "SP_SecureStore"
            InstallAccount  = $InstallAccount
            DependsOn       = "[xSPServiceAppPool]MainServiceAppPool"
        }
        xSPManagedMetaDataServiceApp ManagedMetadataServiceApp
        {  
            Name              = "Managed Metadata Service Application"
            InstallAccount    = $InstallAccount
            ApplicationPool   = "SharePoint Service Applications"
            DatabaseServer    = "localhost"
            DatabaseName      = "SP_ManagedMetadata"
            DependsOn         = "[xSPServiceAppPool]MainServiceAppPool"
        }
        xSPSearchServiceApp SearchServiceApp
        {  
            Name            = "Search Service Application"
            DatabaseName    = "SP_Search"
            ApplicationPool = "SharePoint Service Applications"
            InstallAccount  = $InstallAccount
            DependsOn       = "[xSPServiceAppPool]MainServiceAppPool"
        }
        

        #**********************************************************
        # Site Collections
        #
        # This section contains the site collections to provision
        #**********************************************************
        
        xSPSite TeamSite
        {
            Url                      = "http://$TeamSiteUrl"
            OwnerAlias               = $InstallAccount.UserName
            HostHeaderWebApplication = "http://$WebAppUrl"
            Name                     = "Team Sites"
            Template                 = "STS#0"
            InstallAccount           = $InstallAccount
            DependsOn                = "[xSPWebApplication]HostNameSiteCollectionWebApp"
        }

		xSPSite DevSite
        {
            Url                      = "http://$DevSiteUrl"
            OwnerAlias               = $InstallAccount.UserName
            HostHeaderWebApplication = "http://$WebAppUrl"
            Name                     = "Dev Site"
            Template                 = "DEV#0"
            InstallAccount           = $InstallAccount
            DependsOn                = "[xSPWebApplication]HostNameSiteCollectionWebApp"
        }
        xSPSite MySiteHost
        {
            Url                      = "http://$MySiteHostUrl"
            OwnerAlias               = $InstallAccount.UserName
            HostHeaderWebApplication = "http://$WebAppUrl"
            Name                     = "My Site Host"
            Template                 = "SPSMSITEHOST#0"
            InstallAccount           = $InstallAccount
            DependsOn                = "[xSPWebApplication]HostNameSiteCollectionWebApp"
        }

        #**********************************************************
        # Local configuration manager settings
        #
        # This section contains settings for the LCM of the host
        # that this configuraiton is applied to
        #**********************************************************
        LocalConfigurationManager
        {
            RebootNodeIfNeeded = $true
        }
    }
}