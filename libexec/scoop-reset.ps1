# Usage: scoop reset <app>
# Summary: Reset an app to resolve conflicts
# Help: Used to resolve conflicts in favor of a particular app. For example,
# if you've installed 'python' and 'python27', you can use 'scoop reset' to switch between
# using one or the other.

'core', 'manifest', 'help', 'getopt', 'install', 'Versions', 'shortcuts' | ForEach-Object {
    . "$PSScriptRoot\..\lib\$_.ps1"
}

reset_aliases
$opt, $apps, $err = getopt $args

if ($err) { Write-UserMessage -Message "scoop reset: $err" -Err; exit 2 }
if (!$apps) { Write-UserMessage -Message '<app> missing' -Err; my_usage; exit 1 }

if ($apps -eq '*') {
    $local = installed_apps $false | ForEach-Object { , @($_, $false) }
    $global = installed_apps $true | ForEach-Object { , @($_, $true) }
    $apps = @($local) + @($global)
}

$exitCode = 0
$problems = 0
foreach ($a in $apps) {
    ($app, $global) = $a

    $app, $bucket, $version = parse_app $app

    # Set global flag when running reset command on specific app
    if (($null -eq $global) -and (installed $app $true)) { $global = $true }

    # Skip scoop
    if ($app -eq 'scoop') { return }

    if (!(installed $app)) {
        ++$problems
        Write-UserMessage -Message "'$app' isn't installed" -Err
        continue
    }

    if ($null -eq $version) { $version = Select-CurrentVersion -AppName $app -Global:$global }

    $manifest = installed_manifest $app $version $global
    # if this is null we know the version they're resetting to
    # is not installed
    if ($null -eq $manifest) {
        ++$problems
        Write-UserMessage -Message "'$app ($version)' isn't installed" -Err
        continue
    }

    if ($global -and !(is_admin)) {
        Write-UserMessage -Message "'$app' ($version) is a global app. You need admin rights to reset it. Skipping." -Warning
        ++$problems
        continue
    }

    Write-UserMessage -Message "Resetting $app ($version)."

    $dir = Resolve-Path (versiondir $app $version $global)
    $original_dir = $dir
    $persist_dir = persistdir $app $global

    $install = install_info $app $version $global
    $architecture = $install.architecture

    $dir = link_current $dir
    create_shims $manifest $dir $global $architecture
    create_startmenu_shortcuts $manifest $dir $global $architecture
    env_add_path $manifest $dir
    env_set $manifest $dir $global
    # unlink all potential old link before re-persisting
    unlink_persist_data $original_dir
    persist_data $manifest $original_dir $persist_dir
    persist_permission $manifest $global
}

if ($problems -gt 0) { $exitCode = 10 + $problems }

exit $exitCode
