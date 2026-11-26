# Register the logon task that makes the gate survive a reboot on a Windows
# host - the design docs, WSL2 variant. Run in your own PowerShell; no elevation
# needed. Run again to update; -Remove to take it out.
#
#   ci-runner keepalive   hidden    holds the WSL VM open (WSL stops it when
#                                   no Windows process is attached, whatever
#                                   runs inside - docker and the gate included)
#
# The PIN window is pin-vault's, not this tool's: tools/pin-vault/windows/
# install-logon-task.ps1 registers it.
#
# It runs as the logged-on user with an interactive token, which is what WSL
# interop wants. Nothing here runs elevated and nothing runs when nobody is
# logged on: after a reboot CI is back once you sign in and type the PIN, and
# not before - the cost the docs names, kept on purpose.
[CmdletBinding()]
param(
  [string]$Distro = 'Ubuntu-24.04',
  [switch]$Remove
)
$ErrorActionPreference = 'Stop'
$keep = 'ci-runner keepalive'

if ($Remove) {
  if (Get-ScheduledTask -TaskName $keep -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $keep -Confirm:$false
    Write-Host "removed: $keep"
  }
  exit 0
}

$user = "$env:USERDOMAIN\$env:USERNAME"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$common = @{ AllowStartIfOnBatteries = $true; DontStopIfGoingOnBatteries = $true; ExecutionTimeLimit = [TimeSpan]::Zero }

# conhost --headless: a console app under a "hidden" task still flashes a
# window; this is the one way to launch one with none at all.
$keepAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" `
  -Argument "--headless wsl.exe -d $Distro --exec /bin/sleep infinity"
$keepSettings = New-ScheduledTaskSettingsSet @common -Hidden -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $keep -Action $keepAction -Trigger $trigger -Settings $keepSettings -RunLevel Limited -Force | Out-Null
Write-Host "registered: $keep  (hidden, at logon of $user)"
