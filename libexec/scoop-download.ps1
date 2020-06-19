# Usage: scoop download <app> [options]
# Summary: Download manifest files into cache folder.
#
# Help: All manifest files will be downloaded into cache folder.
#
# Options:
#   -s, --skip                      Skip hash check validation.
#   -u, --utility <native|aria2>    Force using specific download utility.
#   -a, --arch <32bit|64bit>        Use the specified architecture.
#   -b, --all-architectures         All avaible files across all architectures will be downloaded.

'getopt', 'help', 'manifest', 'install' | ForEach-Object {
    . (Join-Path $PSScriptRoot "..\lib\$_.ps1")
}

reset_aliases

#region Parameter validation
$opt, $application, $err = getopt $args 'sba:u:' 'skip', 'all-architectures', 'arch=', 'utility='
if ($err) {
    # TODO: Stop-ScoopExecution
    Write-UserMessage -Message "scoop install: $err" -Err
    exit 2
}

$checkHash = -not ($opt.s -or $opt.skip)
$utility = $opt.u, $opt.utility, 'native' | Where-Object { -not [String]::IsNullOrEmpty($_) } | Select-Object -First 1

try {
    $architecture = ensure_architecture ($opt.a + $opt.arch)
} catch {
    # TODO: Stop-ScoopExecution
    abort "ERROR: $_" 2
}
# Add both architectures
if ($opt.b -or $opt.'all-architectures') { $architecture = '32bit', '64bit' }

if (-not $application) {
    # TODO:? Extend Stop-ScoopExecution with -Usage switch
    Write-UserMessage -Message '<app> missing' -Err
    my_usage
    exit 1
}

if (($utility -eq 'aria2') -and (-not (Test-HelperInstalled -Helper Aria2))) {
    # TODO: Stop-ScoopExecution
    abort 'Aria2 is not installed'
}
#endregion Parameter validation

$exitCode = 0
$problems = 0
foreach ($app in $application) {
    # Prevent leaking variables from previous iteration
    $cleanAppName = $bucket = $version = $appName = $manifest = $foundBucket = $url = $null

    $cleanAppName, $bucket, $version = parse_app $app
    $appName, $manifest, $foundBucket, $url = Find-Manifest $cleanAppName $bucket
    if ($null -eq $bucket) { $bucket = $foundBucket }

    # Handle potential use case, which should not appear, but just in case
    # If parsed name/bucket is not same as the provided one
    if ((-not $url) -and (($cleanAppName -ne $appName) -or ($bucket -ne $foundBucket))) {
        debug $bucket
        debug $cleanAppName
        debug $foundBucket
        debug $appName

        Write-UserMessage -Message 'Found application name or bucket is not same as requested' -Err
        ++$problems

        continue
    }

    # Generate manifest if there is different version in manifest
    if (($null -ne $version) -and ($manifest.version -ne $version)) {
        $generated = generate_user_manifest $appName $bucket $version
        if ($null -eq $generated) {
            Write-UserMessage -Message 'Manifest cannot be generated with provided version' -Err
            ++$problems

            continue
        }
        $manifest = parse_json $generated
    }

    if (-not $version) { $version = $manifest.version }
    if ($version -eq 'nightly') {
        $version = nightly_version (Get-Date)
        $checkHash = $false
    }

    Write-UserMessage "Starting download for $app" -Color Green

    # TODO: Rework with proper wrappers after #3149
    switch ($utility) {
        'aria2' {
            foreach ($arch in $architecture) {
                dl_with_cache_aria2 $appName $version $manifest $arch $cachedir $manifest.cookie $true $checkHash
            }
        }

        'native' {
            foreach ($arch in $architecture) {
                foreach ($url in (url $manifest $arch)) {
                    dl_with_cache $appName $version $url $null $manifest.cookie $true

                    if ($checkHash) {
                        $manifestHash = hash_for_url $manifest $url $arch
                        $source = cache_path $appName $version $url
                        $ok, $err = check_hash $source $manifestHash (show_app $appName $bucket)

                        if (!$ok) {
                            Write-UserMessage -Message $err -Err
                            if (Test-Path $source) { Remove-Item $source -Force }
                            if ($url -like '*sourceforge.net*') {
                                Write-UserMessage -Message 'SourceForge.net is known for causing hash validation fails. Please try again before opening a ticket.' -Warning
                            }
                            Write-UserMessage -Message (new_issue_msg $appName $bucket 'hash check failed') -Err
                            ++$problems

                            continue
                        }
                    }
                }
            }
        }

        default {
            # abort could be called without any issue as it is used for all applications
            # TODO: Stop-ScoopExecution
            abort 'Not supported download utility' 2
        }
    }
}

if ($problems -gt 0) { $exitCode = 10 + $problems }

exit $exitCode
