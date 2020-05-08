﻿param(
	[Parameter(mandatory = $false)]
	[object]$WebHookData,

	# note: if this is enabled, the script will assume that all the authentication is already done in current or parent scope before calling this script
	[switch]$SkipAuth,

	# note: optional for simulating user sessions
	[System.Nullable[int]]$OverrideUserSessions
)
try {
	# Setting ErrorActionPreference to stop script execution when error occurs
	$ErrorActionPreference = "Stop"

	# If runbook was called from Webhook, WebhookData and its RequestBody will not be null.
	if (!$WebHookData -or [string]::IsNullOrWhiteSpace($WebHookData.RequestBody)) {
		throw 'Runbook was not started from Webhook (WebHookData or its RequestBody is empty)'
	}

	# Collect Input converted from JSON request body of Webhook.
	$Input = (ConvertFrom-Json -InputObject $WebHookData.RequestBody)

	$AADTenantId = $Input.AADTenantId
	$SubscriptionID = $Input.SubscriptionID
	$TenantGroupName = $Input.TenantGroupName
	$TenantName = $Input.TenantName
	$HostpoolName = $Input.hostpoolname
	$BeginPeakTime = $Input.BeginPeakTime
	$EndPeakTime = $Input.EndPeakTime
	$TimeDifference = $Input.TimeDifference
	$SessionThresholdPerCPU = $Input.SessionThresholdPerCPU
	[int]$MinimumNumberOfRDSH = $Input.MinimumNumberOfRDSH
	$LimitSecondsToForceLogOffUser = $Input.LimitSecondsToForceLogOffUser
	$LogOffMessageTitle = $Input.LogOffMessageTitle
	$LogOffMessageBody = $Input.LogOffMessageBody
	$MaintenanceTagName = $Input.MaintenanceTagName
	$LogAnalyticsWorkspaceId = $Input.LogAnalyticsWorkspaceId
	$LogAnalyticsPrimaryKey = $Input.LogAnalyticsPrimaryKey
	$RDBrokerURL = $Input.RDBrokerURL
	$AutomationAccountName = $Input.AutomationAccountName
	$ConnectionAssetName = $Input.ConnectionAssetName

	$DesiredRunningStates = ('Available', 'NeedsAssistance')

	Set-ExecutionPolicy -ExecutionPolicy Undefined -Scope Process -Force -Confirm:$false
	if (!$SkipAuth) {
		Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope LocalMachine -Force -Confirm:$false
	}

	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
	# Function to convert from UTC to Local time
	function Convert-UTCtoLocalTime {
		param(
			[string]$TimeDifferenceInHours
		)

		$UniversalTime = (Get-Date).ToUniversalTime()
		$TimeDifferenceMinutes = 0
		if ($TimeDifferenceInHours -match ":") {
			$TimeDifferenceHours = $TimeDifferenceInHours.Split(":")[0]
			$TimeDifferenceMinutes = $TimeDifferenceInHours.Split(":")[1]
		}
		else {
			$TimeDifferenceHours = $TimeDifferenceInHours
		}
		# Azure is using UTC time, justify it to the local time
		$ConvertedTime = $UniversalTime.AddHours($TimeDifferenceHours).AddMinutes($TimeDifferenceMinutes)
		return $ConvertedTime
	}

	# Function to add logs to log analytics workspace
	function Add-LogEntry {
		param(
			[Object]$LogMessageObj,
			[string]$LogAnalyticsWorkspaceId,
			[string]$LogAnalyticsPrimaryKey,
			[string]$LogType,
			[string]$TimeDifferenceInHours
		)

		# //todo use ConvertTo-JSON instead of manually converting using strings
		$LogData = ''
		foreach ($Key in $LogMessageObj.Keys) {
			switch ($Key.substring($Key.Length - 2)) {
				'_s' { $sep = '"'; $trim = $Key.Length - 2 }
				'_t' { $sep = '"'; $trim = $Key.Length - 2 }
				'_b' { $sep = ''; $trim = $Key.Length - 2 }
				'_d' { $sep = ''; $trim = $Key.Length - 2 }
				'_g' { $sep = '"'; $trim = $Key.Length - 2 }
				default { $sep = '"'; $trim = $Key.Length }
			}
			$LogData = $LogData + '"' + $Key.substring(0, $trim) + '":' + $sep + $LogMessageObj.Item($Key) + $sep + ','
		}
		$TimeStamp = Convert-UTCtoLocalTime -TimeDifferenceInHours $TimeDifferenceInHours
		$LogData = $LogData + '"TimeStamp":"' + $TimeStamp + '"'

		# Write-Verbose "LogData: $($LogData)"
		$json = "{$($LogData)}"

		$PostResult = Send-OMSAPIIngestionFile -customerId $LogAnalyticsWorkspaceId -sharedKey $LogAnalyticsPrimaryKey -Body "$json" -logType $LogType -TimeStampField "TimeStamp"
		# Write-Verbose "PostResult: $($PostResult)"
		if ($PostResult -ne "Accepted") {
			throw "Error posting to OMS: Result: $PostResult"
		}
	}

	function Write-Log {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$Message,
		
			[switch]$Err
		)

		# $WriteMessage = "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) [$($MyInvocation.MyCommand.Source): $($MyInvocation.ScriptLineNumber)] $Message"
		$WriteMessage = "$((Convert-UTCtoLocalTime -TimeDifferenceInHours $TimeDifference).ToString('yyyy-MM-dd HH:mm:ss')) [$($MyInvocation.ScriptLineNumber)] $Message"
		if ($Err) {
			Write-Error $WriteMessage
		}
		else {
			Write-Output $WriteMessage
		}
			
		if (!$LogAnalyticsWorkspaceId -or !$LogAnalyticsPrimaryKey) {
			return
		}
		$LogMessageObj = @{ hostpoolName_s = $HostpoolName; logmessage_s = $Message }
		Add-LogEntry -LogMessageObj $LogMessageObj -LogAnalyticsWorkspaceId $LogAnalyticsWorkspaceId -LogAnalyticsPrimaryKey $LogAnalyticsPrimaryKey -logType 'WVDTenantScale_CL' -TimeDifferenceInHours $TimeDifference
	}

	if (!$SkipAuth) {
		# Collect the credentials from Azure Automation Account Assets
		$Connection = Get-AutomationConnection -Name $ConnectionAssetName

		# Authenticate to Azure
		Clear-AzContext -Force
		$AZAuthentication = $null
		try {
			$AZAuthentication = Connect-AzAccount -ApplicationId $Connection.ApplicationId -TenantId $AADTenantId -CertificateThumbprint $Connection.CertificateThumbprint -ServicePrincipal
			if (!$AZAuthentication) {
				throw $AZAuthentication
			}
		}
		catch {
			throw [System.Exception]::new('Failed to authenticate Azure', $PSItem.Exception)
		}
		Write-Log "Successfully authenticated with Azure using service principal. Result: `n$($AZAuthentication | Out-String)"

		# Authenticating to WVD
		$WVDAuthentication = $null
		try {
			$WVDAuthentication = Add-RdsAccount -DeploymentUrl $RDBrokerURL -ApplicationId $Connection.ApplicationId -CertificateThumbprint $Connection.CertificateThumbprint -AADTenantId $AadTenantId
			if (!$WVDAuthentication) {
				throw $WVDAuthentication
			}
		}
		catch {
			throw [System.Exception]::new('Failed to authenticate WVD', $PSItem.Exception)
		}
		Write-Log "Successfully authenticated with WVD using service principal. Result: `n$($WVDAuthentication | Out-String)"
	}

	# Set the Azure context with Subscription
	$AzContext = $null
	try {
		Write-Log 'Set Azure context with the subscription'
		$AzContext = Set-AzContext -SubscriptionId $SubscriptionID
		if (!$AzContext) {
			throw $AzContext
		}
	}
	catch {
		throw [System.Exception]::new("Failed to set Azure context with provided Subscription ID: $SubscriptionID (Please provide a valid subscription)", $PSItem.Exception)
	}
	Write-Log "Successfully set the Azure context with the provided Subscription ID. Result: `n$($AzContext | Out-String)"

	# Set WVD context to the appropriate tenant group
	[string]$CurrentTenantGroupName = (Get-RdsContext).TenantGroupName
	if ($TenantGroupName -ne $CurrentTenantGroupName) {
		try {
			Write-Log "Switch WVD context to tenant group '$TenantGroupName' (current: '$CurrentTenantGroupName')"
			# note: as of Microsoft.RDInfra.RDPowerShell version 1.0.1534.2001 this throws a System.NullReferenceException when the $TenantGroupName doesn't exist.
			Set-RdsContext -TenantGroupName $TenantGroupName
		}
		catch {
			throw [System.Exception]::new("Error switch WVD context to tenant group '$TenantGroupName' from '$CurrentTenantGroupName'. This may be caused by the tenant group not existing or the user not having access to the tenant group", $PSItem.Exception)
		}
	}
	
	try {
		$tenant = $null
		$tenant = Get-RdsTenant -Name $TenantName
		if (!$tenant) {
			throw "No tenant with name '$TenantName' exists or the account doesn't have access to it."
		}
	}
	catch {
		throw [System.Exception]::new("Error getting the tenant '$TenantName'. This may be caused by the tenant not existing or the account doesn't have access to the tenant", $PSItem.Exception)
	}

	<#
	.Description
	Helper functions
	#>
	# Function to check and update the loadbalancer type to BreadthFirst
	function UpdateLoadBalancerTypeInPeakandOffPeakwithBreadthFirst {
		param(
			[string]$HostpoolLoadbalancerType,
			[string]$TenantName,
			[string]$HostpoolName,
			[int]$MaxSessionLimitValue
		)
		if ($HostpoolLoadbalancerType -ne "BreadthFirst") {
			Write-Log "Update HostPool with LoadBalancerType: 'BreadthFirst' (current: '$HostpoolLoadbalancerType'), MaxSessionLimit: $MaxSessionLimitValue. Current Date Time is: $CurrentDateTime"
			Set-RdsHostPool -TenantName $TenantName -Name $HostpoolName -BreadthFirstLoadBalancer -MaxSessionLimit $MaxSessionLimitValue
		}
	}

	# Function to update session host to allow new sessions
	function UpdateSessionHostToAllowNewSessions {
		param(
			[string]$TenantName,
			[string]$HostpoolName,
			[string]$SessionHostName
		)

		$StateOftheSessionHost = Get-RdsSessionHost -TenantName $TenantName -HostPoolName $HostpoolName -Name $SessionHostName
		if (!($StateOftheSessionHost.AllowNewSession)) {
			Write-Log "Update session host '$SessionHostName' to allow new sessions"
			Set-RdsSessionHost -TenantName $TenantName -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession $true
		}
	}

	# Function to start the Session Host
	function Start-SessionHost {
		param(
			[string]$TenantName,
			[string]$HostpoolName,
			[string]$SessionHostName
		)
		
		# Update session host to allow new sessions
		UpdateSessionHostToAllowNewSessions -TenantName $TenantName -HostPoolName $HostpoolName -SessionHostName $SessionHostName

		# Get the status of the VM
		$VMName = $SessionHostName.Split(".")[0]
		$VM = $null
		$StartVMJob = $null
		try {
			$VM = Get-AzVM -Name $VMName -Status
			if (!$VM) {
				throw "Session host VM '$VMName' not found in Azure"
			}
			if ($VM.Count -gt 1) {
				throw "More than 1 VM found in Azure with same Session host name '$VMName' (This is not supported):`n$($VM | Out-String)"
			}

			# Start the VM as a background job
			# //todo why as a background job ?
			Write-Log "Start VM '$VMName' as a background job"
			$StartVMJob = $VM | Start-AzVM -AsJob
			if (!$StartVMJob -or $StartVMJob.State -eq 'Failed') {
				throw $StartVMJob.Error
			}
		}
		catch {
			throw [System.Exception]::new("Failed to start Azure VM '$($VMName)'", $PSItem.Exception)
		}

		# Wait for the VM to start
		Write-Log "Wait for VM '$VMName' to start"
		# //todo may be add a timeout
		while (!$VM -or $VM.PowerState -ne 'VM running') {
			if ($StartVMJob.State -eq 'Failed') {
				throw [System.Exception]::new("Failed to start Azure VM '$($VMName)'", $StartVMJob.Error)
			}

			# Write-Log "VM power state: '$($VM.PowerState)', continue waiting"
			$VM = Get-AzVM -Name $VMName -Status # this takes at least about 15 sec
		}
		Write-Log "VM '$($VM.Name)' is now in '$($VM.PowerState)' power state"

		# Wait for the session host to be available
		$SessionHost = $null
		Write-Log "Wait for session host '$SessionHostName' to be available"
		# //todo may be add a timeout
		# //todo check for multi desired states including 'NeedsAssistance'
		while (!$SessionHost -or $SessionHost.Status -notin $DesiredRunningStates) {
			# Write-Log "Session host status: '$($SessionHost.Status)', continue waiting"
			Start-Sleep -Seconds 5
			$SessionHost = Get-RdsSessionHost -TenantName $TenantName -HostPoolName $HostpoolName -Name $SessionHostName
		}
		Write-Log "Session host '$SessionHostName' is now in '$($SessionHost.Status)' state"
	}

	# Function to stop the Session Host as a background job
	function Stop-SessionHost {
		param(
			[string]$VMName
		)
		try {
			Write-Log "Stop VM '$VMName' as a background job"
			Get-AzVM -Name $VMName | Stop-AzVM -Force -AsJob | Out-Null
		}
		catch {
			throw [System.Exception]::new("Failed to stop Azure VM: $($VMName)", $PSItem.Exception)
		}
	}

	# Check given HostPool name exists in Tenant
	$HostpoolInfo = $null
	try {
		Write-Log "Get Hostpool info: $HostpoolName in Tenant: $TenantName"
		$HostpoolInfo = Get-RdsHostPool -TenantName $TenantName -Name $HostpoolName
		if (!$HostpoolInfo) {
			throw $HostpoolInfo
		}
	}
	catch {
		throw [System.Exception]::new("Hostpool '$HostpoolName' does not exist in the tenant '$TenantName'. Ensure that you have entered the correct values.", $PSItem.Exception)
	}

	# Check if the hostpool has session hosts
	Write-Log 'Get all session hosts'
	$ListOfSessionHosts = Get-RdsSessionHost -TenantName $TenantName -HostPoolName $HostpoolName
	if (!$ListOfSessionHosts) {
		Write-Log "There are no session hosts in the Hostpool '$HostpoolName'. Ensure that hostpool have session hosts."
		exit
	}
	
	# Convert date time from UTC to Local
	$CurrentDateTime = Convert-UTCtoLocalTime -TimeDifferenceInHours $TimeDifference

	$BeginPeakDateTime = [datetime]::Parse($CurrentDateTime.ToShortDateString() + ' ' + $BeginPeakTime)
	$EndPeakDateTime = [datetime]::Parse($CurrentDateTime.ToShortDateString() + ' ' + $EndPeakTime)

	# Check: the calculated end time is later than begin time in case of time zone
	if ($EndPeakDateTime -lt $BeginPeakDateTime) {
		if ($CurrentDateTime -lt $EndPeakDateTime) {
			$BeginPeakDateTime = $BeginPeakDateTime.AddDays(-1)
		}
		else {
			$EndPeakDateTime = $EndPeakDateTime.AddDays(1)
		}
	}

	Write-Log "Using current time: $($CurrentDateTime.ToString('yyyy-MM-dd HH:mm:ss')), begin peak time: $($BeginPeakDateTime.ToString('yyyy-MM-dd HH:mm:ss')), end peak time: $($EndPeakDateTime.ToString('yyyy-MM-dd HH:mm:ss'))"

	# Set up appropriate load balacing type
	[string]$HostpoolLoadbalancerType = $HostpoolInfo.LoadBalancerType
	[int]$MaxSessionLimitValue = $HostpoolInfo.MaxSessionLimit
	# //todo maybe do this inline
	# note: both of the if else blocks are same. Breadth 1st is enforced on AND off peak hours to simplify the things with scaling in the start/end of peak hours
	if ($CurrentDateTime -ge $BeginPeakDateTime -and $CurrentDateTime -le $EndPeakDateTime) {
		UpdateLoadBalancerTypeInPeakandOffPeakwithBreadthFirst -TenantName $TenantName -HostPoolName $HostpoolName -MaxSessionLimitValue $MaxSessionLimitValue -HostpoolLoadbalancerType $HostpoolLoadbalancerType
	}
	else {
		UpdateLoadBalancerTypeInPeakandOffPeakwithBreadthFirst -TenantName $TenantName -HostPoolName $HostpoolName -MaxSessionLimitValue $MaxSessionLimitValue -HostpoolLoadbalancerType $HostpoolLoadbalancerType
	}

	# //todo avoid unnecesary API cals if can to prevent the API from throttling
	# Get the HostPool info after changing hostpool loadbalancer type
	Write-Log 'Get Hostpool info'
	$HostpoolInfo = Get-RdsHostPool -TenantName $TenantName -Name $HostPoolName

	Write-Log "HostPool info:`n$($HostpoolInfo | Out-String)"
	Write-Log "Number of session hosts in the HostPool: $($ListOfSessionHosts.Count)"
	# Write-Log 'Start WVD session hosts scale optimization'

	# Number of running session hosts
	[int]$NumberOfRunningHost = 0
	# Total number of running cores
	[int]$TotalRunningCores = 0

	$VMs = @{}
	$ListOfSessionHosts | ForEach-Object {
		$VMs.Add($_.SessionHostName.Split('.')[0].ToLower(), @{ 'SessionHost' = $_; 'Instance' = $null })
	}
	$VMCores = @{}
	
	Write-Log 'Get all VMs, check session host status and get usage info'
	Get-AzVM -Status | ForEach-Object {
		$VMInstance = $_
		if (!$VMs.ContainsKey($VMInstance.Name.ToLower())) {
			return
		}
		$VMName = $VMInstance.Name.ToLower()
		# Check if VM is in maintenance
		if ($VMInstance.Tags.Keys -contains $MaintenanceTagName) {
			Write-Log "VM '$VMName' is in maintenance and will be ignored"
			$VMs.Remove($VMName)
			return
		}

		$VM = $VMs[$VMName]
		if ($VM.Instance) {
			throw "More than 1 VM found in Azure with same session host name '$($VM.SessionHost.SessionHostName)' (This is not supported):`n$($VMInstance | Out-String)`n$($VM.Instance | Out-String)"
		}

		$VM.Instance = $VMInstance
		$SessionHost = $VM.SessionHost

		Write-Log "Session host '$($SessionHost.SessionHostName)' with power state: $($VMInstance.PowerState), status: $($SessionHost.Status), update state: $($SessionHost.UpdateState), sessions: $($SessionHost.Sessions)"
		if (!$VMCores.ContainsKey($VMInstance.HardwareProfile.VmSize)) {
			Write-Log "Get all Azure VM sizes in location: $($VMInstance.Location)"
			Get-AzVMSize -Location $VMInstance.Location | ForEach-Object { $VMCores.Add($_.Name, $_.NumberOfCores) }
		}
		# Check if the Azure vm is running
		if ($VMInstance.PowerState -eq 'VM running') {
			if ($SessionHost.Status -notin $DesiredRunningStates) {
				Write-Log "[WARN] VM is in running state but session host is not (this could be because the VM was just started and has not connected to broker yet)"
			}

			++$NumberOfRunningHost
			$TotalRunningCores += $VMCores[$VMInstance.HardwareProfile.VmSize]
		}
	}
		
	$AllSessionHosts = $VMs.Values.SessionHost
	$HostPoolUserSessions = $null
	if ($null -eq $OverrideUserSessions) {
		Write-Log 'Get user sessions in Hostpool'
		$HostPoolUserSessions = Get-RdsUserSession -TenantName $TenantName -HostPoolName $HostpoolName
	}
	else {
		$HostPoolUserSessions = @{ Count = $OverrideUserSessions }
	}
	# Calculate available capacity of sessions on running VMs
	$AvailableSessionCapacity = $TotalRunningCores * $SessionThresholdPerCPU

	Write-Log "Current number of running session hosts: $NumberOfRunningHost of total $($AllSessionHosts.Count), user sessions: $($HostPoolUserSessions.Count) of total capacity: $AvailableSessionCapacity"
	Write-Log "Minimum number of session hosts required: $MinimumNumberOfRDSH"

	if ($NumberOfRunningHost -eq $AllSessionHosts.Count -and $AllSessionHosts.Count -le $MinimumNumberOfRDSH) {
		Write-Log '//todo all host are already running but min num of host is more than'
		return
	}
	
	[int]$minVMsToStart = 0
	if ($NumberOfRunningHost -lt $MinimumNumberOfRDSH) {
		$minVMsToStart = $MinimumNumberOfRDSH - $NumberOfRunningHost
	}

	Write-Log 'Get Azure automation account info'
	$AutomationAccount = Get-AzAutomationAccount | Where-Object { $_.AutomationAccountName -eq $AutomationAccountName }

	# Check if it is during the peak or off-peak time
	if ($CurrentDateTime -ge $BeginPeakDateTime -and $CurrentDateTime -le $EndPeakDateTime) {
		# //todo refactor logging
		Write-Log 'It is in peak hours now, start session hosts as needed based on current workloads'

		# //todo centralize managing az auto acc var & log
		# Peak hours: check and remove the MinimumNoOfRDSH value dynamically stored in automation variable
		Write-Log 'Get Azure automation OffPeakUsage-MinimumNoOfRDSH variable'
		$OffPeakUsageMinimumNoOfRDSH = Get-AzAutomationVariable -Name "$HostpoolName-OffPeakUsage-MinimumNoOfRDSH" -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName -ErrorAction SilentlyContinue
		if ($OffPeakUsageMinimumNoOfRDSH) {
			Write-Log 'Delete Azure automation OffPeakUsage-MinimumNoOfRDSH variable'
			Remove-AzAutomationVariable -Name "$HostpoolName-OffPeakUsage-MinimumNoOfRDSH" -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName
		}
		
		$minCoresToStart = 0
		if ($HostPoolUserSessions.Count -ge $AvailableSessionCapacity) {
			$minCoresToStart = ($HostPoolUserSessions.Count - $AvailableSessionCapacity) / $SessionThresholdPerCPU
		}
		Write-Log "minVMsToStart: $minVMsToStart, minCoresToStart: $minCoresToStart"
		if (!$minVMsToStart -and !$minCoresToStart) {
			return
		}
		$VMsToStart = @{}
		foreach ($VM in $VMs.Values) {
			if (!$minVMsToStart -and !$minCoresToStart) {
				break
			}
			if ($VM.Instance.PowerState -eq 'VM running') {
				continue
			}
			if ($VM.SessionHost.UpdateState -ne 'Succeeded') {
				Write-Log "[WARN] Session host '$($VM.SessionHost.SessionHostName)' is not healthy to start"
				continue
			}
			Write-Log "//todo start $($VM.SessionHost.SessionHostName)"
			$VMsToStart.Add($VM.Instance.Name.ToLower(), $VM)
			# Start-SessionHost -TenantName $TenantName -HostPoolName $HostpoolName -SessionHostName $SessionHost
			--$minVMsToStart
			if ($minVMsToStart -lt 0) {
				$minVMsToStart = 0
			}
			$minCoresToStart -= $VMCores[$VM.Instance.Name.ToLower()]
			if ($minCoresToStart -lt 0) {
				$minCoresToStart = 0
			}
		}
		Write-Log "after: minVMsToStart: $minVMsToStart, minCoresToStart: $minCoresToStart"
		if ($minVMsToStart -or $minCoresToStart) {
			Write-Log '//todo'
		}
		return
	}
	<#
	if (min VMs to start) {
		get min Cores to start
		return
	}

	current design:
	if (no sesion host is avail) {
		while (num of running host < min num of host) {
			start
		}
	}

	if (num of running host > min num of host) {
		
	}
	
	#>
	# //todo remove else
	else {
		Write-Log 'It is off peak hours, start to scale down WVD session hosts ...'
		
		# Check if minimum number rdsh vm's are running in off peak hours
		$CheckMinimumNumberOfRDShIsRunning = Get-RdsSessionHost -TenantName $TenantName -HostPoolName $HostpoolName | Where-Object { $_.Status -in $DesiredRunningStates }
		$ListOfSessionHosts = Get-RdsSessionHost -TenantName $TenantName -HostPoolName $HostpoolName
		if (!$CheckMinimumNumberOfRDShIsRunning) {
			# changes from https://github.com/Azure/RDS-Templates/pull/439/
			foreach ($SessionHostName in $ListOfSessionHosts.SessionHostName) {
				if ($NumberOfRunningHost -lt $MinimumNumberOfRDSH) {
					$VMName = $SessionHostName.Split(".")[0]
					# //todo prepare the list of all VMs with RG before hand to save time
					$RoleInstance = Get-AzVM -Status -Name $VMName
					# Check if the session host is in maintenance
					if ($RoleInstance.Tags.Keys -contains $MaintenanceTagName) {
						continue
					}

					# //todo do this in parallel
					Start-SessionHost -TenantName $TenantName -HostPoolName $HostpoolName -SessionHostName $SessionHostName

					[int]$NumberOfRunningHost = [int]$NumberOfRunningHost + 1
					if ($NumberOfRunningHost -ge $MinimumNumberOfRDSH) {
						break;
					}
				}
			}
		}

		$ListOfSessionHosts = Get-RdsSessionHost -TenantName $TenantName -HostPoolName $HostpoolName | Sort-Object Sessions
		# changes from https://github.com/Azure/RDS-Templates/pull/439/
		$NumberOfRunningHost = 0
		foreach ($SessionHost in $ListOfSessionHosts) {
			$SessionHostName = $SessionHost.SessionHostName
			$VMName = $SessionHostName.Split(".")[0]
			# //todo prepare the list of all VMs with RG before hand to save time
			$RoleInstance = Get-AzVM -Status -Name $VMName
			# Check if the session host is in maintenance
			if ($RoleInstance.Tags.Keys -contains $MaintenanceTagName) {
				Write-Log "Session host is in maintenance: $VMName, so script will skip this VM"
				$SkipSessionhosts += $SessionHost
				continue
			}
			# Maintenance VMs skipped and stored into a variable
			$AllSessionHosts = $ListOfSessionHosts | Where-Object { $SkipSessionhosts -notcontains $_ }
			if ($SessionHostName.ToLower().StartsWith($RoleInstance.Name.ToLower())) {
				# Check if the Azure VM is running
				if ($RoleInstance.PowerState -eq "VM running") {
					Write-Log "Checking session host: $($SessionHost.SessionHostName) with sessions: $($SessionHost.Sessions) and status: $($SessionHost.Status)"
					[int]$NumberOfRunningHost = [int]$NumberOfRunningHost + 1
					# //todo prepare the list of all VM sizes before hand to save time
					# Calculate available capacity of sessions  
					$RoleSize = Get-AzVMSize -Location $RoleInstance.Location | Where-Object { $_.Name -eq $RoleInstance.HardwareProfile.VmSize }
					[int]$TotalRunningCores = [int]$TotalRunningCores + $RoleSize.NumberOfCores
				}
			}
		}
		# Defined minimum no of rdsh value from webhook data
		[int]$DefinedMinimumNumberOfRDSH = [int]$MinimumNumberOfRDSH
		# Check and collect dynamically stored MinimumNoOfRDSH value
		$OffPeakUsageMinimumNoOfRDSH = Get-AzAutomationVariable -Name "$HostpoolName-OffPeakUsage-MinimumNoOfRDSH" -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName -ErrorAction SilentlyContinue
		if ($OffPeakUsageMinimumNoOfRDSH) {
			[int]$MinimumNumberOfRDSH = $OffPeakUsageMinimumNoOfRDSH.Value
			if ($MinimumNumberOfRDSH -lt $DefinedMinimumNumberOfRDSH) {
				throw "Don't enter the value of '$HostpoolName-OffPeakUsage-MinimumNoOfRDSH' manually, which is dynamically stored value by script. You have entered manually, so script will stop now."
			}
		}

		# Breadth first session hosts shutdown in off peak hours
		if ($NumberOfRunningHost -gt $MinimumNumberOfRDSH) {
			foreach ($SessionHost in $AllSessionHosts) {
				# Check the status of the session host
				if ($SessionHost.Status -in $DesiredRunningStates) {
					if ($NumberOfRunningHost -gt $MinimumNumberOfRDSH) {
						$SessionHostName = $SessionHost.SessionHostName
						$VMName = $SessionHostName.Split(".")[0]
						if ($SessionHost.Sessions -eq 0) {
							# Shutdown the Azure VM session host that has 0 sessions
							Write-Log "Stopping Azure VM: $VMName and waiting for it to complete ..."
							# //todo do this in parallel
							Stop-SessionHost -VMName $VMName
						}
						else {
							# changes from https://github.com/Azure/RDS-Templates/pull/439/, https://github.com/Azure/RDS-Templates/pull/467/
							if ($LimitSecondsToForceLogOffUser -eq 0) {
								continue
							}
							# Ensure the running Azure VM is set as drain mode
							try {
								# changes from https://github.com/Azure/RDS-Templates/pull/439/, https://github.com/Azure/RDS-Templates/pull/467/
								# //todo this may need to be prevented from logging as it may get logged at a lot
								Set-RdsSessionHost -TenantName $TenantName -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession $false
								# Set-RdsSessionHost -TenantName $TenantName -HostPoolName $HostpoolName -Name $SessionHostName -AllowNewSession $false | Out-Null
							}
							catch {
								throw [System.Exception]::new("Unable to set it to disallow connections on session host: $SessionHostName", $PSItem.Exception)
							}
							# Notify user to log off session
							# Get the user sessions in the hostpool
							try {
								$HostPoolUserSessions = Get-RdsUserSession -TenantName $TenantName -HostPoolName $HostpoolName | Where-Object { $_.SessionHostName -eq $SessionHostName }
							}
							catch {
								throw [System.Exception]::new("Failed to retrieve user sessions in hostpool: $($HostpoolName)", $PSItem.Exception)
							}
							$HostUserSessionCount = ($HostPoolUserSessions | Where-Object -FilterScript { $_.SessionHostName -eq $SessionHostName }).Count
							Write-Log "Counting the current sessions on the host $SessionHostName :$HostUserSessionCount"
							$ExistingSession = 0
							foreach ($session in $HostPoolUserSessions) {
								if ($session.SessionHostName -eq $SessionHostName -and $session.SessionState -eq "Active") {
									# changes from https://github.com/Azure/RDS-Templates/pull/439/
									# if ($LimitSecondsToForceLogOffUser -ne 0) {
									# Send notification
									try {
										Send-RdsUserSessionMessage -TenantName $TenantName -HostPoolName $HostpoolName -SessionHostName $SessionHostName -SessionId $session.SessionId -MessageTitle $LogOffMessageTitle -MessageBody "$($LogOffMessageBody) You will be logged off in $($LimitSecondsToForceLogOffUser) seconds." -NoUserPrompt
									}
									catch {
										throw [System.Exception]::new('Failed to send message to user', $PSItem.Exception)
									}
									# changes from https://github.com/Azure/RDS-Templates/pull/439/
									Write-Log "Script sent a log off message to user: $($Session.AdUserName | Out-String)"
									# }
								}
								$ExistingSession = $ExistingSession + 1
							}
							# Wait for n seconds to log off user
							Start-Sleep -Seconds $LimitSecondsToForceLogOffUser

							# changes from https://github.com/Azure/RDS-Templates/pull/439/
							# if ($LimitSecondsToForceLogOffUser -ne 0) {
							# Force users to log off
							Write-Log "Force users to log off ..."
							foreach ($Session in $HostPoolUserSessions) {
								if ($Session.SessionHostName -eq $SessionHostName) {
									# Log off user
									try {
										# note: the following command was called with -force in log analytics workspace version of this code
										Invoke-RdsUserSessionLogoff -TenantName $TenantName -HostPoolName $HostpoolName -SessionHostName $Session.SessionHostName -SessionId $Session.SessionId -NoUserPrompt
										$ExistingSession = $ExistingSession - 1
									}
									catch {
										throw [System.Exception]::new('Failed to log off user', $PSItem.Exception)
									}
									# changes from https://github.com/Azure/RDS-Templates/pull/439/
									Write-Log "Forcibly logged off the user: $($Session.AdUserName | Out-String)"
								}
							}
							# }
							# Check the session count before shutting down the VM
							if ($ExistingSession -eq 0) {
								# Shutdown the Azure VM
								Write-Log "Stopping Azure VM: $VMName and waiting for it to complete ..."
								Stop-SessionHost -VMName $VMName
							}
						}
						# changes from https://github.com/Azure/RDS-Templates/pull/439/
						if ($LimitSecondsToForceLogOffUser -ne 0 -or $SessionHost.Sessions -eq 0) {
							# wait for the VM to stop
							$IsVMStopped = $false
							while (!$IsVMStopped) {
								# //todo prepare the list of all VMs with RG before hand to save time
								$RoleInstance = Get-AzVM -Status -Name $VMName
								if ($RoleInstance.PowerState -eq "VM deallocated") {
									$IsVMStopped = $true
									Write-Log "Azure VM has been stopped: $($RoleInstance.Name) ..."
								}
							}
							# Check if the session host status is NoHeartbeat or Unavailable                          
							$IsSessionHostNoHeartbeat = $false
							while (!$IsSessionHostNoHeartbeat) {
								$SessionHostInfo = Get-RdsSessionHost -TenantName $TenantName -HostPoolName $HostpoolName -Name $SessionHostName
								if ($SessionHostInfo.UpdateState -eq "Succeeded" -and $SessionHostInfo.Status -notin $DesiredRunningStates) {
									$IsSessionHostNoHeartbeat = $true
									# Ensure the Azure VMs that are off have allow new connections mode set to True
									if ($SessionHostInfo.AllowNewSession -eq $false) {
										UpdateSessionHostToAllowNewSessions -TenantName $TenantName -HostPoolName $HostpoolName -SessionHostName $SessionHostName
									}
								}
							}
						}
						# //todo prepare the list of all VM sizes before hand to save time
						$RoleSize = Get-AzVMSize -Location $RoleInstance.Location | Where-Object { $_.Name -eq $RoleInstance.HardwareProfile.VmSize }
						# changes from https://github.com/Azure/RDS-Templates/pull/439/
						if ($LimitSecondsToForceLogOffUser -ne 0 -or $SessionHost.Sessions -eq 0) {
							# decrement number of running session host
							[int]$NumberOfRunningHost = [int]$NumberOfRunningHost - 1
							[int]$TotalRunningCores = [int]$TotalRunningCores - $RoleSize.NumberOfCores
						}
					}
				}
			}
		}
		
		$OffPeakUsageMinimumNoOfRDSH = Get-AzAutomationVariable -Name "$HostpoolName-OffPeakUsage-MinimumNoOfRDSH" -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName -ErrorAction SilentlyContinue
		if ($OffPeakUsageMinimumNoOfRDSH) {
			[int]$MinimumNumberOfRDSH = $OffPeakUsageMinimumNoOfRDSH.Value
			$NoConnectionsofhost = 0
			if ($NumberOfRunningHost -le $MinimumNumberOfRDSH) {
				foreach ($SessionHost in $AllSessionHosts) {
					if ($SessionHost.Status -in $DesiredRunningStates -and $SessionHost.Sessions -eq 0) {
						$NoConnectionsofhost = $NoConnectionsofhost + 1
					}
				}
				$NoConnectionsofhost = $NoConnectionsofhost - $DefinedMinimumNumberOfRDSH
				if ($NoConnectionsofhost -gt $DefinedMinimumNumberOfRDSH) {
					[int]$MinimumNumberOfRDSH = [int]$MinimumNumberOfRDSH - $NoConnectionsofhost
					Set-AzAutomationVariable -Name "$HostpoolName-OffPeakUsage-MinimumNoOfRDSH" -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName -Encrypted $false -Value $MinimumNumberOfRDSH
				}
			}
		}
		$HostpoolMaxSessionLimit = $HostpoolInfo.MaxSessionLimit
		
		$HostpoolSessionCount = $null
		if ($null -eq $OverrideUserSessions) {
			$HostpoolSessionCount = (Get-RdsUserSession -TenantName $TenantName -HostPoolName $HostpoolName).Count
		}
		else {
			$HostpoolSessionCount = $OverrideUserSessions
		}
		if ($HostpoolSessionCount -ne 0) {
			# Calculate how many sessions will be allowed in minimum number of RDSH VMs in off peak hours and calculate TotalAllowSessions Scale Factor
			$TotalAllowSessionsInOffPeak = [int]$MinimumNumberOfRDSH * $HostpoolMaxSessionLimit
			$SessionsScaleFactor = $TotalAllowSessionsInOffPeak * 0.90
			$ScaleFactor = [math]::Floor($SessionsScaleFactor)

			if ($HostpoolSessionCount -ge $ScaleFactor) {
				$ListOfSessionHosts = Get-RdsSessionHost -TenantName $TenantName -HostPoolName $HostpoolName | Where-Object { $_.Status -notin $DesiredRunningStates }
				$AllSessionHosts = $ListOfSessionHosts | Where-Object { $SkipSessionhosts -notcontains $_ }
				foreach ($SessionHost in $AllSessionHosts) {
					# Check the session host status and if the session host is healthy before starting the host
					if ($SessionHost.UpdateState -eq "Succeeded") {
						Write-Log "Existing sessionhost sessions value reached near by hostpool maximumsession limit, need to start the session host"
						$SessionHostName = $SessionHost.SessionHostName | Out-String

						# //todo do this in parallel
						Start-SessionHost -TenantName $TenantName -HostPoolName $HostpoolName -SessionHostName $SessionHost.SessionHostName

						# Increment the number of running session host
						[int]$NumberOfRunningHost = [int]$NumberOfRunningHost + 1
						# Increment the number of minimumnumberofrdsh
						[int]$MinimumNumberOfRDSH = [int]$MinimumNumberOfRDSH + 1
						$OffPeakUsageMinimumNoOfRDSH = Get-AzAutomationVariable -Name "$HostpoolName-OffPeakUsage-MinimumNoOfRDSH" -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName -ErrorAction SilentlyContinue
						if (!$OffPeakUsageMinimumNoOfRDSH) {
							New-AzAutomationVariable -Name "$HostpoolName-OffPeakUsage-MinimumNoOfRDSH" -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName -Encrypted $false -Value $MinimumNumberOfRDSH -Description "Dynamically generated minimumnumber of RDSH value"
						}
						else {
							Set-AzAutomationVariable -Name "$HostpoolName-OffPeakUsage-MinimumNoOfRDSH" -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName -Encrypted $false -Value $MinimumNumberOfRDSH
						}
						# //todo prepare the list of all VM sizes before hand to save time
						# Calculate available capacity of sessions
						$RoleSize = Get-AzVMSize -Location $RoleInstance.Location | Where-Object { $_.Name -eq $RoleInstance.HardwareProfile.VmSize }
						# //todo def $TotalAllowSessions
						$AvailableSessionCapacity = $TotalAllowSessions + $HostpoolInfo.MaxSessionLimit
						[int]$TotalRunningCores = [int]$TotalRunningCores + $RoleSize.NumberOfCores
						Write-Log "New available session capacity is: $AvailableSessionCapacity"
						break
					}
				}
			}

		}
	}

	# //todo refactor logging
	Write-Log "HostPool: $HostpoolName, Total running cores: $TotalRunningCores, Number of running session hosts: $NumberOfRunningHost"
	Write-Log "End WVD HostPool scale optimization."
}
catch {
	$ErrContainer = $PSItem
	# $ErrContainer = $_

	$ErrMsg = $ErrContainer | Format-List -force | Out-String
	if (Get-Command 'Write-Log' -ErrorAction:SilentlyContinue) {
		Write-Log -Err $ErrMsg -ErrorAction:Continue
	}
	else {
		Write-Error $ErrMsg -ErrorAction:Continue
	}

	throw
	# throw [System.Exception]::new($ErrMsg, $ErrContainer.Exception)
}