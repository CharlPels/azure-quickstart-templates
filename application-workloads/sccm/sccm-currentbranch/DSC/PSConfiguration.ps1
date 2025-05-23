﻿configuration Configuration
{
   param
   (
        [Parameter(Mandatory)]
        [String]$DomainName,
        [Parameter(Mandatory)]
        [String]$DCName,
        [Parameter(Mandatory)]
        [String]$DPMPName,
        [Parameter(Mandatory)]
        [String]$CSName,
        [Parameter(Mandatory)]
        [String]$PSName,
        [Parameter(Mandatory)]
        [System.Array]$ClientName,
        [Parameter(Mandatory)]
        [String]$Configuration,
        [Parameter(Mandatory)]
        [String]$DNSIPAddress,
        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$Admincreds
    )
    Import-DscResource -ModuleName TemplateHelpDSC
    
    $LogFolder = "TempLog"
    $CM = "CMCB"
    $LogPath = "c:\$LogFolder"
    $DName = $DomainName.Split(".")[0]
    $DCComputerAccount = "$DName\$DCName$"
    $CurrentRole = "PS"
    if($Configuration -ne "Standalone")
    {
        $CSComputerAccount = "$DName\$CSName$"
    }
    $DPMPComputerAccount = "$DName\$DPMPName$"
    $Clients = [system.String]::Join(",", $ClientName)
    
    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("${DomainName}\$($Admincreds.UserName)", $Admincreds.Password)

    Node LOCALHOST
    {
        LocalConfigurationManager
        {
            ConfigurationMode = 'ApplyOnly'
            RebootNodeIfNeeded = $true
        }
        SetCustomPagingFile PagingSettings
        {
            Drive       = 'C:'
            InitialSize = '8192'
            MaximumSize = '8192'
        }

        AddBuiltinPermission AddSQLPermission
        {
            Ensure = "Present"
            DependsOn = "[SetCustomPagingFile]PagingSettings"
        }

        InstallFeatureForSCCM InstallFeature
        {
            NAME = "PS"
            Role = "Site Server"
            DependsOn = "[AddBuiltinPermission]AddSQLPermission"
        }

        InstallADK ADKInstall
        {
            ADKPath = "C:\adksetup.exe"
            ADKWinPEPath = "c:\adksetupwinpe.exe"
            Ensure = "Present"
            DependsOn = "[InstallFeatureForSCCM]InstallFeature"
        }

        DownloadAndInstallvcredist DownloadAndInstallvcredist
        {
            Ensure = "Present"
            DependsOn = "[InstallADK]ADKInstall"
        }

        DownloadAndInstallODBC DownloadAndInstallODBC
        {
            Ensure = "Present"
            DependsOn = "[DownloadAndInstallvcredist]DownloadAndInstallvcredist"
        }

        if($Configuration -eq "Standalone")
        {
            DownloadSCCM DownLoadSCCM
            {
                CM = $CM
                Ensure = "Present"
                DependsOn = "[DownloadAndInstallODBC]DownloadAndInstallODBC"
            }

            SetDNS DnsServerAddress
            {
                DNSIPAddress = $DNSIPAddress
                Ensure = "Present"
                DependsOn = "[DownloadSCCM]DownLoadSCCM"
            }

            FileReadAccessShare DomainSMBShare
            {
                Name = $LogFolder
                Path = $LogPath
                Account = $DCComputerAccount
                DependsOn = "[File]ShareFolder"
            }

            FileReadAccessShare CMSourceSMBShare
            {
                Name = $CM
                Path = "c:\$CM"
                Account = $DCComputerAccount
                DependsOn = "[ChangeSQLServicesAccount]ChangeToLocalSystem"
            }

            RegisterTaskScheduler InstallAndUpdateSCCM
            {
                TaskName = "ScriptWorkFlow"
                ScriptName = "ScriptWorkFlow.ps1"
                ScriptPath = $PSScriptRoot
                ScriptArgument = "$DomainName $CM $DName\$($Admincreds.UserName) $DPMPName $Clients $Configuration $CurrentRole $LogFolder $CSName $PSName"
                Ensure = "Present"
                DependsOn = "[FileReadAccessShare]CMSourceSMBShare"
            }
        }
        else 
        {
            SetDNS DnsServerAddress
            {
                DNSIPAddress = $DNSIPAddress
                Ensure = "Present"
                DependsOn = "[DownloadAndInstallODBC]DownloadAndInstallODBC"
            }

            WaitForConfigurationFile WaitCSJoinDomain
            {
                Role = "DC"
                MachineName = $DCName
                LogFolder = $LogFolder
                ReadNode = "CSJoinDomain"
                Ensure = "Present"
                DependsOn = "[File]ShareFolder"
            }

            FileReadAccessShare DomainSMBShare
            {
                Name = $LogFolder
                Path = $LogPath
                Account = $DCComputerAccount,$CSComputerAccount
                DependsOn = "[WaitForConfigurationFile]WaitCSJoinDomain"
            }

            RegisterTaskScheduler InstallAndUpdateSCCM
            {
                TaskName = "ScriptWorkFlow"
                ScriptName = "ScriptWorkFlow.ps1"
                ScriptPath = $PSScriptRoot
                ScriptArgument = "$DomainName $CM $DName\$($Admincreds.UserName) $DPMPName $Clients $Configuration $CurrentRole $LogFolder $CSName $PSName"
                Ensure = "Present"
                DependsOn = "[ChangeSQLServicesAccount]ChangeToLocalSystem"
            }
        }

        WaitForDomainReady WaitForDomain
        {
            Ensure = "Present"
            DCName = $DCName
            WaitSeconds = 0
            DependsOn = "[SetDNS]DnsServerAddress"
        }

        JoinDomain JoinDomain
        {
            DomainName = $DomainName
            Credential = $DomainCreds
            DependsOn = "[WaitForDomainReady]WaitForDomain"
        }
        
        File ShareFolder
        {            
            DestinationPath = $LogPath     
            Type = 'Directory'            
            Ensure = 'Present'
            DependsOn = "[JoinDomain]JoinDomain"
        }
        
        OpenFirewallPortForSCCM OpenFirewall
        {
            Name = "PS"
            Role = "Site Server"
            DependsOn = "[JoinDomain]JoinDomain"
        }

        WaitForConfigurationFile DelegateControl
        {
            Role = "DC"
            MachineName = $DCName
            LogFolder = $LogFolder
            ReadNode = "DelegateControl"
            Ensure = "Present"
            DependsOn = "[OpenFirewallPortForSCCM]OpenFirewall"
        }

        ChangeSQLServicesAccount ChangeToLocalSystem
        {
            SQLInstanceName = "MSSQLSERVER"
            Ensure = "Present"
            DependsOn = "[WaitForConfigurationFile]DelegateControl"
        }
    }
}