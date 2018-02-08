###########################################################
# SCRIPT PARAMETERS 
###########################################################

Param
(
    # Name of the server instances that will participate in the availability group.
    # The first server is assumed to be the initial primary, the others initial secondaries.
    [Parameter(Mandatory=$true)]
    [string[]] $ServerList,

    # Name of the availability group
    [string] $AgName = "MyAvailabilityGroup",

    # Names of the databases to add to availability group
    [string[]] $DatabaseList,
    
    # Directory for backup files
    [Parameter(Mandatory=$true)]
    [string] $BackupShare
)

###########################################################
# SCRIPT BODY 
###########################################################

# Initialize some collections
$serverObjects = @()
$replicas = @()

foreach ($server in $ServerList)
{
    # Connection to the server instance, using Windows authentication
    Write-Verbose "Creating SMO Server object for server: $server"
    $serverObject = New-Object Microsoft.SQLServer.Management.SMO.Server($server) 
    $serverObjects += $serverObject

    # Get the mirroring endpoint on the server
    $endpointObject = $serverObject.Endpoints | 
        Where-Object { $_.EndpointType -eq "DatabaseMirroring" } | 
        Select-Object -First 1

    # Create an endpoint if one doesn't exist
    if($endpointObject -eq $null)
    {
        throw "No Mirroring endpoint found on server: $server"
    }

    $fqdn = $serverObject.Information.FullyQualifiedNetName
    $port = $endpointObject.Protocol.Tcp.ListenerPort
    $endpointURL = "TCP://${fqdn}:${port}"

    # Create an availability replica for this server instance.
    # For this example all replicas use asynchronous commit, manual failover, and 
    # support reads on the secondaries
    $replicas += (New-SqlAvailabilityReplica `
            -Name $server `
            -EndpointUrl $endpointURL `
            -AvailabilityMode "AsynchronousCommit" `
            -FailoverMode "Manual" `
            -ConnectionModeInSecondaryRole "AllowAllConnections" `
            -AsTemplate `
            -Version 11) 
}

$primary, $secondaries = $serverObjects

# Create the initial copies of the databases on the secondaries,
# via backup/restore
foreach ($db in $DatabaseList)
{
    $bakFile = Join-Path $BackupShare "$db.bak"
    $trnFile = Join-Path $BackupShare "$db.trn"

    Write-Verbose "Backing up database '$db' on $primary to $bakFile"
    Backup-SqlDatabase -InputObject $primary -Database $db -BackupFile $bakFile -Init 
    Write-Verbose "Backing up the log of database '$db' on $primary to $trnFile"
    Backup-SqlDatabase -InputObject $primary -Database $db -BackupFile $trnFile -BackupAction "Log" -Init 

    foreach($secondary in $secondaries)
    {
        Write-Verbose "Restoring database '$db' on $secondary from $bakFile"
        Restore-SqlDatabase -InputObject $secondary -Database $db -BackupFile $bakFile -NoRecovery 
        Write-Verbose "Restoring the log of database '$db' on $secondary from $trnFile"
        Restore-SqlDatabase -InputObject $secondary -Database $db -BackupFile $trnFile -RestoreAction "Log" -NoRecovery 
    }
}

# Create the availability group
New-SqlAvailabilityGroup -Name $AgName -InputObject $primary -AvailabilityReplica $Replicas -Database $DatabaseList | Out-Null

# Join the secondary replicas, and join the databases on those replicas
foreach ($secondary in $secondaries)
{
    Write-Verbose "Joining secondary instance $secondary to the availability group '$AgName'"
    Join-SqlAvailabilityGroup -InputObject $secondary -Name $AgName
    $ag = $secondary.AvailabilityGroups[$AgName]
    Write-Verbose "Joining secondary databases on $seecondary to the availability group '$AgName'"
    Add-SqlAvailabilityDatabase -InputObject $ag -Database $DatabaseList 
}

