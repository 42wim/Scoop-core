# Usage: scoop update [<OPTIONS>] [<APP>...]
# Summary: Update installed application(s), or scoop itself.
# Help: 'scoop update' updates scoop and all local buckets to the latest version.
# 'scoop update <APP>' updates already installed application to the latest available version.
#
# You can use '*' in place of <APP> to update all applications.
#
# Options:
#   -h, --help                Show help for this command.
#   -f, --force               Force update even when there is not a newer version.
#   -g, --global              Update a globally installed application(s).
#   -i, --independent         Do not install dependencies automatically.
#   -k, --no-cache            Do not use the download cache.
#   -s, --skip                Skip hash validation (use with caution!).
#   -q, --quiet               Hide extraneous messages.

@(
    @('core', 'Test-ScoopDebugEnabled'),
    @('getopt', 'Resolve-GetOpt'),
    @('help', 'scoop_help'),
    @('Helpers', 'New-IssuePrompt'),
    @('Applications', 'Get-InstalledApplicationInformation'),
    @('Dependencies', 'Resolve-DependsProperty'),
    @('depends', 'script_deps'),
    @('install', 'install_app'),
    @('manifest', 'Resolve-ManifestInformation'),
    @('Uninstall', 'Uninstall-ScoopApplication'),
    @('Update', 'Update-ScoopCoreClone'),
    @('Versions', 'Clear-InstalledVersion')
) | ForEach-Object {
    if (!([bool] (Get-Command $_[1] -ErrorAction 'Ignore'))) {
        Write-Verbose "Import of lib '$($_[0])' initiated from '$PSCommandPath'"
        . (Join-Path $PSScriptRoot "..\lib\$($_[0]).ps1")
    }
}

$ExitCode = 0
$Problems = 0
$Options, $Applications, $_err = Resolve-GetOpt $args 'gfiksq' 'global', 'force', 'independent', 'no-cache', 'skip', 'quiet'

if ($_err) { Stop-ScoopExecution -Message "scoop update: $_err" -ExitCode 2 }

# Flags/Parameters
$Global = $Options.g -or $Options.global
$Force = $Options.f -or $Options.force
$CheckHash = !($Options.s -or $Options.skip)
$UseCache = !($Options.k -or $Options.'no-cache')
$Quiet = $Options.q -or $Options.quiet
$Independent = $Options.i -or $Options.independent

if (!$Applications) {
    if ($Global) { Stop-ScoopExecution -Message 'scoop update: --global option is invalid when <APP> is not specified.' -ExitCode 2 }
    if (!$UseCache) { Stop-ScoopExecution -Message 'scoop update: --no-cache option is invalid when <APP> is not specified.' -ExitCode 2 }

    Update-Scoop
} else {
    if ($Global -and !(is_admin)) { Stop-ScoopExecution -Message 'Admin privileges are required to manipulate with globally installed applications' -ExitCode 4 }

    Update-Scoop -CheckLastUpdate

    $outdatedApplications = @()
    $failedApplications = @()
    $applicationsParam = $Applications # Original users request

    if ($applicationsParam -eq '*') {
        $Applications = applist (installed_apps $false) $false
        if ($Global) { $Applications += applist (installed_apps $true) $true }
    } else {
        $Applications = Confirm-InstallationStatus $applicationsParam -Global:$Global
    }

    if ($Applications) {
        foreach ($_ in $Applications) {
            ($app, $global, $bb) = $_
            $status = app_status $app $global
            $bb = $status.bucket

            if ($force -or $status.outdated) {
                if ($status.hold) {
                    Write-UserMessage -Message "'$app' is held to version $($status.version)"
                } else {
                    $outdatedApplications += applist $app $global $bb
                    $globText = if ($global) { ' (global)' } else { '' }
                    Write-UserMessage -Message "${app}: $($status.version) -> $($status.latest_version)$globText" -Warning -SkipSeverity
                }
            } elseif ($applicationsParam -ne '*') {
                Write-UserMessage -Message "${app}: $($status.version) (latest available version)" -Color 'Green'
            }
        }

        $c = $outdatedApplications.Count
        if ($c -eq 0) {
            Write-UserMessage -Message 'Latest versions for all apps are installed! For more information try ''scoop status''' -Color 'Green'
        } else {
            $a = pluralize $c 'app' 'apps'
            Write-UserMessage -Message "Updating $c outdated ${a}:" -Color 'DarkCyan'
        }
    }

    foreach ($out in $outdatedApplications) {
        try {
            Update-App -App $out[0] -Global:$out[1] -Suggested @{ } -Quiet:$Quiet -Independent:$Independent -SkipCache:(!$UseCache) -SkipHashCheck:(!$CheckHash)
        } catch {
            ++$Problems
            $failedApplications += $out[0]
            debug $_.InvocationInfo
            New-IssuePromptFromException -ExceptionMessage $_.Exception.Message -Application $out[0] -Bucket $out[2]
        }
    }
}

if ($failedApplications) {
    $pl = pluralize $failedApplications.Count 'This application' 'These applications'
    Write-UserMessage -Message "$pl failed to update: $($failedApplications -join ', ')" -Err
}

if ($Problems -gt 0) { $ExitCode = 10 + $Problems }

exit $ExitCode
