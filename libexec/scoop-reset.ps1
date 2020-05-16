# Usage: scoop reset <app>
# Summary: Reset an app to resolve conflicts
# Help: Used to resolve conflicts in favor of a particular app. For example,
# if you've installed 'python' and 'python27', you can use 'scoop reset' to switch between
# using one or the other.

. "$PSScriptRoot\..\lib\core.ps1"
. "$PSScriptRoot\..\lib\manifest.ps1"
. "$PSScriptRoot\..\lib\help.ps1"
. "$PSScriptRoot\..\lib\getopt.ps1"
. "$PSScriptRoot\..\lib\install.ps1"
. "$PSScriptRoot\..\lib\versions.ps1"
. "$PSScriptRoot\..\lib\shortcuts.ps1"

reset_aliases
$opt, $apps, $err = getopt $args
if ($err) { "scoop reset: $err"; exit 1 }

if (!$apps) { Write-UserMessage -Message '<app> missing' -Err; my_usage; exit 1 }

if ($apps -eq '*') {
    $local = installed_apps $false | ForEach-Object { , @($_, $false) }
    $global = installed_apps $true | ForEach-Object { , @($_, $true) }
    $apps = @($local) + @($global)
}

$exitCode = 0
$apps | ForEach-Object {
    ($app, $global) = $_

    $app, $bucket, $version = parse_app $app

    # Set global flag when running reset command on specific app
    if (($null -eq $global) -and (installed $app $true)) { $global = $true }

    # Skip scoop
    if ($app -eq 'scoop') { return }

    if (!(installed $app)) {
        Write-UserMessage -Message "'$app' isn't installed" -Err
        $exitCode = 1
        return
    }

    if ($null -eq $version) { $version = current_version $app $global }

    $manifest = installed_manifest $app $version $global
    # if this is null we know the version they're resetting to
    # is not installed
    if ($manifest -eq $null) {
        Write-UserMessage -Message "'$app ($version)' isn't installed" -Err
        $exitCode = 1
        return
    }

    if ($global -and !(is_admin)) {
        Write-UserMessage -Message "'$app' ($version) is a global app. You need admin rights to reset it. Skipping." -Warning
        $exitCode = 1
        return
    }

    Write-UserMessage "Resetting $app ($version)."

    $dir = resolve-path (versiondir $app $version $global)
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

exit $exitCode
