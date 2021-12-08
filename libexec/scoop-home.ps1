# Usage: scoop home [<OPTIONS>] <APP>
# Summary: Open the application's homepage in default browser.
#
# Supports the same format of <APP> parameter as in "scoop install" (See: 'scoop install --help')
#
# Options:
#   -h, --help      Show help for this command.

@(
    @('core', 'Test-ScoopDebugEnabled'),
    @('getopt', 'Resolve-GetOpt'),
    @('help', 'scoop_help'),
    @('Helpers', 'New-IssuePrompt'),
    @('buckets', 'Get-KnownBucket'),
    @('manifest', 'Resolve-ManifestInformation')
) | ForEach-Object {
    if (!([bool] (Get-Command $_[1] -ErrorAction 'Ignore'))) {
        Write-Verbose "Import of lib '$($_[0])' initiated from '$PSCommandPath'"
        . (Join-Path $PSScriptRoot "..\lib\$($_[0]).ps1")
    }
}

$ExitCode = 0
$Options, $Application, $_err = Resolve-GetOpt $args

if ($_err) { Stop-ScoopExecution -Message "scoop home: $_err" -ExitCode 2 }
if (!$Application) { Stop-ScoopExecution -Message 'Parameter <APP> missing' -Usage (my_usage) }

$Application = $Application[0]
# Home does not need to generate the manifest as homepage will not change
if ($Application -notmatch '^https?://') { $Application = ($Application -split '@')[0] }

$resolved = $null
try {
    $resolved = Resolve-ManifestInformation -ApplicationQuery $Application
} catch {
    debug $_.InvocationInfo
    New-IssuePromptFromException -ExceptionMessage $_.Exception.Message

    $ExitCode = 3
}

debug $resolved

if ($ExitCode -eq 0) {
    if ([String]::IsNullOrEmpty($resolved.ManifestObject.homepage)) {
        Write-UserMessage -Message 'Manifest does not contain homepage property' -Err
        $ExitCode = 3
    } else {
        Start-Process $resolved.ManifestObject.homepage
    }
}

exit $ExitCode
