#
# Copyright="© Microsoft Corporation. All rights reserved."
#

configuration AddSQLServerInstance
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$SourceCredential,

        [Parameter(Mandatory)]
        [String]$SourcePath,

        [Parameter(Mandatory)]
        [System.Management.Automation.PsCredential]$SACred,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$SvcAccount,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AgtSvcAccount,

        [ValidateNotNullOrEmpty()]
        [String[]]$SysAdminAccounts = 'GTSAZURE\SQL-Sysadmin-All',

        [ValidateNotNullOrEmpty()]
        [String]$OUPath,

        [String]$DNSServerName='dc-pdc',

        [UInt32]$DatabaseEnginePort = 1433,

        [String]$DomainNetbiosName=(Get-NetBIOSName -DomainName $DomainName),

        [Parameter(Mandatory)]
        [String]$ClusterName,

        [String]$SQLInstanceName = "INST1",

        [String[]]$DatabaseNames,
        [Int]$RetryCount=20,
        [Int]$RetryIntervalSec=30

    )

    Set-StrictMode -Version Latest;

    Import-DscResource -ModuleName xSQL,xStorage,xSmbShare;
    Import-DscResource -ModuleName @{ModuleName="PSDesiredStateConfiguration";ModuleVersion="1.1"};
    Import-DscResource -ModuleName @{ModuleName="xComputerManagement";ModuleVersion="1.8.0.0"};
    Import-DscResource -ModuleName @{ModuleName="xActiveDirectory";ModuleVersion="2.13.0.0"};
    Import-DscResource -ModuleName @{ModuleName="xSQLServer";ModuleVersion="2.0.0.0"};
    Import-DscResource -ModuleName xNetworking;
    Import-DscResource -ModuleName cNtfsAccessControl;
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($Admincreds.UserName)", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$DomainFQDNCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$SACreds = New-Object System.Management.Automation.PSCredential ("sa", $SACred.Password)
    $sqlSvcAccount = $env:computername.ToLower().Replace("-","") + "sql";
    $sqlAgtAccount = $env:computername.ToLower().Replace("-","") + "agt";
    $sqlSvcAccountFQ = $DomainNetBiosName + "\" + $sqlSvcAccount;
    $sqlAgtAccountFQ = $DomainNetBiosName + "\" + $sqlAgtAccount;
    [System.Management.Automation.PSCredential]$sqlSvcCred = New-Object System.Management.Automation.PSCredential ($sqlSvcAccountFQ,$SvcAccount.Password);
    [System.Management.Automation.PSCredential]$sqlAgtCred = New-Object System.Management.Automation.PSCredential ($sqlAgtAccountFQ,$SvcAccount.Password);
    # Strip trailing slash to avoid vague "Network name not found" errors.
    if ($SourcePath.Substring($SourcePath.Length - 1,1) -eq "\")
    {
        $SourcePath = $SourcePath.Substring(0,$SourcePath.Length - 1);
    }

    Node localhost
    {

        WindowsFeature "InstallADTools"
        {
            Name = "RSAT-AD-Powershell"
            Ensure = "Present"
        }


        xADUser SQLServiceAccount
        {
            DependsOn = "[WindowsFeature]InstallADTools"
            DomainName = $DomainName
            UserName = $sqlSvcAccount
            Path = $OUPath
            Password = $sqlSvcCred
            PasswordNeverExpires = $true
            DomainAdministratorCredential = $DomainCreds
        }

        xADUser SQLAgentAccount
        {
            DependsOn = "[WindowsFeature]InstallADTools"
            DomainName = $DomainName
            UserName = $sqlAgtAccount
            Path = $OUPath
            Password = $AgtSvcAccount
            PasswordNeverExpires = $true
            DomainAdministratorCredential = $DomainCreds
        }

        xADGroup SQLServiceGroup
        {
            DependsOn = @("[WindowsFeature]InstallADTools","[xADUser]SQLServiceAccount")
            GroupName = "$($ClusterName)_Group"
            Path = $OUPath
            Credential = $DomainCreds
            MembersToInclude = $sqlSvcAccount
        }

        xADGroup SQLServiceGroup2
        {
            DependsOn = @("[WindowsFeature]InstallADTools","[xADUser]SQLServiceAccount")
            GroupName = "SQLServiceAccounts"
            Path = $OUPath
            Credential = $DomainCreds
            MembersToInclude = $sqlSvcAccount
        }

        xADGroup SQLAgentGroup
        {
            DependsOn = @("[WindowsFeature]InstallADTools","[xADUser]SQLAgentAccount")
            GroupName = "SQLAgentAccounts"
            Path = $OUPath
            Credential = $DomainCreds
            MembersToInclude = $sqlAgtAccount
        }

        xSQLServerSetup SetupSQLServer
        {
            DependsOn = @("[xADGroup]SQLServiceGroup2","[xADGroup]SQLAgentGroup")
            InstanceName = $SQLInstanceName
            SetupCredential = $AdminCreds
            SourceCredential = $SourceCredential
            Features = "SQLENGINE,FULLTEXT,IS,REPLICATION"
            SecurityMode="SQL"
            SAPwd = $SACreds
            SourcePath = $SourcePath
            InstallSQLDataDir = 'F:\SYSTEMDB'
            SQLUserDBDir = 'F:\DBASE_DATA'
            SQLUserDBLogDir = 'F:\DBASE_LOG'
            SQLTempDBDir = 'F:\TEMPDB'
            SQLTempDBLogDir = 'F:\TEMPDBLOG'
            SQLSvcAccount = $sqlSvcCred
            AgtSvcAccount = $sqlAgtCred
            SQLBackupDir = 'G:\Backups'
            SQLSysAdminAccounts = $SysAdminAccounts
        }
        
        xSQLServerNetwork SetupSQLNetwork
        {
            InstanceName = $SQLInstanceName
            ProtocolName = "TCP"
            DependsOn = "[xSQLServerSetup]SetupSQLServer"
            IsEnabled = $true
            TCPPort = 1433
        }

        xSQLServerLogin HADRGroupLogin
        {
            Name = "$(Get-NetBiosName $DomainNetBiosName)\$($ClusterName)_Group"
            SQLInstanceName = $SQLInstanceName
            SQLServer = "localhost"
            DependsOn = "[xSqlServerSetup]SetupSqlServer"
            Ensure = "Present"
            LoginType = "WindowsGroup"
        }

        xSqlServerEndpoint SqlAlwaysOnEndpoint
        {
            EndPointName = "HADR_Endpoint"
            Ensure = "Present"
            Port = 5022
            AuthorizedUser = "$DomainNetBiosName\$($ClusterName)_Group"
            SqlServer = "localhost"
            SqlInstanceName = $SQLInstanceName
            DependsOn = "[xSQLServerLogin]HADRGroupLogin"
        }

        xSqlServerConfiguration SetContainedAuth
        {
          InstanceName = $SQLInstanceName
          OptionName = "contained database authentication"
          OptionValue = 1
          DependsOn = "[xSqlServerSetup]SetupSqlServer"
        }

        Registry SetMSXEncryptOff
        {
            Key = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL13.INST1\SQLServerAgent"
            ValueName = "MsxEncryptChannelOptions"
            ValueData = "1"
            Force = $true
            Ensure = "Present"
            ValueType = "DWord"
        }

        xFirewall AllowSQLIn
        {
            Name = "Allow-SQL-Inbound"
            Direction = "Inbound"
            Action = "Allow"
            LocalPort = @("1433","5022")
            Protocol = "TCP"
        }

        File CreateAgentJobLogFolder
        {
            DestinationPath = "G:\AgentJobLog"
            Type = "Directory"
            Ensure = "Present"
        }

        cNtfsPermissionEntry SetAgentJobLogFolderPermissions
        {
            DependsOn = @("[File]CreateAgentJobLogFolder","[xADUser]SQLAgentAccount")
            Path = "G:\AgentJobLog"
            Principal = $sqlAgtAccountFQ
            Ensure = "Present"
            AccessControlInformation = @(
                cNtfsAccessControlInformation
                {
                    AccessControlType = 'Allow'
                    FileSystemRights = 'FullControl'
                    Inheritance = 'ThisFolderSubfoldersAndFiles'
                }
            )
        }
    }   
}

function Get-NetBIOSName
{ 
    [OutputType([string])]
    param(
        [string]$DomainName
    )

    if ($DomainName.Contains('.')) {
        $length=$DomainName.IndexOf('.')
        if ( $length -ge 16) {
            $length=15
        }
        return $DomainName.Substring(0,$length)
    }
    else {
        if ($DomainName.Length -gt 15) {
            return $DomainName.Substring(0,15)
        }
        else {
            return $DomainName
        }
    }
}
