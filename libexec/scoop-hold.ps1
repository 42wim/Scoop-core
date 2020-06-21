# Usage: scoop hold <apps> [options]
# Summary: Hold an app to disable updates
# Options:
#   -g, --global              Hold globally installed app

'getopt', 'help', 'Helpers', 'manifest' | ForEach-Object {
    . (Join-Path $PSScriptRoot "..\lib\$_.ps1")
}

reset_aliases

$opt, $apps, $err = getopt $args 'g' 'global'
if ($err) { Write-UserMessage -Message "scoop hold: $err" -Err; exit 2 }
if (!$apps) { Write-UserMessage -Message '<app> missing' -Err; my_usage; exit 1 }

$global = $opt.g -or $opt.global

# TODO: Stop-ScoopExecution
if ($global -and !(is_admin)) { abort 'Admin privileges are required to interact with globally installed apps' 4 }

if (!$apps) {
    my_usage
    exit 1
}

$exitCode = 0
foreach ($app in $apps) {
    # Not at all installed
    if (!(installed $app)) {
        Write-UserMessage -Message "'$app' is not installed." -Err
        $exitCode = 3
        continue
    }

    # Global required, but not installed globally
    if ($global -and (!(installed $app $global))) {
        Write-UserMessage -Message "'$app' not installed globally" -Err
        $exitCode = 3
        continue
    }

    # TODO: Respect NO_JUNCTION
    $dir = versiondir $app 'current' $global
    $json = install_info $app 'current' $global
    if ($json.hold -and ($json.hold -eq $true)) {
       Write-UserMessage -Message "'$app' is already held" -Warning
       continue
    }
    $install = @{ }
    # TODO: Add-member instead of duplicating of whole object
    $json | Get-Member -MemberType Properties | ForEach-Object { $install.Add($_.Name, $json.($_.Name)) }
    $install.hold = $true
    save_install_info $install $dir
    Write-UserMessage -Message "$app is now held and can not be updated anymore." -Success
}

exit $exitCode
