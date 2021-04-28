# Usage: scoop home [<OPTIONS>] <APP>
# Summary: Opens the application's homepage in default browser.
#
# Options:
#   -h, --help      Show help for this command.

param($app)

# TODO: getopt adoption

'core', 'help', 'manifest', 'buckets' | ForEach-Object {
    . (Join-Path $PSScriptRoot "..\lib\$_.ps1")
}

Reset-Alias

$exitCode = 0

if ($app) {
    # TODO: Resolve-ManifestInformation
    $manifest, $bucket = find_manifest $app
    if ($manifest) {
        if ([String]::IsNullOrEmpty($manifest.homepage)) {
            $exitCode = 3
            Write-UserMessage -Message "Could not find homepage in manifest for '$app'." -Err
        } else {
            Start-Process $manifest.homepage
        }
    } else {
        $exitCode = 3
        Write-UserMessage -Message "Could not find manifest for '$app'." -Err
    }
} else {
    Stop-ScoopExecution -Message 'Parameter <APP> missing' -Usage (my_usage)
}

exit $exitCode
