Param (
	[string]$BUILDNUMBER,
	[string]$REVISION,
	[string]$ACTION,
	[string]$SOLUTION,
	[string]$AUTOMATIONROOT,
	[string]$LOCAL_WORK_DIR,
	[string]$REMOTE_WORK_DIR
)

Import-Module Microsoft.PowerShell.Utility
Import-Module Microsoft.PowerShell.Management
Import-Module Microsoft.PowerShell.Security

# Initialise
cmd /c "exit 0"
$scriptName = $MyInvocation.MyCommand.Name

# Common expression logging and error handling function, copied, not referenced to ensure atomic process
function executeExpression ($expression) {
	$error.clear()
	Write-Host "[$(date)] $expression"
	try {
		Invoke-Expression $expression
	    if(!$?) { Write-Host "[$scriptName] `$? = $?"; exit 1 }
	} catch { Write-Output $_.Exception|format-list -force; exit 2 }
    if ( $error ) { Write-Host "[$scriptName] `$error[0] = $error"; exit 3 }
    if (( $LASTEXITCODE ) -and ( $LASTEXITCODE -ne 0 )) { Write-Host "[$scriptName] `$LASTEXITCODE = $LASTEXITCODE "; exit $LASTEXITCODE }
}

# Common expression logging and error handling function, copied, not referenced to ensure atomic process
function executeReturn ($expression) {
	$error.clear()
	Write-Host "[$scriptName] $expression"
	try {
		$output = Invoke-Expression $expression
	    if(!$?) { Write-Host "[$scriptName] `$? = $?"; exit 1 }
	} catch { Write-Output $_.Exception|format-list -force; exit 2 }
    if ( $error ) { Write-Host "[$scriptName] `$error[0] = $error"; exit 3 }
    if (( $LASTEXITCODE ) -and ( $LASTEXITCODE -ne 0 )) { Write-Host "[$scriptName] `$LASTEXITCODE = $LASTEXITCODE "; exit $LASTEXITCODE }
    return $output
}

# Entry Point for Build Process, child scripts inherit the functions of parent scripts, so these definitions are global for the CI process
# Primary powershell, returns exitcode to DOS
function exitWithCode ($message, $exitCode) {
    write-host "[$scriptName] $message" -ForegroundColor Red
    write-host "[$scriptName]   Returning errorlevel $exitCode to DOS" -ForegroundColor Magenta
    $host.SetShouldExit($exitCode)
    exit $exitCode
}

function passExitCode ($message, $exitCode) {
    write-host "[$scriptName] $message" -ForegroundColor Red
    write-host "[$scriptName]   Exiting with `$LASTEXITCODE $exitCode" -ForegroundColor Magenta
    exit $exitCode
}

function exceptionExit ($exception) {
    write-host "[$scriptName]   Exception details follow ..." -ForegroundColor Red
    Write-Output $exception.Exception|format-list -force
    write-host "[$scriptName] Returning errorlevel (20) to DOS" -ForegroundColor Magenta
    $host.SetShouldExit(20)
    exit
}

# Not used in this script because called from DOS, but defined here for all child scripts
function taskFailure ($taskName) {
    write-host
    write-host "[$scriptName] Failure occured! Code returned ... $taskName" -ForegroundColor Red
    $host.SetShouldExit(30)
    exit 30
}

function taskWarning { 
    write-host "[$scriptName] Warning, $taskName encountered an error that was allowed to proceed." -ForegroundColor Yellow
}

function itemRemove ($itemPath) { 
	if ( Test-Path $itemPath ) {
		write-host "[$scriptName] Delete $itemPath"
		Remove-Item $itemPath -Recurse 
		if(!$?){ taskFailure "Remove-Item $itemPath" }
	}
}

function pathTest ($pathToTest) { 
	if ( Test-Path $pathToTest ) {
		Write-Host "found ($pathToTest)"
	} else {
		Write-Host "none ($pathToTest)"
	}
}

function getProp ($propName, $propertiesFile) {
	try {
		$propValue=$(& $AUTOMATIONROOT\remote\getProperty.ps1 $propertiesFile $propName)
		if(!$?){ taskWarning }
	} catch { exceptionExit $_ }
	
    return $propValue
}

function dockerStart {
	Write-Host "[$scriptName] Docker installed but not running, `$env:CDAF_DOCKER_REQUIRED is set so will try and start"
	executeExpression 'Start-Service Docker'
	Write-Host '$dockerStatus = ' -NoNewline 
	$dockerStatus = executeReturn '(Get-Service Docker).Status'
	$dockerStatus
	if ( $dockerStatus -ne 'Running' ) {
		Write-Host "[$scriptName] Unable to start Docker, `$dockerStatus = $dockerStatus"
		exit 8910
	}
}
# Load automation root out of sequence as needed for solution root derivation
if (!($AUTOMATIONROOT)) {
	$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition
	$AUTOMATIONROOT = split-path -parent $scriptPath
}

# Check for user defined solution folder, i.e. outside of automation root, if found override solution root
Write-Host "[$scriptName]   solutionRoot    : " -NoNewline
foreach ($item in (Get-ChildItem -Path ".")) {
	if (Test-Path $item -PathType "Container") {
		if (Test-Path "$item\CDAF.solution") {
			$solutionRoot=$item
		}
	}
}
if ($solutionRoot) {
	write-host "$solutionRoot (override $solutionRoot\CDAF.solution found)"
} else {
	$solutionRoot="$AUTOMATIONROOT\solution"
	write-host "$solutionRoot (default, project directory containing CDAF.solution not found)"
}

if ( $BUILDNUMBER ) {
	Write-Host "[$scriptName]   BUILDNUMBER     : $BUILDNUMBER"
} else { 
	$counterFile = "$env:USERPROFILE\buildnumber.counter"
	# Use a simple text file ($counterFile) for incrimental build number, using the same logic as cdEmulate.ps1
	if ( Test-Path "$counterFile" ) {
		$buildNumber = Get-Content "$counterFile"
	} else {
		$buildNumber = 0
	}
	[int]$buildnumber = [convert]::ToInt32($buildNumber)
	if ( $action -ne "cdonly" ) { # Do not incriment when just deploying
		$buildNumber += 1
	}
	Set-Content "$counterFile" "$BUILDNUMBER"
    Write-Host "[$scriptName]   BUILDNUMBER     : $BUILDNUMBER (not supplied, generated from local counter file)"
}

if ( $REVISION ) {
	Write-Host "[$scriptName]   REVISION        : $REVISION"
} else {
	$REVISION = 'Revision'
	Write-Host "[$scriptName]   REVISION        : $REVISION (default)"
}

Write-Host "[$scriptName]   ACTION          : $ACTION"

if ($SOLUTION) {
	Write-Host "[$scriptName]   SOLUTION        : $SOLUTION"
} else {
	$SOLUTION = getProp 'solutionName' "$solutionRoot\CDAF.solution"
	if ($SOLUTION) {
		Write-Host "[$scriptName]   SOLUTION        : $SOLUTION (from `$solutionRoot\CDAF.solution)"
	} else {
		exitWithCode "SOLUTION_NOT_FOUND Solution not supplied and unable to derive from $solutionRoot\CDAF.solution" 22
	}
}

# Arguments out of order, as automation root processed first
if ( $LOCAL_WORK_DIR ) {
	Write-Host "[$scriptName]   LOCAL_WORK_DIR  : $LOCAL_WORK_DIR"
} else {
	$LOCAL_WORK_DIR = 'TasksLocal'
	Write-Host "[$scriptName]   LOCAL_WORK_DIR  : $LOCAL_WORK_DIR (default)"
}

if ( $REMOTE_WORK_DIR ) {
	Write-Host "[$scriptName]   REMOTE_WORK_DIR : $REMOTE_WORK_DIR"
} else {
	$REMOTE_WORK_DIR = 'TasksRemote'
	Write-Host "[$scriptName]   REMOTE_WORK_DIR : $REMOTE_WORK_DIR (default)"
}

# Load automation root as environment variable
$env:CDAF_AUTOMATION_ROOT = $AUTOMATIONROOT
Write-Host "[$scriptName]   AUTOMATIONROOT  : $AUTOMATIONROOT" 

# Runtime information
Write-Host "[$scriptName]   pwd             : $(pwd)"
Write-Host "[$scriptName]   hostname        : $(hostname)" 
Write-Host "[$scriptName]   whoami          : $(whoami)"

$cdafVersion = getProp 'productVersion' "$AUTOMATIONROOT\CDAF.windows"
Write-Host "[$scriptName]   CDAF Version    : $cdafVersion"

$containerImage = getProp 'containerImage' "$solutionRoot\CDAF.solution"
if ( $containerImage ) {
	if (($env:CONTAINER_IMAGE) -or ($CONTAINER_IMAGE)) {
		Write-Host "[$scriptName]   containerImage  : $containerImage"
		if ($env:CONTAINER_IMAGE) {
			Write-Host "[$scriptName]   CONTAINER_IMAGE : $env:CONTAINER_IMAGE (not changed as already set)"
		} else {
			$env:CONTAINER_IMAGE = $CONTAINER_IMAGE
			Write-Host "[$scriptName]   CONTAINER_IMAGE : $env:CONTAINER_IMAGE (loaded from `$CONTAINER_IMAGE)"
		}
	} else {
		$env:CONTAINER_IMAGE = $containerImage
		Write-Host "[$scriptName]   CONTAINER_IMAGE : $env:CONTAINER_IMAGE (set to `$containerImage)"
	}
}

# Properties generator (added in release 1.7.8, extended to list in 1.8.11, moved from build to pre-process 1.8.14)
$itemList = @("propertiesForLocalTasks", "propertiesForRemoteTasks")
foreach ($itemName in $itemList) {  
	itemRemove ".\${itemName}"
}

$configManagementList = Get-ChildItem -Path "$solutionRoot" -Name '*.cm'
if ( $configManagementList ) {
	foreach ($item in $configManagementList) {
		Write-Host "[$scriptName]   CM Driver       : $item"
	}
} else {
		Write-Host "[$scriptName]   CM Driver       : none ($SOLUTIONROOT\*.cm)"
}

$pivotList = Get-ChildItem -Path "$solutionRoot" -Name '*.pv'
if ( $pivotList ) {
	foreach ($item in $pivotList) {
		Write-Host "[$scriptName]   PV Driver       : $item"
	}
} else {
		Write-Host "[$scriptName]   PV Driver       : none ($SOLUTIONROOT\*.pv)"
}

# Process table with properties as fields and environments as rows
foreach ($propertiesDriver in $configManagementList) {
	Write-Host "`n[$scriptName] Generating properties files from ${propertiesDriver}"
	$columns = ( -split (Get-Content $SOLUTIONROOT\$propertiesDriver -First 1 ))
	foreach ( $line in (Get-Content $SOLUTIONROOT\$propertiesDriver )) {
		$arr = (-split $line)
		if ( $arr[0] -ne 'context' ) {
			if ( $arr[0] -eq 'remote' ) {
				$cdafPath="./propertiesForRemoteTasks"
			} else {
				$cdafPath="./propertiesForLocalTasks"
			}
			if ( ! (Test-Path $cdafPath) ) {
				Write-Host "[$scriptName]   mkdir $(mkdir $cdafPath)"
			}
			Write-Host "[$scriptName]   Generating ${cdafPath}/$($arr[1])"
			foreach ($field in $columns) {
				if ( $columns.IndexOf($field) -gt 1 ) { # do not create entries for context and target
					if ( $($arr[$columns.IndexOf($field)]) ) { # Only write properties that are populated
						Add-Content "${cdafPath}/$($arr[1])" "${field}=$($arr[$columns.IndexOf($field)])"
					}
				}
			}
			if ( ! ( Test-Path ${cdafPath}/$($arr[1]) )) {
				Write-Host "[$scriptName]   [WARN] Property file ${cdafPath}/$($arr[1]) not created as containers definition contains no properties."
			}
		}
	}
}

# Process table with properties as rows and environments as fields
foreach ($propertiesDriver in $pivotList) {
	Write-Host "`n[$scriptName] Generating properties files from ${propertiesDriver}"
	$rows = Get-Content $SOLUTIONROOT\$propertiesDriver
	$columns = -split $rows[0]
	$paths = -split $rows[1]
    for ($i=2; $i -le $rows.Count; $i++) {
		$arr = (-split $rows[$i])
		for ($j=1; $j -le $arr.Count; $j++) {
			if (( $columns[$j] ) -and ( $arr[$j] )) {
				if ( $paths[$j] -eq 'remote' ) {
					$cdafPath="./propertiesForRemoteTasks"
				} else {
					$cdafPath="./propertiesForLocalTasks"
				}
				if ( ! (Test-Path $cdafPath) ) {
					Write-Host "[$scriptName]   mkdir $(mkdir $cdafPath)"
				}
				if ( ! ( Test-Path "${cdafPath}/$($columns[$j])" )) {
					Write-Host "[$scriptName]   Generating ${cdafPath}/$($columns[$j])"
				}
				Add-Content "${cdafPath}/$($columns[$j])" "$($arr[0])=$($arr[$j])"
			}
		}
	}
}

# CDAF 1.6.7 Container Build process
if ( $ACTION -eq 'containerbuild' ) {
	Write-Host "`n[$scriptName] `$ACTION = $ACTION, skip detection.`n"
} else {
	$containerBuild = getProp 'containerBuild' "$solutionRoot\CDAF.solution"
	if ( $containerBuild ) {
		$versionTest = cmd /c docker --version 2`>`&1; cmd /c "exit 0"
		if ($versionTest -like '*not recognized*') {
			Write-Host "[$scriptName]   containerBuild  : containerBuild defined in $solutionRoot\CDAF.solution, but Docker not installed, will attempt to execute natively"
			Clear-Variable -Name 'containerBuild'
		} else {
			Write-Host "[$scriptName]   containerBuild  : $containerBuild"
			$array = $versionTest.split(" ")
			$dockerRun = $($array[2])
			Write-Host "[$scriptName]   Docker          : $dockerRun"
			# Test Docker is running
			If (Get-Service Docker -ErrorAction SilentlyContinue) {
			    $dockerStatus = executeReturn '(Get-Service Docker).Status'
			    $dockerStatus
			    if ( $dockerStatus -ne 'Running' ) {
			        if ( $dockerdProcess = Get-Process dockerd -ea SilentlyContinue ) {
			            Write-Host "[$scriptName] Process dockerd is running..."
			        } else {
			            Write-Host "[$scriptName] Process dockerd is not running..."
			        }
			    }
			    if (( $dockerStatus -ne 'Running' ) -and ( $dockerdProcess -eq $null )){
			    	if ( $env:CDAF_DOCKER_REQUIRED ) {
						dockerStart
					} else {			    
						Write-Host "[$scriptName] Docker installed but not running, will attempt to execute natively (set `$env:CDAF_DOCKER_REQUIRED if docker is mandatory)"
						cmd /c "exit 0"
						Clear-Variable -Name 'containerBuild'
					}
				}
			}
			
			Write-Host "[$scriptName] List all current images"
			Write-Host "docker images 2> `$null"
			docker images 2> $null
			if ( $LASTEXITCODE -ne 0 ) {
				Write-Host "[$scriptName] Docker not responding, will attempt to execute natively (set `$env:CDAF_DOCKER_REQUIRED if docker is mandatory)"
				if ( $env:CDAF_DOCKER_REQUIRED ) {
					dockerStart
				} else {			    
					Write-Host "[$scriptName] Docker installed but not running, will attempt to execute natively (set `$env:CDAF_DOCKER_REQUIRED if docker is mandatory)"
					cmd /c "exit 0"
					Clear-Variable -Name 'containerBuild'
				}
			}
		}
	} else {
		Write-Host "[$scriptName]   containerBuild  : (not defined in $solutionRoot\CDAF.solution)"
	}
}

if (( $containerBuild ) -and ( $ACTION -ne 'packageonly' )) {

	Write-Host "`n[$scriptName] Execute Container build, this performs cionly, buildonly is ignored.`n" -ForegroundColor Green
	executeExpression $containerBuild

	$imageBuild = getProp 'imageBuild' "$solutionRoot\CDAF.solution"
	if ( $imageBuild ) {
		Write-Host "`n[$scriptName] Execute Image build, as defined for imageBuild in $solutionRoot\CDAF.solution`n"
		executeExpression $imageBuild
	} else {
		Write-Host "[$scriptName]   imageBuild      : (not defined in $solutionRoot\CDAF.solution)"
	}

} else { # Native build
	
	if ( $ACTION -eq 'packageonly' ) {
		if ( $containerBuild ) {
			Write-Host "`n[$scriptName] ACTION is $ACTION so do not use container build process" -ForegroundColor Yellow
		} else {
			Write-Host "`n[$scriptName] ACTION is $ACTION so skipping build process" -ForegroundColor Yellow
		}
	} else {
		& $AUTOMATIONROOT\buildandpackage\buildProjects.ps1 $SOLUTION $BUILDNUMBER $REVISION $AUTOMATIONROOT $solutionRoot $ACTION
		if($LASTEXITCODE -ne 0){
			exitWithCode "BUILD_NON_ZERO_EXIT $AUTOMATIONROOT\buildandpackage\buildProjects.ps1 $SOLUTION $BUILDNUMBER $REVISION $AUTOMATIONROOT $solutionRoot $ACTION" $LASTEXITCODE
		}
		if(!$?){ taskWarning "buildProjects.ps1" }
	}
	
	if ( $ACTION -eq 'buildonly' ) {
		Write-Host "`n[$scriptName] Action is $ACTION so skipping package process" -ForegroundColor Yellow
	} else {
		& $AUTOMATIONROOT\buildandpackage\package.ps1 $SOLUTION $BUILDNUMBER $REVISION $AUTOMATIONROOT $solutionRoot $LOCAL_WORK_DIR $REMOTE_WORK_DIR $ACTION
		if($LASTEXITCODE -ne 0){
			exitWithCode "PACKAGE_NON_ZERO_EXIT $AUTOMATIONROOT\buildandpackage\package.ps1 $SOLUTION $BUILDNUMBER $REVISION $AUTOMATIONROOT $solutionRoot $LOCAL_WORK_DIR $REMOTE_WORK_DIR $ACTION" $LASTEXITCODE
		}
		if(!$?){ taskWarning "package.ps1" }
	}
}

if ( $ACTION -like 'staging@*' ) { # Primarily for VSTS / Azure pipelines
	$parts = $ACTION.split('@')
	$stageTarget = $parts[1]
	executeExpression "Copy-Item -Recurse '.\TasksLocal\' '$stageTarget'"
	executeExpression "Copy-Item '*.zip' '$stageTarget'"
}
