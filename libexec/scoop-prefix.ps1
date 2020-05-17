# Usage: scoop prefix <app>
# Summary: Returns the path to the specified app

param($app)

'core', 'help', 'manifest', 'buckets' | ForEach-Object {
    . "$PSScriptRoot\..\lib\$_.ps1"
}

reset_aliases
$exitCode = 0

if (!$app) { my_usage; exit 1 }

$app_path = versiondir $app 'current' $false
if (!(Test-Path $app_path)) { $app_path = versiondir $app 'current' $true }

if (Test-Path $app_path) {
    Write-Output $app_path
} else {
    $exitCode = 3
    Write-UserMessage -Message "Could not find app path for '$app'." -Err
}

exit $exitCode
