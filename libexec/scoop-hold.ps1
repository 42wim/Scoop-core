# Usage: scoop hold <apps>
# Summary: Hold an app to disable updates

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
        Write-UserMessage -Message "'$app' is not installed." -Err
        $exitCode = 3
        return
    }

    $dir = versiondir $app 'current' $global
    $json = install_info $app 'current' $global
    $install = @{ }
    $json | Get-Member -MemberType Properties | ForEach-Object { $install.Add($_.Name, $json.($_.Name)) }
    $install.hold = $true
    save_install_info $install $dir
    Write-UserMessage -Message "$app is now held and can not be updated anymore." -Success
}

exit $exitCode
