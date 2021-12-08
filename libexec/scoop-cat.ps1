# Usage: scoop cat [<OPTIONS>] <APP>...
# Summary: Show content of specified manifest(s).
# Help: Supports the same format of <APP> parameter as in "scoop install" (See: 'scoop install --help')
#
# Options:
#   -h, --help                  Show help for this command.
#   -f, --format <json|yaml>    Show manifest in specific format. Json will be considered as default when this parameter is not provided.

@(
    @('core', 'Test-ScoopDebugEnabled'),
    @('getopt', 'Resolve-GetOpt'),
    @('help', 'scoop_help'),
    @('Helpers', 'New-IssuePrompt'),
    @('install', 'install_app'),
    @('manifest', 'Resolve-ManifestInformation')
) | ForEach-Object {
    if (!([bool] (Get-Command $_[1] -ErrorAction 'Ignore'))) {
        Write-Verbose "Import of lib '$($_[0])' initiated from '$PSCommandPath'"
        . (Join-Path $PSScriptRoot "..\lib\$($_[0]).ps1")
    }
}

$ExitCode = 0
$Problems = 0
$Options, $Applications, $_err = Resolve-GetOpt $args 'f:' 'format='

if ($_err) { Stop-ScoopExecution -Message "scoop cat: $_err" -ExitCode 2 }
if (!$Applications) { Stop-ScoopExecution -Message 'Parameter <APP> missing' -Usage (my_usage) }

$Format = $Options.f, $Options.format, 'json' | Where-Object { ! [String]::IsNullOrEmpty($_) } | Select-Object -First 1
if ($Format -notin $ALLOWED_MANIFEST_EXTENSION) { Stop-ScoopExecution -Message "Format '$Format' is not supported" -ExitCode 2 }

foreach ($app in $Applications) {
    $resolved = $null
    try {
        $resolved = Resolve-ManifestInformation -ApplicationQuery $app
    } catch {
        ++$Problems
        debug $_.InvocationInfo
        New-IssuePromptFromException -ExceptionMessage $_.Exception.Message

        continue
    }

    debug $resolved

    $output = $resolved.ManifestObject | ConvertTo-Manifest -Extension $Format

    if ($output) {
        Write-UserMessage -Message "Showing manifest for '$app'" -Success # TODO: Add better text with parsed appname, version, url/bucket
        Write-UserMessage -Message $output -Output
    }
}

if ($Problems -gt 0) { $ExitCode = 10 + $Problems }

exit $ExitCode
