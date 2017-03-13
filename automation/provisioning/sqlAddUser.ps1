# Common expression logging and error handling function, copied, not referenced to ensure atomic process
function executeExpression ($expression) {
	$error.clear()
	Write-Host "[$scriptName] $expression"
	try {
		Invoke-Expression $expression
	    if(!$?) { Write-Host "[$scriptName] `$? = $?"; exit 1 }
	} catch { echo $_.Exception|format-list -force; exit 2 }
    if ( $error[0] ) { Write-Host "[$scriptName] `$error[0] = $error"; exit 3 }
}

$scriptName = 'sqlAddUser.ps1'
Write-Host
Write-Host "[$scriptName] ---------- start ----------"
$dbUser = $args[0]
if ($dbUser) {
    Write-Host "[$scriptName] dbUser      : $dbUser"
} else {
    Write-Host "[$scriptName] dbUser not supplied, exiting with code 101"; exit 101
}

$dbhost = $args[1]
if ($dbhost) {
    Write-Host "[$scriptName] dbhost      : $dbhost"
} else {
	$dbhost = '.'
    Write-Host "[$scriptName] dbhost      : $dbhost (default)"
}

$loginType = $args[3]
if ($loginType) {
    Write-Host "[$scriptName] loginType   : $loginType"
} else {
	$loginType = 'WindowsUser'
    Write-Host "[$scriptName] loginType   : $loginType (not supplied, set to default)"
}

$sqlPassword = $args[4]
if ($sqlPassword) {
    Write-Host "[$scriptName] sqlPassword : *********************** (only applicable if loginType is SQLLogin)"
} else {
	if ( $loginType -eq 'SQLLogin' ) {
    	Write-Host "[$scriptName] sqlPassword : not supplied, required when loginType is SQLLogin, exiting with code 102."; exit 102
	} else {
	    Write-Host "[$scriptName] sqlPassword : not supplied (only applicable if loginType is SQLLogin)"
    }
}

# Load the assemblies
executeExpression '[reflection.assembly]::LoadWithPartialName("Microsoft.SqlServer.Smo")'
executeExpression '[reflection.assembly]::LoadWithPartialName("Microsoft.SqlServer.SqlWmiManagement")'

# Rely on caller passing host or host\instance as they desire
$srv = new-Object Microsoft.SqlServer.Management.Smo.Server("$dbhost")

try {

	$SqlUser = New-Object -TypeName Microsoft.SqlServer.Management.Smo.Login -ArgumentList $srv,"$dbUser"
	$SqlUser.LoginType = $loginType
	$sqlUser.PasswordPolicyEnforced = $false
	$SqlUser.Create($sqlPassword)
	Write-Host; Write-Host "[$scriptName] User $domain\$dbUser added to $dbhost\$dbinstance"; Write-Host 
	
} catch {

	Write-Host; Write-Host "[$scriptName] User Add failed with exception, message follows ..."; Write-Host 
	Write-Host "[$scriptName] $_"; Write-Host 
	exit 2
}

Write-Host
executeExpression '$srv.Logins | select name'

Write-Host
Write-Host "[$scriptName] ---------- stop ----------"
