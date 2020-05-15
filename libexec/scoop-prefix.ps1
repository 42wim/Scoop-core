# Usage: scoop prefix <app>
# Summary: Returns the path to the specified app
param($app)

. "$PSScriptRoot\..\lib\core.ps1"
. "$PSScriptRoot\..\lib\help.ps1"
. "$PSScriptRoot\..\lib\manifest.ps1"
. "$PSScriptRoot\..\lib\buckets.ps1"

reset_aliases

if (!$app) { my_usage; exit 1 }

$app_path = versiondir $app 'current' $false
if (!(Test-Path $app_path)) {
    $app_path = versiondir $app 'current' $true
}

if (Test-Path $app_path) {
    Write-Output $app_path
} else {
    abort "Could not find app path for '$app'."
}

exit 0
