# Usage: scoop status [<OPTIONS>]
# Summary: Show status and check for available updates for all installed applications.
# Help: Status command will check various factors and report if any of them is not satisfied.
# Following factors are checked:
#    Scoop installation is up-to-date.
#    Every installed application use the latest version.
#    Remote manifests of installed applications are accessible.
#    All applications are successfully installed.
#    All runtime dependencies are installed.
#    All installed dependencies are still needed.
#
# Options:
#   -h, --help      Show help for this command.

@(
    @('core', 'Test-ScoopDebugEnabled'),
    @('getopt', 'Resolve-GetOpt'),
    @('help', 'scoop_help'),
    @('Helpers', 'New-IssuePrompt'),
    @('Applications', 'Get-InstalledApplicationInformation'),
    @('buckets', 'Get-KnownBucket'),
    @('Dependencies', 'Resolve-DependsProperty'),
    @('depends', 'script_deps'),
    @('Git', 'Invoke-GitCmd'),
    @('manifest', 'Resolve-ManifestInformation'),
    @('Versions', 'Clear-InstalledVersion')
) | ForEach-Object {
    if (!([bool] (Get-Command $_[1] -ErrorAction 'Ignore'))) {
        Write-Verbose "Import of lib '$($_[0])' initiated from '$PSCommandPath'"
        . (Join-Path $PSScriptRoot "..\lib\$($_[0]).ps1")
    }
}

$ExitCode = 0
$Failed = @()
$Outdated = @()
$Removed = @()
$MissingDependencies = @()
$Onhold = @()
$CouldBeRemoved = @()
$null, $null, $_err = Resolve-GetOpt $args

if ($_err) { Stop-ScoopExecution -Message "scoop status: $_err" -ExitCode 2 }

# Check if scoop needs updating
$ScoopInstallationDirectory = versiondir 'scoop' 'current'
$UpdateRequired = $false

if (Join-Path $ScoopInstallationDirectory '.git' | Test-Path -PathType 'Container') {
    $target = @{ 'Repository' = $ScoopInstallationDirectory }

    Invoke-GitCmd @target -Command 'fetch' -Argument '--quiet', 'origin' -Proxy
    $commits = Invoke-GitCmd @target -Command 'log' -Argument '--oneline', """HEAD..origin/$(get_config 'SCOOP_BRANCH' 'main')"""

    if ($commits) { $UpdateRequired = $true }
} else {
    $UpdateRequired = $true
}

if ($UpdateRequired) {
    Write-UserMessage -Message "Scoop is out of date. Run 'scoop update' to get the latest changes" -Warning
} else {
    Write-UserMessage -Message 'Scoop is up to date' -Success
}

$installedApps = @((installed_apps $true) + (installed_apps $false))

# Local and global applications
foreach ($global in ($true, $false)) {
    $dir = appsdir $global
    if (!(Test-Path -LiteralPath $dir -PathType 'Container')) { continue }

    foreach ($application in (Get-ChildItem -LiteralPath $dir | Where-Object -Property 'Name' -NE -Value 'scoop')) {
        $app = $application.name
        $status = app_status $app $global

        if ($status.failed) { $Failed += @{ $app = $status.version } }
        if ($status.removed) { $Removed += @{ $app = $status.version } }
        if ($status.missing_deps) { $MissingDependencies += , (@($app) + @($status.missing_deps)) }
        if ($status.outdated) {
            $Outdated += @{ $app = @($status.version, $status.latest_version) }
            if ($status.hold) { $Onhold += @{ $app = @($status.version, $status.latest_version) } }
        }
        if (($status.install_info.dependency_for) -and ($installedApps -notcontains $status.install_info.dependency_for)) {
            $CouldBeRemoved += $app
        }
    }
}

if ($Outdated) {
    $ExitCode = 3
    $pl = pluralize $Outdated.Count 'Update is' 'Updates are'
    Write-UserMessage -Message "$pl available for:" -Color 'DarkCyan'
    $Outdated.Keys | ForEach-Object {
        Write-UserMessage -Message "    ${_}: $($Outdated.$_[0]) -> $($Outdated.$_[1])"
    }
}

if ($Onhold) {
    $ExitCode = 3
    $pl = pluralize $Onhold.Count 'This application' 'These applications'
    Write-UserMessage -Message "$pl are outdated and held:" -Color 'DarkCyan'
    $Onhold.Keys | ForEach-Object {
        Write-UserMessage -Message "    ${_}: $($Onhold.$_[0]) -> $($Onhold.$_[1])"
    }
}

if ($Removed) {
    $ExitCode = 3
    $pl = pluralize $Removed.Count 'This application' 'These applications'
    Write-UserMessage -Message "$pl manifests have been removed:" -Color 'DarkCyan'
    $Removed.Keys | ForEach-Object {
        Write-UserMessage -Message "    $_"
    }
}

if ($Failed) {
    $ExitCode = 3
    $pl = pluralize $Failed.Count 'This application' 'These applications'
    Write-UserMessage -Message "$pl failed to install:" -Color 'DarkCyan'
    $Failed.Keys | ForEach-Object {
        Write-UserMessage -Message "    $_"
    }
}

if ($MissingDependencies) {
    $ExitCode = 3
    $pl = pluralize $MissingDependencies.Count 'dependency' 'dependencies'
    Write-UserMessage -Message "Missing runtime $pl`:" -Color 'DarkCyan'
    $MissingDependencies | ForEach-Object {
        $app, $deps = $_
        Write-UserMessage -Message "    '$app' requires '$($deps -join ', ')'"
    }
}

if ($CouldBeRemoved) {
    $pl = pluralize $CouldBeRemoved.Count 'This dependency' 'These dependencies'
    Write-UserMessage -Message "$pl could be removed:" -Color 'DarkCyan'
    $CouldBeRemoved | ForEach-Object {
        Write-UserMessage -Message "    $_"
    }
}

if (!$UpdateRequired -and !$Removed -and !$Failed -and !$MissingDependencies -and !$Outdated) { Write-UserMessage -Message 'Everything is ok!' -Success }

exit $ExitCode
