<#PSScriptInfo
.VERSION 3.9.2

.GUID 482e19fb-a8f0-4e3c-acbc-63b535d6486e

.AUTHOR Tomas Rudh

.LICENSE

Copyright 2021 Tomas Rudh

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE
OR OTHER DEALINGS IN THE SOFTWARE.

.DESCRIPTION
    This Azure Automation runbook automates the scheduled shutdown and startup of virtual machines in an Azure subscription, based on tags on each machine.

.USAGE
    The runbook implements a solution for scheduled power management of Azure virtual machines in combination with tags
    on virtual machines or resource groups which define a shutdown schedule. Each time it runs, the runbook looks for all
    virtual machines or resource groups with a tag named "AutoShutdownSchedule" having a value defining the schedule,
    e.g. "10PM -> 6AM". It then checks the current time against each schedule entry, ensuring that VMs with tags or in tagged groups
    are shut down or started to conform to the defined schedule.

    This is a PowerShell runbook, as opposed to a PowerShell Workflow runbook.

    This runbook requires the "Az.Accounts", "Az.Compute" and "Az.Resources" modules which need to be added to the Azure Automation account.

    Valid tags:
    19:00->08:00            Turned off between 19 and 08
    Sunday                  Turned off sundays
    12-24                   Turned off 24th of December
    19:00->08:00,Sunday     Turned off between 19 and 08 and on Sundays
    17:00                   Turns off at 17, does never start, has to be alone in the tag

    PARAMETER AzureSubscriptionName
    The name or ID of Azure subscription in which the resources will be created. By default, the runbook will use
    the value defined in the Variable setting named "Default Azure Subscription"

    PARAMETER AzureEnvironmentName
    The name of an Azure Environment in which the Azure Subscription presides. By default, the runbook will use
    the value defined in the Variable setting named "Default Azure Environment".

    PARAMETER tz
    The name of the time zone you want to use. Run 'Get-TimeZone -ListAvailable' to get available timezone ID's.

    PARAMETER Simulate
    If $true, the runbook will not perform any power actions and will only simulate evaluating the tagged schedules. Use this
    to test your runbook to see what it will do when run normally (Simulate = $false).

.PROJECTURI https://github.com/tomasrudh/AutoShutdownSchedule

.TAGS
    Azure, Automation, Runbook, Start, Stop, Machine

.OUTPUTS
    Human-readable informational and error messages produced during the job. Not intended to be consumed by another runbook.

.CREDITS
    The script was originally created by Automys, https://automys.com/library/asset/scheduled-virtual-machine-shutdown-startup-microsoft-azure
#>

param(
    [parameter(Mandatory = $false)]
    [String] $AzureCredentialName = "Use *Default Automation Credential* Asset",
    [parameter(Mandatory = $false)]
    [String] $AzureSubscriptionName = "Use *Default Azure Subscription* Variable Value",
    [parameter(Mandatory = $false)]
    [String] $AzureEnvironmentName = "Use *Default Azure Environment* Variable Value",
    [parameter(Mandatory = $false)]
    [String] $tz = "Use *Default Time Zone* Variable Value",
    [parameter(Mandatory = $false)]
    [bool]$Simulate = $false,
    [parameter(Mandatory = $false)]
    [bool]$Deallocate = $true
)

$VERSION = "3.9.2"
$script:DoNotStart = $false

# Define function to check current time against specified range
function CheckScheduleEntry ([string]$TimeRange) {
    # Initialize variables
    $rangeStart, $rangeEnd, $parsedDay = $null
    $tempTime = (Get-Date).ToUniversalTime()
    $tzEST = [System.TimeZoneInfo]::FindSystemTimeZoneById($tz)
    $CurrentTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($tempTime, $tzEST)
    $midnight = $currentTime.AddDays(1).Date

    try {
        # Parse as range if contains '->'
        if ($TimeRange -like "*->*") {
            $timeRangeComponents = $TimeRange -split "->" | ForEach-Object { $_.Trim() }
            if ($timeRangeComponents.Count -eq 2) {
                $rangeStart = Get-Date $timeRangeComponents[0]
                $rangeEnd = Get-Date $timeRangeComponents[1]

                # Check for crossing midnight
                if ($rangeStart -gt $rangeEnd) {
                    # If current time is between the start of range and midnight tonight, interpret start time as earlier today and end time as tomorrow
                    if ($currentTime -ge $rangeStart -and $currentTime -lt $midnight) {
                        $rangeEnd = $rangeEnd.AddDays(1)
                    }
                    # Otherwise interpret start time as yesterday and end time as today
                    else {
                        $rangeStart = $rangeStart.AddDays(-1)
                    }
                }
            }
            else {
                Write-Output "`tWARNING: Invalid time range format. Expects valid .Net DateTime-formatted start time and end time separated by '->'"
            }
        }
        # Otherwise attempt to parse as a full day entry, e.g. 'Monday' or 'December 25'
        else {
            # If specified as day of week, check if today
            if ([System.DayOfWeek].GetEnumValues() -contains $TimeRange) {
                if ($TimeRange -eq (Get-Date).DayOfWeek) {
                    $parsedDay = Get-Date "00:00"
                }
                else {
                    # Skip detected day of week that isn't today
                }
            }
            elseif ($TimeRange -match '^([0-1]?[0-9]|[2][0-3]):([0-5][0-9])|([0-9]pm|am)$') {
                # Parse as time, e.g. '17:00'
                $parsedDay = $null
                $rangeStart = Get-Date $TimeRange
                $rangeStart = $rangeStart.AddDays((Get-Date).Day - $CurrentTime.Day)
                $rangeEnd = $rangeStart.AddMinutes(30) # Only match this hour
            }
            else {
                # Otherwise attempt to parse as a date, e.g. 'December 25'
                $parsedDay = Get-Date $TimeRange
            }

            if ($null -ne $parsedDay) {
                $rangeStart = $parsedDay # Defaults to midnight
                $rangeEnd = $parsedDay.AddHours(23).AddMinutes(59).AddSeconds(59) # End of the same day
            }
        }
    }
    catch {
        # Record any errors and return false by default
        Write-Output "`tWARNING: Exception encountered while parsing time range. Details: $($_.Exception.Message). Check the syntax of entry, e.g. '<StartTime> -> <EndTime>', or days/dates like 'Sunday' and 'December 25'"
        return $false
    }

    # Check if current time falls within range
    if ($currentTime -ge $rangeStart -and $currentTime -le $rangeEnd) {
        return $true
    }
    else {
        return $false
    }

} # End function CheckScheduleEntry

# Function to handle power state assertion for resource manager VMs
function AssertVirtualMachinePowerState {
    param(
        [Object]$VirtualMachine,
        [string]$RGName,
        [string]$DesiredState,
        [Object[]]$ResourceManagerVMList,
        [Object[]]$ClassicVMList,
        [bool]$Simulate
    )

    $resourceManagerVM = $ResourceManagerVMList | Where-Object { $_.Name -eq $VirtualMachine.Name -and $_.ResourceGroupName -eq $RGName }
    AssertResourceManagerVirtualMachinePowerState -VirtualMachine $resourceManagerVM -DesiredState $DesiredState -Simulate $Simulate
}

# Function to handle power state assertion for resource manager VM
function AssertResourceManagerVirtualMachinePowerState {
    param(
        [Object]$VirtualMachine,
        [string]$DesiredState,
        [bool]$Simulate
    )

    #Write-Host $VirtualMachine

    # Get VM with current status
    $resourceManagerVM = Get-AzVM -ResourceGroupName $VirtualMachine.ResourceGroupName -Name $VirtualMachine.Name -Status
    $currentStatus = $resourceManagerVM.Statuses | Where-Object Code -Like "PowerState*"
    $currentStatus = $currentStatus.Code -replace "PowerState/", ""

    # If should be started and isn't, start VM
    if ($DesiredState -eq "Started" -and $currentStatus -notmatch "running") {
        if ($DoNotStart -eq $true) {
            Write-Output "[$($VirtualMachine.Name)]: This tag never starts VMs"
        }
        else {
            if ($Simulate) {
                Write-Output "[$($VirtualMachine.Name)]: SIMULATION -- Would have started VM. (No action taken)"
            }
            else {
                Write-Output "[$($VirtualMachine.Name)]: Starting VM"
                $resourceManagerVM | Start-AzVM -NoWait > $null
            }
        }
    }

    # If should be stopped and isn't, stop VM
    elseif ($DesiredState -eq "StoppedDeallocated" -and $currentStatus -ne "deallocated") {
        if ($Simulate) {
            Write-Output "[$($VirtualMachine.Name)]: SIMULATION -- Would have stopped VM. (No action taken)"
        }
        else {
            Write-Output "[$($VirtualMachine.Name)]: Stopping VM"
            $resourceManagerVM | Stop-AzVM -NoWait -Force > $null
        }
    }

    # Otherwise, current power state is correct
    else {
        Write-Output "[$($VirtualMachine.Name)]: Current power state [$currentStatus] is correct."
    }
}

# Function to  deallocate the virtual machine that is stopped but not deallocated
function DeallocateVirtualMachine {
    param(
        [Object]$VirtualMachine,
        [bool]$Simulate,
        [bool]$Deallocate
    )
    # Get VM with current status
    $resourceManagerVM = Get-AzVM -ResourceGroupName $VirtualMachine.ResourceGroupName -Name $VirtualMachine.Name -Status
    $currentStatus = $resourceManagerVM.Statuses | Where-Object Code -Like "PowerState*"
    $currentStatus = $currentStatus.Code -replace "PowerState/", ""

    # If stopped but not deallocated, deallocate
    if ($currentStatus -eq 'stopped') {
        Write-Output "[$($VirtualMachine.Name)]: The virtual machine is stopped but not deallocated, charges still incurred"
        if ($Deallocate) {
            if ($Simulate) {
                Write-Output "[$($VirtualMachine.Name)]: SIMULATION -- Would have deallocated VM. (No action taken)"
            }
            else {
                Write-Output "[$($VirtualMachine.Name)]: Deallocating VM"
                $resourceManagerVM | Stop-AzVM -NoWait -Force > $null
            }
        }
        else {
            Write-Output "The setting Deallocate is set to False"
        }
    }
}

function ValidateScheduleList ($TimeRangeList) {
    $TagRange = 0
    $TagDay = 0
    $TagTime = 0
    $TagInvalid = 0
    $TimeRanges = @($TimeRangeList -split "," | ForEach-Object { $_.Trim() })
    foreach ($TimeRange in $TimeRanges) {
        try {
            if ($TimeRange -like '*->*') {
                #$Times = $TimeRange.Split('->')
                $Divider = $TimeRange.IndexOf('->')
                $Times = @($TimeRange.Substring(0, $Divider), $TimeRange.Substring($Divider + 2))
                $InError = $false
                foreach ($Time in $Times) {
                    if ($Time -notmatch '^(([0-1]?[0-9]|[2][0-3]):([0-5][0-9])|([0-1]?[0-9](pm|am)))$') {
                        $InError = $true
                    }
                }
                if ($InError) {
                    $TagInvalid += 1
                }
                else {
                    $TagRange += 1
                }
            }
            elseif ($TimeRange -match '^(([0-1]?[0-9]|[2][0-3]):([0-5][0-9])|([0-1]?[0-9](pm|am)))$') {
                $TagTime += 1
                $script:DoNotStart = $true
            }
            elseif ([System.DayOfWeek].GetEnumValues() -contains $TimeRange) { $TagDay += 1 }
            elseif (Get-Date $TimeRange) { $TagDay += 1 }
            else { $TagInvalid += 1 }
        }
        catch {
            $TagInvalid += 1
        }
    }
    if ($TagInvalid -gt 0) {
        return "Invalid tag: '$TimeRangeList'"
    }
    elseif ($TagTime -gt 0 -and (($TagRange -gt 0) -or ($TagDay -gt 0))) {
        return "Time has to be alone in the tag: '$TimeRangeList'"
    }
    return 'OK'
}

# Main runbook content
try {
    # Ensures you do not inherit an AzContext in your runbook
    Disable-AzContextAutosave -Scope Process
    # Retrieve time zone name from variable asset if not specified
    if ($tz -eq "Use *Default Time Zone* Variable Value") {
        $tz = Get-AutomationVariable -Name "Default Time Zone"
        if ($tz.length -gt 0) {
            Write-Output "Specified time zone: [$tz]"
        }
        else {
            #throw "No time zone was specified, and no variable asset with name 'Default Time Zone' was found. Either specify a time zone or define the default using a variable setting"
            Write-Output "No time zone was specified, and no variable asset with name 'Default Time Zone' was found, will use UTC"
            $tz = 'UTC'

        }
    }

    $tempTime = (Get-Date).ToUniversalTime()
    $tzEST = [System.TimeZoneInfo]::FindSystemTimeZoneById($tz)
    $CurrentTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($tempTime, $tzEST)

    Write-Output "Runbook started. Version: $VERSION"
    if ($Simulate) {
        Write-Output "*** Running in SIMULATE mode. No power actions will be taken. ***"
    }
    else {
        Write-Output "*** Running in LIVE mode. Schedules will be enforced. ***"
    }
    Write-Output "Current $tz time [$($currentTime.ToString("dddd, yyyy MMM dd HH:mm:ss"))] will be checked against schedules"

    # Retrieve subscription name from variable asset if not specified
    if ($AzureSubscriptionName -eq "Use *Default Azure Subscription* Variable Value") {
        $AzureSubscriptionName = Get-AutomationVariable -Name "Default Azure Subscription" -ErrorAction Ignore
        if ($AzureSubscriptionName.length -gt 0) {
            Write-Output "Specified subscription name/ID: [$AzureSubscriptionName]"
        }
    }

    # Retrieve Azure environment from variable if not specified
    if ($AzureEnvironmentName -eq "Use *Default Azure Environment* Variable Value") {
        $AzureEnvironmentName = Get-AutomationVariable -Name "Default Azure Environment" -ErrorAction Ignore
        if ($AzureEnvironmentName.length -gt 0) {
            Write-Output "Specified Azure Environment: [$AzureEnvironmentName]"
        }
        else {
            Write-Output "No Azure Environment was specified, and no variable asset with name 'Default Azure Environment' was found, will use AzureCloud"
            $AzureEnvironmentName = 'AzureCloud'
        }
    }
    # Retrieve credential

    $ManagedIdentityId = Get-AutomationVariable -Name "Managed Identity ID" -ErrorAction Ignore
    $RunAsConnection = Get-AutomationConnection -Name "AzureRunAsConnection" -ErrorAction Ignore
    if ($ManagedIdentityId -eq 'System') {
        Write-Output ("Logging in to Azure using the system managed identity...")
        if ($AzureSubscriptionName.Length -eq 0) {
            throw "No subscription indicated"
        }
        Connect-AzAccount -Identity -Subscription $AzureSubscriptionName -EnvironmentName $AzureEnvironmentName > $null
    }
    elseif ($ManagedIdentityId) {
        Write-Output "Logging in to Azure using the user managed identity..."
        if ($AzureSubscriptionName.Length -eq 0) {
            throw "No subscription indicated"
        }
        Connect-AzAccount -Identity -AccountId $ManagedIdentityId -Subscription $AzureSubscriptionName -EnvironmentName $AzureEnvironmentName > $null
    }
    elseif ($RunAsConnection) {
        Write-Output ("Logging in to Azure using the runas account...")
        Connect-AzAccount -ServicePrincipal `
            -TenantId $RunAsConnection.TenantId `
            -ApplicationId $RunAsConnection.ApplicationId `
            -CertificateThumbprint $RunAsConnection.CertificateThumbprint `
            -SubscriptionId $RunAsConnection.SubscriptionId `
            -EnvironmentName $AzureEnvironmentName > $null
    }
    else {
        Write-Output "Logging in to Azure using the supplied credentials"
        Write-Output "Specified credential asset name: [$AzureCredentialName]"
        if ($AzureCredentialName -eq "Use *Default Automation Credential* asset") {
            # By default, look for "Default Automation Credential" asset
            $azureCredential = Get-AutomationPSCredential -Name "Default Automation Credential"
            if ($null -ne $azureCredential) {
                Write-Output "Attempting to authenticate as: [$($azureCredential.UserName)]"
            }
            else {
                throw "No runas account and no automation credential name was specified, and no credential asset with name 'Default Automation Credential' was found. Either specify a runas account, a stored credential name or define the default using a credential asset"
            }
        }
        else {
            # A different credential name was specified, attempt to load it
            $azureCredential = Get-AutomationPSCredential -Name $AzureCredentialName
            if ($null -eq $azureCredential) {
                throw "Failed to get credential with name [$AzureCredentialName]"
            }
        }

        # Connect to Azure using credential asset (AzureRM)
        if ($AzureSubscriptionName.Length -eq 0) {
            throw "No subscription indicated"
        }
        $account = Connect-AzAccount -Credential $azureCredential -SubscriptionName $AzureSubscriptionName -EnvironmentName $AzureEnvironmentName

        # Check for returned userID, indicating successful authentication
        #if(Get-AzureAccount -Name $azureCredential.UserName)
        if ($account.Context.Account.Id -eq $azureCredential.UserName) {
            Write-Output "Successfully authenticated as user: [$($azureCredential.UserName)]"
        }
        else {
            throw "Authentication failed for credential [$($azureCredential.UserName)]. Ensure a valid Azure Active Directory user account is specified which is configured as subscription owner (modern portal) on the target subscription. Verify you can log into the Azure portal using these credentials."
        }
    }

    # If subscription is set in varable, use that. Otherwise use subscription from the runas account
    if ($AzureSubscriptionName.length -gt 0) {
        $AzureSubscriptionId = (Get-AzSubscription -SubscriptionName $AzureSubscriptionName).Id
    }
    else {
        $AzureSubscriptionId = $RunAsConnection.SubscriptionId
    }
    Set-AzContext -SubscriptionId $AzureSubscriptionId > $null

    # Validate subscription
    $subscriptions = @(Get-AzSubscription | Where-Object { $_.Name -eq $AzureSubscriptionName -or $_.Id -eq $AzureSubscriptionName })
    if ($subscriptions.Count -eq 1) {
        # Set working subscription
        $targetSubscription = $subscriptions | Select-Object -First 1
        $targetSubscription | Select-AzSubscription > $null

        #$currentSubscription = Get-AzSubscription
        Write-Output "Working against subscription: $($targetSubscription.Name) ($($targetSubscription.SubscriptionId))"
    }
    else {
        if ($subscription.Count -eq 0) {
            throw "No accessible subscription found with name or ID [$AzureSubscriptionName]."
        }
        elseif ($subscriptions.Count -gt 1) {
            throw "More than one accessible subscription found with name or ID [$AzureSubscriptionName]. Please ensure your subscription names are unique, or specify the ID instead"
        }
    }

    # Get a list of all virtual machines in subscription
    $resourceManagerVMList = Get-AzVM | Sort-Object Name

    # Get resource groups that are tagged for automatic shutdown of resources
    $taggedResourceGroups = @(Get-AzResourceGroup | Where-Object { $_.Tags.Count -gt 0 -and $_.Tags.AutoShutdownSchedule })
    $taggedResourceGroupNames = @($taggedResourceGroups | Select-Object -ExpandProperty ResourceGroupName)
    Write-Output "Found [$($taggedResourceGroups.Count)] schedule-tagged resource groups in subscription"

    # For each VM, determine
    #  - Is it directly tagged for shutdown or member of a tagged resource group
    #  - Is the current time within the tagged schedule
    # Then assert its correct power state based on the assigned schedule (if present)
    Write-Output "Processing [$($resourceManagerVMList.Count)] virtual machines found in subscription"
    foreach ($vm in $resourceManagerVMList) {
        $script:DoNotStart = $false
        # Deallocate all machines stopped and not deallocated, regardless of tags
        DeallocateVirtualMachine -VirtualMachine $vm -Simulate $Simulate -Deallocate $Deallocate

        $schedule = $null

        # Check for direct tag or group-inherited tag
        if ($vm.Tags -and $vm.Tags.AutoShutdownSchedule) {
            # VM has direct tag (possible for resource manager deployment model VMs). Prefer this tag schedule.
            $schedule = $vm.Tags.AutoShutdownSchedule
            Write-Output "[$($vm.Name)]: Found direct VM schedule tag with value: $schedule"
        }
        elseif ($taggedResourceGroupNames -contains $vm.ResourceGroupName) {
            # VM belongs to a tagged resource group. Use the group tag
            $parentGroup = $taggedResourceGroups | Where-Object ResourceGroupName -EQ $vm.ResourceGroupName
            $schedule = $parentGroup.Tags.AutoShutdownSchedule
            Write-Output "[$($vm.Name)]: Found parent resource group schedule tag with value: $schedule"
        }
        else {
            # No direct or inherited tag. Skip this VM.
            Write-Output "[$($vm.Name)]: Not tagged for shutdown directly or via membership in a tagged resource group. Skipping this VM."
            continue
        }

        # Check that tag value was succesfully obtained
        if ($null -eq $schedule) {
            Write-Output "[$($vm.Name)]: Failed to get tagged schedule for virtual machine. Skipping this VM."
            continue
        }

        $Result = ValidateScheduleList $($schedule -replace '\s','')
        if ($Result -ne 'OK') {
            Write-Error "[$($vm.Name)]: $Result. Skipping this VM."
            continue
        }

        # Parse the ranges in the Tag value. Expects a string of comma-separated time ranges, or a single time range
        $timeRangeList = @($schedule -split "," | ForEach-Object { $_.Trim() })

        # Check each range against the current time to see if any schedule is matched
        $scheduleMatched = $false
        $matchedSchedule = $null
        foreach ($entry in $timeRangeList) {
            if ((CheckScheduleEntry -TimeRange $entry) -eq $true) {
                $scheduleMatched = $true
                $matchedSchedule = $entry
                break
            }
        }

        # Enforce desired state for group resources based on result.
        if ($scheduleMatched) {
            # Schedule is matched. Shut down the VM if it is running.
            Write-Output "[$($vm.Name)]: Current time [$currentTime] falls within the scheduled shutdown range [$matchedSchedule]"
            AssertVirtualMachinePowerState -VirtualMachine $vm -RGName $vm.ResourceGroupName -DesiredState "StoppedDeallocated" -ResourceManagerVMList $resourceManagerVMList -ClassicVMList $classicVMList -Simulate $Simulate
        }
        else {
            # If the tag consists of a single date should the machine never be started
            try {
                if (Get-Date($schedule)) {
                    Write-Output "[$($vm.Name)]: Current time [$currentTime] falls outside the scheduled shutdown range [$schedule], single time so not changing the state."
                }
            }
            catch {
                Write-Output "[$($vm.Name)]: Current time falls outside of all scheduled shutdown ranges."
                AssertVirtualMachinePowerState -VirtualMachine $vm -RGName $vm.ResourceGroupName -DesiredState "Started" -ResourceManagerVMList $resourceManagerVMList -ClassicVMList $classicVMList -Simulate $Simulate
            }
        }
    }
    Write-Output "Finished processing virtual machine schedules"
}
catch {
    $errorMessage = $_.Exception.Message
    $line = $_.InvocationInfo.ScriptLineNumber
    throw "Unexpected exception: $errorMessage at $line"
}
finally {
    $tempTime = (Get-Date).ToUniversalTime()
    $EndTime = [System.TimeZoneInfo]::ConvertTimeFromUtc($tempTime, $tzEST)
    Write-Output "Runbook finished (Duration: $(("{0:hh\:mm\:ss}" -f ($EndTime - $currentTime))))"
}
