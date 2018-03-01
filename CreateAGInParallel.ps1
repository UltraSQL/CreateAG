<#
==============================================================================================
  File:     CreateAGInParallel.ps1
  Author:   Changyong Xu
  Version:  SQL Server 2014, PowerShell V4
  Comment:  First of all,backup database in parallel on primary.
            And then restore database in parallel on secondaries.
            Then create AG.At last test AG state.
            Run Powershell as Administor,and execute like this:
            .\CreateAGInParallel.ps1 "alwayson3\teststandby","sqlclust\testal" testag a "\\10.190.190.160\c$\xxxx\"
===============================================================================================
#>

Param
(
    # Name of the server instances that will participate in the availability group.
    # The first server is assumed to be the initial primary, the others initial secondaries.
    [Parameter(Mandatory=$true)]
    [string[]] $InstanceList,

    # Name of the availability group
    [string] $AgName = "MyAvailabilityGroup",

    # Names of the databases to add to availability group
    [string[]] $DatabaseList,
    
    # Directory for backup files
    [Parameter(Mandatory=$true)]
    [string] $BackupShare
)

# Import module sqlps
Import-Module SQLPS -DisableNameChecking

# Define function send-mail
function Send-Mail
([psobject]$MailCredential,$To,[string]$Body,[string]$Subject)
{
 Send-MailMessage -To $To -Body $Body -Subject $Subject -Credential $MailCredential -From "xxxx@xxxx.com" -SmtpServer "10.0.10.1"`
 -Encoding ([System.Text.Encoding]::UTF8);
}

# Initialize some collections
$InstanceObjects = @()
$Replicas = @()

$Log = Join-Path $Home "Documents\alwayson.log"

$User = "xxxx@xxxx.com"
$Key = (2,2,2,2,22,22,222,222,1,1,2,23,42,54,33,233,1,34,2,7,6,5,22,22)
$Pwd = "76492d1116743f0423413b16050a5345MgB8AEYARwA3AEcASwA3AG0AUgBMAEUAdgByAEoANQAvAGsAbQBrAFYANABLAGcAPQA9AHwAZgA2AGQAYQA5ADQAYQA4ADIAMQAxADQAYgA4AGYAMwA1ADgAZgA0AGEAYwBjADkAZgBkADYAMQA5AGMAOQA5ADkAZgBjADgANgA3ADcANABkAGUAZAA4ADkAOQA2ADMAZgAyADkAMgA3ADcANQAzAGQAMgA4AGQAYQBlADUAMgA="
$SecStr=ConvertTo-SecureString -String $Pwd -Key $Key;
$Credential = New-Object -TypeName "System.Management.Automation.PSCredential" -ArgumentList $User, $SecStr
$MailTo = @("Xu Changyong <xuchangyong@xxxx.com>","yyy yyy <yyyyyy@xxxx.com>")

$StartTime = Get-Date

$Message = "###############################################################`r`n"
$Message += "[INFO] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
$Message += "[INFO] Build up Alwayson AG now`r`n"
$Message += "###############################################################`r`n"
Write-Host -ForegroundColor Green $Message
$Message | Out-File -FilePath $Log -Append

# Create AG replica
foreach ($instance in $InstanceList)
{
    # Connection to the server instance, using Windows authentication
    Write-Verbose "Creating SMO Server object for server instance: $instance"
    $InstanceObject = New-Object Microsoft.SQLServer.Management.SMO.Server($instance) 
    $InstanceObjects += $InstanceObject

    # Get the mirroring endpoint on the server instance
    $EndpointObject = $InstanceObject.Endpoints | 
        Where-Object { $_.EndpointType -eq "DatabaseMirroring" } | 
        Select-Object -First 1

    # Create an endpoint if one doesn't exist
    if ($EndpointObject -eq $null)
    {
        Write-Warning "No Mirroring endpoint found on server instance: $instance"
        exit
    }

    <#
    # Create endpoint first.
    $ServerList = @(zbsz1-xxxx-db1,zbsz1-xxxx-db3,zbbj1-xxxx-db1,zbsz1-yyyy-his,zbsz1-yyyy-hisb, `
        zbbj1-yyyy-his,zbsz1-zzzz-db1,zbsz1-zzzz-db3,zbbj1-zzzz-db1,zbsz1-mmmm-his,zbsz1-mmmm-hisb, `
        zbbj1-mmmm-his,zbsz1-nnnn-db2,zbsz1-nnnn-db3,zbbj1-nnnn-db1)

    $ScriptEndpoint = {
        $InstanceName = (Get-Item -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL" -ErrorAction SilentlyContinue).property)
        if ($InstanceName = $null)
        {
            Write-Warning "No instance found on this server"
            exit
        }
        elseif ($InstanceName = "MSSQLSERVER")
        {
            New-SqlHADREndpoint -Path SQLSERVER:\sql\$ServerList\DEFAULT\ -Name "hadr_endpoint" -Port 5022
            Set-SqlHadrEndpoint -Path SQLSERVER:\sql\$ServerList\DEFAULT\Endpoints\hadr_endpoint -State Started
        }
        else
        {
            New-SqlHADREndpoint -Path SQLSERVER:\sql\$ServerList\$In\ -Name "hadr_endpoint" -Port 5022
            Set-SqlHadrEndpoint -Path SQLSERVER:\sql\$ServerList\DEFAULT\Endpoints\hadr_endpoint -State Started
        }
    }
    Invoke-Command -ComputerName $ServerList -ScriptBlock $ScriptEndpoint
    #>

    $fqdn = $InstanceObject.Information.FullyQualifiedNetName
    $port = $EndpointObject.Protocol.Tcp.ListenerPort
    $EndpointURL = "TCP://${fqdn}:${port}"

    $VersionMajor = $InstanceObject.Version.Major

    # Create an availability replica for this server instance.
    # For this example all replicas use asynchronous commit, manual failover, and 
    # support reads on the secondaries
    $Replicas += (New-SqlAvailabilityReplica `
            -Name $instance `
            -EndpointUrl $EndpointURL `
            -AvailabilityMode "AsynchronousCommit" `
            -FailoverMode "Manual" `
            -ConnectionModeInSecondaryRole "AllowAllConnections" `
            -AsTemplate `
            -Version $VersionMajor) 
}

$Primary, $Secondaries = $InstanceObjects
$PrimaryInstance, $SecondaryInstanceList = $InstanceList


# Create the initial copies of the databases on the primary
foreach ($db in $DatabaseList)
{
    $bakFile = Join-Path $BackupShare "$db.bak"
    $trnFile = Join-Path $BackupShare "$db.trn"

    $ScriptBlock = {
        param($db,$PrimaryInstance,$bakFile,$trnFile)

        Import-Module SQLPS -DisableNameChecking

        $ErrorActionPreference = "Stop"

        $Log = Join-Path $Home "Documents\alwayson.log"

        try{
            Write-Verbose "Backing up database '$db' on $PrimaryInstance to $bakFile"
            Backup-SqlDatabase -ServerInstance $PrimaryInstance -Database $db -BackupFile $bakFile -Init 
            Write-Verbose "Backing up the log of database '$db' on $PrimaryInstance to $trnFile"
            Backup-SqlDatabase -ServerInstance $PrimaryInstance -Database $db -BackupFile $trnFile -BackupAction "Log" -Init
        }
        catch
        {
            $Message = "###############################################################`r`n"
            $Message += "[ERROR] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
            $Message += "[ERROR] backup $($db) failed`r`n"
            $Message += "[ERROR] $($_.Exception.Message)`r`n"
            Write-Host -ForegroundColor Red $Message
            $Message | Out-File -FilePath $Log -Append
        }
    }

    Start-Job -ScriptBlock $ScriptBlock -Name "backup_$db" -ArgumentList $db,$PrimaryInstance,$bakFile,$trnFile
}

# Get backup job state
$BackupJobList = @()
$BackupJobList = Get-Job -Name backup*
Wait-Job -Job $BackupJobList | Format-Table -AutoSize

foreach ($job in $BackupJobList)
{
    $name = $job.Name
    $state = $job.JobStateInfo.State
    $reason = $job.JobSateInfo.Reason
    if ($job.JobStateInfo.State -ne "Completed")
    {
        $Message = "###############################################################`r`n"
        $Message += "[ERROR] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
        $Message += "[ERROR] backup job failed`r`n"
        $Message += "[ERROR] job name: $($name)`r`n"
        $Message += "[ERROR] reason: $($reason)`r`n"
        Write-Host -ForegroundColor Red $Message
        $Message | Out-File -FilePath $Log -Append
        Send-Mail -MailCredential $Credential -To $MailTo -Body $Message -Subject "backup job failed"
        exit
    }
}

Remove-Job -Job $BackupJobList

$Message = "###############################################################`r`n"
$Message += "[INFO] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
$Message += "[INFO] backup job in parallel completed`r`n"
$Message += "###############################################################`r`n"
Write-Host -ForegroundColor Green $Message


# Restore in secondaries
foreach ($secInstance in $SecondaryInstanceList)
{
    $secServer, $secInstanceName = $secInstance -split "\\"
    #Write-Host -ForegroundColor Blue "$secServer $secInstanceName"

    foreach ($db in $DatabaseList)
    {
        $bakFile = Join-Path $BackupShare "$db.bak"
        $trnFile = Join-Path $BackupShare "$db.trn"

        #Write-Host -ForegroundColor Blue "out script block: $Log`r`n $db`r`n $secInstance`r`n $bakFile`r`n $trnFile`r`n"

        $ScriptBlock = {
            param($db,$secInstance,$bakFile,$trnFile)

            Import-Module SQLPS -DisableNameChecking 

            $ErrorActionPreference = "Stop"
            $Log = Join-Path $Home "Documents\alwayson.log"
            #"in script block & out try: $Log`r`n $db`r`n $secInstance`r`n $bakFile`r`n $trnFile`r`n" | Out-File -FilePath $Log -Append          

            try
            {
                $secondary = New-Object -TypeName Microsoft.SqlServer.Management.Smo.Server -ArgumentList $secInstance

                #get default data file directory
                $RelocatePath = $secondary.Settings.DefaultFile
                #"in try: $RelocatePath" | Out-File -FilePath $Log -Append

                $SmoRestore = New-Object Microsoft.SqlServer.Management.Smo.Restore
                $SmoRestore.Devices.AddDevice($bakFile, [Microsoft.SqlServer.Management.Smo.DeviceType]::File)

                #get the File list
                $FileList = $SmoRestore.ReadFileList($secondary)
                $RelocateFileList = @()
                #"in try: $FileList" | Out-File -FilePath $Log -Append

                foreach ($File in $FileList)
                {
                    $RelocateFile = $RelocatePath + "\" + (Split-Path $File.PhysicalName -Leaf)
                    #$RelocateFile  | Out-File -FilePath $Log -Append
                    $RelocateFileList += New-Object Microsoft.SqlServer.Management.Smo.RelocateFile($File.LogicalName, $RelocateFile)
                }

                if($secondary.Databases.Item($db))
                {
                    $secondary.KillAllProcesses($db)
                    $secondary.Databases.Item($db).Drop()
                }

                Restore-SqlDatabase -ServerInstance $secInstance -Database $db -BackupFile $bakFile -RelocateFile $RelocateFileList -NoRecovery
                Restore-SqlDatabase -ServerInstance $secInstance -Database $db -BackupFile $trnFile -RestoreAction "Log" -NoRecovery
            }
            catch
            {
                $Message = "###############################################################`r`n"
                $Message += "[ERROR] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
                $Message += "[ERROR] restore $($db) failed`r`n"
                $Message += "[ERROR] $($_.Exception.Message)`r`n"
                Write-Host -ForegroundColor Red $Message
                $Message | Out-File -FilePath $Log -Append
            }
        }

        Start-Job -ScriptBlock $ScriptBlock -Name "restore_$($secServer)_$($db)" -ArgumentList $db,$secInstance,$bakFile,$trnFile
    }
}

# Get restore job state
$RestoreJobList = Get-Job -Name restore*
Wait-Job -Job $RestoreJobList  | Format-Table -AutoSize

foreach ($job in $RestoreJobList)
{
    $name = $job.Name
    $state = $job.JobStateInfo.State
    $reason = $job.JobSateInfo.Reason
    if ($job.JobStateInfo.State -ne "Completed")
    {
        $Message = "###############################################################`r`n"
        $Message += "[ERROR] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
        $Message += "[ERROR] restore job failed`r`n"
        $Message += "[ERROR] job name: $($name)`r`n"
        $Message += "[ERROR] reason: $($reason)`r`n"
        Write-Host -ForegroundColor Red $Message
        $Message | Out-File -FilePath $Log -Append
        Send-Mail -MailCredential $Credential -To $MailTo -Body $Message -Subject "restore job failed"
        exit
    }
}

Remove-Job -Job $RestoreJobList

$Message = "###############################################################`r`n"
$Message += "[INFO] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
$Message += "[INFO] restore job in parallel completed`r`n"
$Message += "###############################################################`r`n"
Write-Host -ForegroundColor Green $Message


# Create AG
try
{
    # Create the availability group
    New-SqlAvailabilityGroup -Name $AgName -InputObject $Primary -AvailabilityReplica $Replicas -Database $DatabaseList | Out-Null

    # Join the secondary replicas, and join the databases on those replicas
    foreach ($secondary in $Secondaries)
    {
        Join-SqlAvailabilityGroup -InputObject $secondary -Name $AgName
        $ag = $secondary.AvailabilityGroups[$AgName]
        Add-SqlAvailabilityDatabase -InputObject $ag -Database $DatabaseList 
    }
}
catch
{
    $Message = "###############################################################`r`n"
    $Message += "[ERROR] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
    $Message += "[ERROR] create ag failed`r`n"
    $Message += "[ERROR] $($_.Exception.Message)`r`n"
    Write-Host -ForegroundColor Red $Message
    $Message | Out-File -FilePath $Log -Append
    Send-Mail -MailCredential $Credential -To $MailTo -Body $Message -Subject "create ag failed"
    exit
}


# Test AG
# Connect to the server instance and set default init fields for 
# efficient loading of collections. We use windows authentication here,
# but this can be changed to use SQL Authentication if required.
$Primary.SetDefaultInitFields([Microsoft.SqlServer.Management.Smo.AvailabilityGroup], $true)
$Primary.SetDefaultInitFields([Microsoft.SqlServer.Management.Smo.AvailabilityReplica], $true)
$Primary.SetDefaultInitFields([Microsoft.SqlServer.Management.Smo.DatabaseReplicaState], $true)

# Attempt to access the availability group object on the server
$groupObject = $Primary.AvailabilityGroups[$AgName]

if($groupObject -eq $null)
{
    # Can't find the availability group on the server.
    $Message = "###############################################################`r`n"
    $Message += "[ERROR] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
    $Message += "[ERROR] The availability group '$AgName' does not exist on server '$PrimaryInstance'.`r`n"
    Write-Host -ForegroundColor Red $Message
    $Message | Out-File -FilePath $Log -Append
    exit
}
elseif($groupObject.PrimaryReplicaServerName -eq $null)
{
    # Can't determine the primary server instance. This can be serious (may mean the AG is offline), so throw an error.
    $Message = "###############################################################`r`n"
    $Message += "[ERROR] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
    $Message += "[ERROR] Cannot determine the primary replica of availability group '$AgName' from server instance '$PrimaryInstance'. Please investigate!`r`n"
    Write-Host -ForegroundColor Red $Message
    $Message | Out-File -FilePath $Log -Append
    Send-Mail -MailCredential $Credential -To $MailTo -Body $Message -Subject "test ag failed"
    exit
}
elseif($groupObject.PrimaryReplicaServerName -ne $PrimaryInstance)
{
    # We're trying to run the script on a secondary replica, which we shouldn't do.
    # We'll just throw a warning in this case, however, and skip health evaluation.
    $Message = "###############################################################`r`n"
    $Message += "[ERROR] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
    $Message += "[ERROR] The server instance '$PrimaryInstance' is not the primary replica for the availability group '$AgName'. Skipping evaluation.`r`n"
    Write-Host -ForegroundColor Red $Message
    $Message | Out-File -FilePath $Log -Append
    Send-Mail -MailCredential $Credential -To $MailTo -Body $Message -Subject "test ag failed"
    exit
}
else 
{
    # Run the health cmdlets
    $groupResult = Test-SqlAvailabilityGroup $groupObject -NoRefresh
    $replicaResults = @($groupObject.AvailabilityReplicas | Test-SqlAvailabilityReplica -NoRefresh)
    $databaseResults = @($groupObject.DatabaseReplicaStates | Test-SqlDatabaseReplicaState -NoRefresh)
    
    # Determine if any objects are in the critical state
    $groupIsCritical = $groupResult.HealthState -eq "Error"
    $criticalReplicas = @($replicaResults | Where-Object { $_.HealthState -eq "Error" })
    $criticalDatabases = @($databaseResults | Where-Object { $_.HealthState -eq "Error" })

    # If any objects are critical throw an error
    if($groupIsCritical -or $criticalReplicas.Count -gt 0 -or $criticalDatabases.Count -gt 0)
    {
        $Message = "###############################################################`r`n"
        $Message += "[ERROR] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
        $Message += "[ERROR] The availability group '$AgName' has objects in the critical state! Please investigate.`r`n"
        Write-Host -ForegroundColor Red $Message
        $Message | Out-File -FilePath $Log -Append
        Send-Mail -MailCredential $Credential -To $MailTo -Body $Message -Subject "test ag failed"
        exit
    }
}


$TotalUsed=(New-TimeSpan $StartTime).TotalMinutes

# Send mail
$Message = "###############################################################`r`n"
$Message += "[INFO] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n"
$Message += "[INFO] Create AG In Parallel successfully`r`n"
$Message += "[INFO] Total used $TotalUsed minutes`r`n"
$Message += "[DONE]`r`n"
Write-Host -ForegroundColor Green $Message
$Message | Out-File -FilePath $Log -Append
Send-Mail -MailCredential $Credential -To $MailTo -Body ($Message|Out-String) -Subject "Create AG in parallel successfully"
