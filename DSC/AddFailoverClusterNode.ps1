
configuration AddFailoverClusterNode
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds,
        
        [Parameter(Mandatory)]
        [String]$ClusterName,
        
        [Parameter(Mandatory)]
        [String[]]$ClusterNodes,

        [Parameter(Mandatory)]
        [String]$OUPath,

        [Parameter(Mandatory)]
        [String]$WitnessStorageAccountName,

        # Cluster cloud witness storage account key
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]
        $WitnessStorageAccountKey,

        [String]$DomainNetbiosName=(Get-NetBIOSName -DomainName $DomainName),

        [Int]$RetryCount=20,
        [Int]$RetryIntervalSec=30

    )

    Set-StrictMode -Version Latest;

    Import-DscResource -ModuleName @{ModuleName='xActiveDirectory';ModuleVersion='2.16.0.0'};
    Import-DscResource -ModuleName @{ModuleName="PSDesiredStateConfiguration";ModuleVersion="1.1"};
    Import-DscResource -ModuleName @{ModuleName="xFailoverClusterAzure";ModuleVersion="1.0"};
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$($Admincreds.UserName)", $Admincreds.Password)
    [System.Management.Automation.PSCredential]$DomainFQDNCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)
    # [string]$LBFQName="${LBName}.${DomainName}"
    $ClusterNodeAccounts = @()
    foreach ($clusterNode in $ClusterNodes)
    {
        $ClusterNodeAccounts += "$clusterNode`$"
    }


    Node localhost
    {
        Write-Verbose "Domain credential is $($DomainCreds.UserName), password is $($DomainCreds.GetNetworkCredential().Password)";
        
        WindowsFeature "InstallClustering"
        {
            Name = "Failover-Clustering"
            Ensure = "Present"
        }

        WindowsFeature "InstallRSATClustering"
        {
            Name = "RSAT-Clustering"
            Ensure = "Present"
        }

        WindowsFeature "InstallADTools"
        {
            Name = "RSAT-ADDS"
            Ensure = "Present"
        }

        xADGroup "ClusterGroup"
        {
            DependsOn = "[WindowsFeature]InstallADTools"
            GroupName = "$($ClusterName)_Group"
            DisplayName = "$($ClusterName)_Group"
            MembersToInclude = $ClusterNodeAccounts
            Credential = $DomainCreds
            Path = $OUPath
        }

        xADComputer "CreateClusterComputer"
        {
            DependsOn = "[WindowsFeature]InstallADTools"
            ComputerName = $ClusterName
            Path = $OUPath
            DomainAdministratorCredential = $DomainCreds
            Enabled = $false
        }

        xADGroup "AddClusterToClusterComputers"
        {
            DependsOn = "[xADComputer]CreateClusterComputer"
            GroupName = "ClusterComputers"
            MembersToInclude = "$($ClusterName)`$"
            Credential = $DomainCreds
            Path = $OUPath
        }

        # This is for re-run purposes, so the cluster command doesn't fail if the cluster core group is somewhere else
        Script MoveCluster 
        {
            SetScript  = "Get-Cluster `$env:Computername -ErrorAction SilentlyContinue | Get-ClusterGroup 'Cluster Group' | Move-ClusterGroup -Node `$env:Computername | Start-ClusterGroup"
            TestScript = "`$false"
            GetScript  = "@{Result = 'Moved Cluster Group resource to local node}"
            DependsOn  = "[WindowsFeature]InstallClustering","[WindowsFeature]InstallRSATClustering"
        }

        xCluster FailoverCluster
        {
            Name = $ClusterName
            DomainAdministratorCredential = $DomainCreds
            Nodes = $ClusterNodes
            DependsOn = "[Script]MoveCluster","[xADGroup]AddClusterToClusterComputers"
        }

        # This is to ensure that the cluster computer account is enabled for re-run purposes.
        Script EnableClusterComputerAccount
        {
            DependsOn = "[xCluster]FailoverCluster"
            SetScript = "Get-ADComputer '$ClusterName' | Set-ADComputer -Enabled `$true"
            GetScript = "@{Result = 'Enabled computer account'"
            TestScript = "`$false"
            PsDscRunAsCredential = $DomainCreds
        }

        Script CloudWitness {
            SetScript  = "Set-ClusterQuorum -CloudWitness -AccountName ${witnessStorageAccountName} -AccessKey $($witnessStorageAccountKey.GetNetworkCredential().Password)"
            TestScript = "(Get-ClusterQuorum).QuorumResource.Name -eq 'Cloud Witness'"
            GetScript  = "@{Ensure = if ((Get-ClusterQuorum).QuorumResource.Name -eq 'Cloud Witness') {'Present'} else {'Absent'}}"
            DependsOn  = "[xCluster]FailoverCluster"
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
