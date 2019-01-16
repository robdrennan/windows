Param (
	[string]$install,
	[string]$mediaDir,
	[string]$proxy,
	[string]$version,
	[string]$checksum,
	[string]$otherArgs	
)

cmd /c "exit 0"
$scriptName = 'base.ps1'

# Common expression logging and error handling function, copied, not referenced to ensure atomic process
function executeExpression ($expression) {
	$error.clear()
	Write-Host "$expression"
	try {
		Invoke-Expression $expression
	    if(!$?) { Write-Host "[$scriptName] `$? = $?"; exit 1 }
	} catch { echo $_.Exception|format-list -force; exit 2 }
    if ( $error[0] ) { Write-Host "[$scriptName] `$error[0] = $error"; exit 3 }
    if (( $LASTEXITCODE ) -and ( $LASTEXITCODE -ne 0 )) {
		Write-Host "[$scriptName] `$LASTEXITCODE = ${LASTEXITCODE}, listing log file contents ..."
		cat C:\ProgramData\chocolatey\logs\chocolatey.log | findstr 'ERROR'
		exit 4 # do not use $LASTEXITCODE as it is a negative value 
	}
}

Write-Host "[$scriptName] Install components using Chocolatey.`n"
Write-Host "[$scriptName] ---------- start ----------"
if ($install) {
    Write-Host "[$scriptName] install    : $install (can be space separated list)"
} else {
    Write-Host "[$scriptName] Package to install not supplied, exiting with LASTEXITCODE 4"; exit 4 
}

if ($mediaDir) {
    Write-Host "[$scriptName] mediaDir   : $mediaDir"
} else {
	$mediaDir = '/.provision'
    Write-Host "[$scriptName] mediaDir   : $mediaDir (default)"
}

if ($proxy) {
    Write-Host "[$scriptName] proxy      : $proxy`n"
} else {
	if ( $env:http_proxy ) {
		$proxy = $env:http_proxy
	    Write-Host "[$scriptName] proxy      : (not supplied, but defaulted from `$env:http_proxy)"
    } else {
	    Write-Host "[$scriptName] proxy      : (not supplied)"
    }
}

if ($version) {
    Write-Host "[$scriptName] version    : $version`n"
    $version = "--version $version"
} else {
    Write-Host "[$scriptName] version    : (not supplied)"
}

if ($checksum) {
    Write-Host "[$scriptName] checksum   : $checksum`n"
	if ( $checksum -eq 'ignore' ) {
		$checksum = "--ignorechecksum -y"
	} else {
	    $checksum = "--checksum $checksum"
    }
} else {
    Write-Host "[$scriptName] checksum   : (not supplied)"
}

if ($otherArgs) {
    Write-Host "[$scriptName] otherArgs  : $otherArgs`n"
} else {
    Write-Host "[$scriptName] otherArgs  : (not supplied)"
}

if ($proxy) {
    Write-Host "`n[$scriptName] Load common proxy settings`n"
    executeExpression "[system.net.webrequest]::defaultwebproxy = new-object system.net.webproxy('$proxy')"
    executeExpression "`$env:chocolateyProxyLocation = '$proxy'"
    executeExpression "`$env:http_proxy = '$proxy'"
}

$versionTest = cmd /c choco --version 2`>`&1
if ($versionTest -like '*not recognized*') {
	Write-Host "`n[$scriptName] Chocolatey not installed, installing ..."
	cmd /c "exit 0"
	if (!( Test-Path $mediaDir )) {
		Write-Host "[$scriptName] mkdir $mediaDir"
		Write-Host "[$scriptName]   $(mkdir $mediaDir) created"
	}
	
	Write-Host
	$file = 'install.ps1'
	$fullpath = $mediaDir + '\' + $file
	if ( Test-Path $fullpath ) {
		Write-Host "[$scriptName] $fullpath exists, download not required"
	} else {
	
		$uri = 'https://chocolatey.org/' + $file
		Write-Host "[$scriptName] $file does not exist in $mediaDir, listing contents"
		try {
			Get-ChildItem $mediaDir | Format-Table name
		    if(!$?) { $fullpath = listAndContinue }
		} catch { $fullpath = listAndContinue }

		Write-Host "[$scriptName] Attempt download"
		executeExpression "(New-Object System.Net.WebClient).DownloadFile('$uri', '$fullpath')"
	}
	
	try {
		$argList = @("$fullpath")
		Write-Host "[$scriptName] Start-Process -FilePath 'powershell' -ArgumentList $argList -PassThru -Wait -NoNewWindow"
		$proc = Start-Process -FilePath 'powershell' -ArgumentList $argList -PassThru -Wait -NoNewWindow
	} catch {
		Write-Host "[$scriptName] $file Install Exception : $_" -ForegroundColor Red
		exit 200
	}
	
	# Reload the path (without logging off and back on)
	$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

	$versionTest = cmd /c choco --version 2`>`&1
	if ($versionTest -like '*not recognized*') {
		Write-Host "[$scriptName] Chocolatey install has failed, exiting!"
		exit # that should retain the exit code from the version test itself
	}

}
Write-Host "[$scriptName] Chocolatey : $versionTest`n"

# if processed as a list and any item other than the last fails, choco will return a false possitive
Write-Host "[$scriptName] Process each package separately to trap failures`n"
$install.Split(" ") | ForEach {
	executeExpression "choco install -y $_ --no-progress --fail-on-standard-error $checksum $version $otherArgs"

	Write-Host "`n[$scriptName] Reload the path`n"
	executeExpression '$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")'
}

Write-Host "`n[$scriptName] ---------- stop ----------"
exit 0
