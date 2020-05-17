# Usage: scoop unhold <app>
# Summary: Unhold an app to enable updates

'help', 'manifest' | ForEach-Object {
    . "$PSScriptRoot\..\lib\$_.ps1"
}

reset_aliases
$apps = $args

if (!$apps) {
    my_usage
    exit 1
}

$exitCode = 0
foreach ($app in $apps) {
    $global = installed $app $true

    if (!(installed $app)) {
        $exitCode = 3
        Write-UserMessage -Message "'$app' is not installed." -Err
        return
    }

    $dir = versiondir $app 'current' $global
    $json = install_info $app 'current' $global
    $install = @{ }
    $json | Get-Member -MemberType Properties | ForEach-Object { $install.Add($_.Name, $json.($_.Name)) }
    $install.hold = $null
    save_install_info $install $dir
    Write-UserMessage -Message "$app is no longer held and can be updated again." -Success
}

exit $exitCode
