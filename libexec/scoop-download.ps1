# Usage: scoop download [<OPTIONS>] <APP>...
# Summary: Download manifest files into cache folder.
# Help: All manifest files will be downloaded into cache folder without need to install the application.
#
# Supports the same format of <APP> parameter as in "scoop install" (See: 'scoop install --help')
#
# Options:
#   -h, --help                      Show help for this command.
#   -s, --skip                      Skip hash check validation (use with caution!).
#   -u, --utility <native|aria2>    Force to download with specific utility.
#   -a, --arch <32bit|64bit>        Use the specified architecture.
#   -b, --all-architectures         All available files across all architectures will be downloaded.

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

#region Parameter validation
$opt, $application, $err = Resolve-GetOpt $args 'sba:u:' 'skip', 'all-architectures', 'arch=', 'utility='
if ($err) { Stop-ScoopExecution -Message "scoop download: $err" -ExitCode 2 }

$checkHash = -not ($opt.s -or $opt.skip)
$utility = $opt.u, $opt.utility, 'native' | Where-Object { -not [String]::IsNullOrEmpty($_) } | Select-Object -First 1

if (!$application) { Stop-ScoopExecution -Message 'Parameter <APP> missing' }
if (($utility -eq 'aria2') -and (!(Test-HelperInstalled -Helper Aria2))) { Stop-ScoopExecution -Message 'Aria2 is not installed' }

$Architecture = Resolve-ArchitectureParameter -Architecture $opt.a, $opt.arch

# Add all supported architectures
if ($opt.b -or $opt.'all-architectures') { $Architecture = $SHOVEL_SUPPORTED_ARCHITECTURES }
#endregion Parameter validation

$exitCode = 0
$problems = 0

try {
    Confirm-DirectoryExistence -LiteralPath $SCOOP_CACHE_DIRECTORY | Out-Null
} catch {
    Stop-ScoopExecution -Message "Could not create cache directory: '$SCOOP_CACHE_DIRECTORY' ($($_.Exception.Message))"
}

foreach ($app in $application) {
    $resolved = $null
    try {
        $resolved = Resolve-ManifestInformation -ApplicationQuery $app
    } catch {
        ++$problems
        debug $_.InvocationInfo
        New-IssuePromptFromException -ExceptionMessage $_.Exception.Message

        continue
    }

    debug $resolved

    # TODO: Remove not neeeded variables. Keep them for now just for less changes
    $appName = $resolved.ApplicationName
    $manifest = $resolved.ManifestObject
    $bucket = $resolved.Bucket
    $version = $manifest.version
    if ($version -eq 'nightly') {
        $version = nightly_version (Get-Date)
        $checkHash = $false
    }

    Write-UserMessage -Message "Starting download for '$app'" -Color 'Green' # TODO: Add better text with parsed appname, version, url/bucket

    $registered = $false
    # TODO: Rework with proper wrappers after #3149
    switch ($utility) {
        'aria2' {
            foreach ($arch in $Architecture) {
                try {
                    dl_with_cache_aria2 $appName $version $manifest $arch $SCOOP_CACHE_DIRECTORY $manifest.cookie $true $checkHash
                } catch {
                    # Do not count specific architectures or URLs
                    if (!$registered) {
                        $registered = $true
                        ++$problems
                    }

                    debug $_.InvocationInfo
                    New-IssuePromptFromException -ExceptionMessage $_.Exception.Message -Application $appName -Bucket $bucket

                    continue
                }
            }
        }

        'native' {
            foreach ($arch in $Architecture) {
                foreach ($url in (url $manifest $arch)) {
                    try {
                        dl_with_cache $appName $version $url $null $manifest.cookie $true

                        if ($checkHash) {
                            $manifestHash = hash_for_url $manifest $url $arch
                            $source = cache_path $appName $version $url
                            $ok, $err = check_hash $source $manifestHash (show_app $appName $bucket)

                            if (!$ok) {
                                if (Test-Path $source) { Remove-Item $source -Force }
                                if ($url -like '*sourceforge.net*') {
                                    Write-UserMessage -Message 'SourceForge.net is known for causing hash validation fails. Please try again before opening a ticket.' -Warning
                                }

                                throw [ScoopException] "Hash check failed|-$err" # TerminatingError thrown
                            }
                        }
                    } catch {
                        # Do not count specific architectures or URLs
                        if (!$registered) {
                            $registered = $true
                            ++$problems
                        }

                        debug $_.InvocationInfo
                        New-IssuePromptFromException -ExceptionMessage $_.Exception.Message -Application $appName -Bucket $bucket

                        continue
                    }
                }
            }
        }

        default {
            # Could be called without any issue as it is used for all applications
            Stop-ScoopExecution -Message 'Not supported download utility' 2
        }
    }
}

if ($problems -gt 0) { $exitCode = 10 + $problems }

exit $exitCode
