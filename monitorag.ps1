###########################################################
# Script Parameters
###########################################################

Param
(
    # The name of the server instance that hosts the availability group
    [Parameter(Mandatory=$true)]
    [string] $ServerName,

    # Name of the availability group to monitor
    [Parameter(Mandatory=$true)]
    [string] $GroupName
)

###########################################################
# Script Body 
###########################################################

# Connect to the server instance and set default init fields for 
# efficient loading of collections. We use windows authentication here,
# but this can be changed to use SQL Authentication if required.
$serverObject = New-Object Microsoft.SqlServer.Management.SMO.Server($ServerName)
$serverObject.SetDefaultInitFields([Microsoft.SqlServer.Management.Smo.AvailabilityGroup], $true)
$serverObject.SetDefaultInitFields([Microsoft.SqlServer.Management.Smo.AvailabilityReplica], $true)
$serverObject.SetDefaultInitFields([Microsoft.SqlServer.Management.Smo.DatabaseReplicaState], $true)

# Attempt to access the availability group object on the server
$groupObject = $serverObject.AvailabilityGroups[$GroupName]

if($groupObject -eq $null)
{
    # Can't find the availability group on the server.
    throw "The availability group '$GroupName' does not exist on server '$ServerName'."
}
elseif($groupObject.PrimaryReplicaServerName -eq $null)
{
    # Can't determine the primary server instance. This can be serious (may mean the AG is offline), so throw an error.
    throw "Cannot determine the primary replica of availability group '$GroupName' from server instance '$ServerName'. Please investigate!" 
}
elseif($groupObject.PrimaryReplicaServerName -ne $ServerName)
{
    # We're trying to run the script on a secondary replica, which we shouldn't do.
    # We'll just throw a warning in this case, however, and skip health evaluation.
    Write-Warning "The server instance '$ServerName' is not the primary replica for the availability group '$GroupName'. Skipping evaluation."
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
        throw "The availability group '$GroupName' has objects in the critical state! Please investigate."
    }
}

