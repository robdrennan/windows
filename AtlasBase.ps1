Param (
��[string]$emailTo,
��[string]$smtpServer
)
$scriptName = 'AtlasBase.ps1'

# Common expression logging and error handling function, copied, not referenced to ensure atomic process
function emailAndExit ($exitCode) {
	if ($smtpServer) {
		executeExpression "Send-MailMessage -To `"$emailTo`" -From `'no-reply@cdaf.info`' -Subject `"$scriptName ERROR $exitCode`" -SmtpServer `"$smtpServer`""
	}
	exit $exitCode
}

function executeExpression ($expression) {
	$error.clear()
	Write-Host "[$scriptName] $expression"
	Add-Content "$imageLog" "[$scriptName] $expression"
	try {
		$output = Invoke-Expression $expression
	    if(!$?) { Write-Host "[$scriptName] `$? = $?"; Add-Content "$imageLog" "[$scriptName] `$? = $?"; emailAndExit 1 }
	} catch { echo $_.Exception|format-list -force; Add-Content "$imageLog" "$_.Exception|format-list"; emailAndExit 2 }
    if ( $error[0] ) { Write-Host "[$scriptName] `$error[0] = $error"; Add-Content "$imageLog" "[$scriptName] `$error[0] = $error"; emailAndExit 3 }
    return $output
}

Write-Host "`n[$scriptName] ---------- start ----------"

if ($emailTo) {
    Write-Host "[$scriptName] emailTo    : $emailTo"
} else {
    Write-Host "[$scriptName] emailTo    : (not specified, email will not be attempted)"
}

if ($smtpServer) {
    Write-Host "[$scriptName] smtpServer : $smtpServer"
} else {
    Write-Host "[$scriptName] smtpServer : (not specified, email will not be attempted)"
}

$imageLog = 'baseLog.txt'
if (Test-Path "$imageLog") {
    Write-Host "`n[$scriptName] Logfile exists ($imageLog), delete for new run."
	executeExpression "Remove-Item `"$imageLog`""
}
if ($smtpServer) {
	executeExpression "Send-MailMessage -To `"$emailTo`" -From `'no-reply@cdaf.info`' -Subject `"$scriptName starting, logging to $imageLog`" -SmtpServer `"$smtpServer`""
}

Write-Host "`n[$scriptName] Disable password policy"
executeExpression "secedit /export /cfg c:\secpol.cfg"
executeExpression "(gc C:\secpol.cfg).replace(`"PasswordComplexity = 1`", `"PasswordComplexity = 0`") | Out-File C:\secpol.cfg"
executeExpression "secedit /configure /db c:\windows\security\local.sdb /cfg c:\secpol.cfg /areas SECURITYPOLICY"
executeExpression "rm -force c:\secpol.cfg -confirm:`$false"

Write-Host "`n[$scriptName] Set default Administrator password to `'vagrant`'"
$admin = executeExpression "[adsi]`'WinNT://./Administrator,user`'"
executeExpression "`$admin.SetPassword(`'vagrant`')"
executeExpression "`$admin.UserFlags.value = `$admin.UserFlags.value -bor 0x10000" # Password never expires
executeExpression "`$admin.CommitChanges()" 

Write-Host "`n[$scriptName] Apply Windows Updates"
executeExpression "./automation/provisioning/applyWindowsUpdates.ps1 no"
if ($smtpServer) {
	Send-MailMessage -To "jules@xtra.co.nz" -From 'no-reply@cdaf.info' -Subject "Windows Updates applied, rebooting"
}
executeExpression "shutdown /r /t 60"

Write-Host "`n[$scriptName] ---------- stop ----------"
exit 0