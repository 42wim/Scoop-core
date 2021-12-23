@(
    @('core', 'Test-ScoopDebugEnabled'),
    @('Helpers', 'New-IssuePrompt'),
    @('buckets', 'Get-KnownBucket'),
    @('commands', 'Invoke-ScoopCommand'),
    @('Git', 'Invoke-GitCmd'),
    @('install', 'msi_installed'),
    @('Dependencies', 'Resolve-DependsProperty'),
    @('Installation', 'Install-ScoopApp'),
    @('manifest', 'Resolve-ManifestInformation')
) | ForEach-Object {
    if (!([bool] (Get-Command $_[1] -ErrorAction 'Ignore'))) {
        Write-Verbose "Import of lib '$($_[0])' initiated from '$PSCommandPath'"
        . (Join-Path $PSScriptRoot "$($_[0]).ps1")
    }
}

$DEFAULT_UPDATE_REPO = 'https://github.com/Ash258/Scoop-Core'
$DEFAULT_UPDATE_BRANCH = 'main'
# TODO: CONFIG adopt refactor
$SHOW_UPDATE_LOG = get_config 'show_update_log' $true

function Update-ScoopCoreClone {
    <#
    .SYNOPSIS
        Temporary clone scoop into $env:SCOOP\apps\scoop\new and then move it to current.
    .PARAMETER Repo
        Specifies the git repository to be cloned.
    .PARAMETER Branch
        Specifies the git branch to be cloned.
    .PARAMETER TargetDirectory
        Specifies the final directory of scoop installation.
    #>
    param(
        [Parameter(Mandatory)]
        [String] $Repo,
        [Parameter(Mandatory)]
        [String] $Branch,
        [Parameter(Mandatory)]
        [String] $TargetDirectory
    )

    Write-UserMessage -Message "Cloning scoop installation from $Repo ($Branch)" -Info

    $newDir = versiondir 'scoop' 'new'
    Invoke-GitCmd -Command 'clone' -Argument '--quiet', '--single-branch', '--branch', """$Branch""", $Repo, """$newDir""" -Proxy

    # Check if scoop was successful downloaded
    if (!(Test-Path -LiteralPath $newDir -PathType 'Container')) { Stop-ScoopExecution -Message 'Scoop update failed.' }

    # Replace non-git scoop with the git version
    Remove-Item $TargetDirectory -ErrorAction 'Stop' -Force -Recurse
    Move-Item $newDir $TargetDirectory
}

function Update-ScoopCorePull {
    <#
    .SYNOPSIS
        Update working scoop core installation using git pull.
    .PARAMETER TargetDirectory
        Specifies the final directory of scoop installation.
    .PARAMETER Repo
        Specifies the git repository to be cloned.
    .PARAMETER Branch
        Specifies the git branch to be cloned.
    #>
    param(
        [Parameter(Mandatory)]
        [String] $TargetDirectory,
        [Parameter(Mandatory)]
        [String] $Repo,
        [Parameter(Mandatory)]
        [String] $Branch
    )

    $target = @{ 'Repository' = $TargetDirectory }

    $previousCommit = Invoke-GitCmd @target -Command 'CurrentCommit'
    $currentRepo = Invoke-GitCmd @target -Command 'config' -Argument '--get', 'remote.origin.url'
    $currentBranch = Invoke-GitCmd @target -Command 'branch' -Argument '--show-current'

    $isRepoChanged = $currentRepo -ne $Repo
    $isBranchChanged = $currentBranch -ne $Branch

    # Change remote url if the repo is changed
    if ($isRepoChanged) { Invoke-GitCmd @target -Cmd 'config' -Argument 'remote.origin.url', """$Repo""" }

    # Fetch and reset local repo if the repo or the branch is changed
    if ($isRepoChanged -or $isBranchChanged) {
        Write-UserMessage -Message "Switching to $Repo ($Branch)" -Info
        # Reset git fetch refs, so that it can fetch all branches (GH-3368)
        Invoke-GitCmd @target -Command 'config' -Argument 'remote.origin.fetch', '"+refs/heads/*:refs/remotes/origin/*"'
        # Fetch remote branch
        Invoke-GitCmd @target -Command 'fetch' -Argument '--quiet', '--force', 'origin', """refs/heads/${Branch}:refs/remotes/origin/$Branch""" -Proxy
        # Checkout and track the branch
        Invoke-GitCmd @target -Command 'checkout' -Argument '--quiet', '-B', """$Branch""", '--track', """origin/$Branch""" -Proxy
        # Reset branch HEAD
        Invoke-GitCmd @target -Command 'reset' -Argument '--quiet', '--hard', """origin/$Branch"""
    } else {
        Invoke-GitCmd @target -Command 'Update' -Argument '--quiet' -Proxy
    }

    $res = $LASTEXITCODE
    if ($SHOW_UPDATE_LOG) { Invoke-GitCmd @target -Command 'UpdateLog' -Argument """$previousCommit..HEAD""" }

    if ($res -ne 0) { Stop-ScoopExecution -Message 'Update failed.' }
}

function Update-ScoopLocalBucket {
    param([Parameter(Mandatory, ValueFromPipeline)] [String[]] $Bucket)

    process {
        foreach ($b in $Bucket) {
            Write-UserMessage -Message "Updating '$b' bucket..." -Output
            $loc = Find-BucketDirectory $b -Root
            $g = Join-Path $loc '.git'

            # Make sure main bucket, which was downloaded as zip, will be properly "converted" into git
            if (($b -eq 'main') -and !(Test-Path $g -PathType 'Container')) {
                Remove-Bucket -Name 'main'
                Add-Bucket -Name 'main'
            }

            # Skip not git repositories
            if (!(Test-Path $g)) { continue }

            $target = @{ 'Repository' = $loc }
            $previousCommit = Invoke-GitCmd @target -Command 'CurrentCommit'
            Invoke-GitCmd @target -Command 'Update' -Argument '--quiet' -Proxy

            if ($SHOW_UPDATE_LOG) { Invoke-GitCmd @target -Command 'UpdateLog' -Argument """$previousCommit..HEAD""" }
        }
    }
}

function last_scoop_update() {
    # TODO: Config refactor
    $lastUpdate = Invoke-ScoopCommand 'config' @('lastupdate')

    if ($null -ne $lastUpdate) {
        try {
            $lastUpdate = Get-Date ($lastUpdate.Substring(4))
        } catch {
            Write-UserMessage -Message 'Config: Incorrect update date format' -Info
            $lastUpdate = $null
        }
    }

    return $lastUpdate
}

function is_scoop_outdated() {
    $lastUp = last_scoop_update
    $now = Get-Date
    $res = $true

    if ($null -eq $lastUp) {
        # TODO: Config refactor
        Invoke-ScoopCommand 'config' @('lastupdate', ($now.ToString($UPDATE_DATE_FORMAT))) | Out-Null
    } else {
        $res = $lastUp.AddHours(3) -lt $now.ToLocalTime()
    }

    return $res
}

function Update-Scoop {
    <#
    .SYNOPSIS
        Update scoop itself and all buckets.
    #>
    param([Switch] $CheckLastUpdate)

    if (!(Test-CommandAvailable -Command 'git')) { Stop-ScoopExecution -Message 'Scoop uses Git to update itself. Run ''scoop install git'' and try again.' }
    # Skip updates if not needed
    if ($CheckLastUpdate -and ($false -eq (is_scoop_outdated))) {
        return
    }

    Write-UserMessage -Message 'Updating Scoop...' -Output

    # TODO: CONFIG refactor adoption
    $configRepo = get_config 'SCOOP_REPO'
    $configBranch = get_config 'SCOOP_BRANCH'
    $currentDir = versiondir 'scoop' 'current'

    # Defaults
    if (!$configRepo) {
        $configRepo = $DEFAULT_UPDATE_REPO
        set_config 'SCOOP_REPO' $DEFAULT_UPDATE_REPO | Out-Null
    }
    # Main adoption
    if ($configBranch -and ($configBranch -eq 'master')) {
        Write-UserMessage -Message 'Master branch should not be used anymore. Migrating to ''main''' -Warning
        $configBranch = $null # Trigger automatic config handler below
    }
    if (!$configBranch) {
        $configBranch = $DEFAULT_UPDATE_BRANCH
        set_config 'SCOOP_BRANCH' $DEFAULT_UPDATE_BRANCH | Out-Null
    }

    # Get when was scoop updated
    $lastUpdate = last_scoop_update
    if ($null -eq $lastUpdate) { $lastUpdate = [System.DateTime]::Now }
    $lastUpdate = $lastUpdate.ToString('s')

    # Clone new installation or pull changes
    $par = @{ 'Repo' = $configRepo; 'Branch' = $configBranch; 'TargetDirectory' = $currentDir }
    if (Join-Path $currentDir '.git' | Test-Path -PathType 'Container') {
        Update-ScoopCorePull @par
    } else {
        Update-ScoopCoreClone @par
    }

    # Update buckets
    # Add main bucket if not already added
    if ((Get-LocalBucket) -notcontains 'main') {
        Write-UserMessage -Message 'The main bucket has been separated', 'Adding main bucket...' -Output
        try {
            Add-Bucket -Name 'main'
        } catch {
            Write-UserMessage -Message "'main' bucket cannot be added: $($_.Exception.Message)" -Err
        }
    }

    # Add Base bucket if not already added
    if ((Get-LocalBucket) -notcontains 'Base') {
        Write-UserMessage -Message 'New Base bucket was introduces, which will replace main', 'Adding Base bucket...' -Output
        try {
            Add-Bucket -Name 'Base'
        } catch {
            Write-UserMessage -Message "'Base' bucket cannot be added: $($_.Exception.Message)" -Err
        }
    }

    ensure_scoop_in_path
    shim (Join-Path $currentDir 'bin\scoop.ps1') $false

    Get-LocalBucket | Update-ScoopLocalBucket

    set_config 'lastupdate' ((Get-Date).ToString($UPDATE_DATE_FORMAT)) | Out-Null
    Write-UserMessage -Message 'Scoop was updated successfully!' -Success
}

function Update-App {
    <#
    .SYNOPSIS
        Update scoop installed application
    .PARAMETER App
        Specifies the application name.
    .PARAMETER Global
        Specifies globally installe application.
    .PARAMETER Quiet
        Specifies supressing more verbose output.
    .PARAMETER Independent
        Specifies to not update dependent applications.
    .PARAMETER Suggested
        Specifies applications to be shown to user as suggestions after update.
    .PARAMETER SkipCache
        Specifies to skip use of download cache.
    .PARAMETER SkipHashCheck
        Specifies to not verify downloaded files using hash comparison.
    #>
    [CmdletBinding()]
    param(
        [String] $App,
        [Switch] $Global,
        [Switch] $Quiet,
        [Switch] $Independent,
        $Suggested,
        [Switch] $SkipCache,
        [Switch] $SkipHashCheck
    )

    $oldVersion = Select-CurrentVersion -AppName $App -Global:$Global
    $oldManifest = installed_manifest $App $oldVersion $Global
    $install = install_info $App $oldVersion $Global

    # Old variables
    $checkHash = !$SkipHashCheck
    $useCache = !$SkipCache
    $oldVersion = $oldVersion
    $oldManifest = $oldManifest
    $toInstall = @{
        'Failed'   = @()
        'Resolved' = @()
    }

    # Re-use architecture, bucket and url from first install
    $architecture = ensure_architecture $install.architecture
    $url = $install.url
    $bucket = $install.bucket
    if ($null -eq $bucket) { $bucket = 'main' }

    $a = if ($url) { $url } else { "$bucket/$App" }

    # Check dependencies
    if ($Independent) {
        $ar = $null
        try {
            $ar = Resolve-ManifestInformation -ApplicationQuery $a
        } catch {
            throw [ScoopException] $_.Exception.Message # TerminatingError thrown
        }
        $toInstall.Resolved += $ar
    } else {
        $toInstall = Resolve-MultipleApplicationDependency -Applications @($a) -Architecture $architecture -IncludeInstalledApps
    }

    if ($toInstall.Failed.Count -gt 0) {
        throw [ScoopException] 'Cannot resolve all dependencies' # TerminatingError thrown
    }

    $_deps = @($toInstall.Resolved | Where-Object -Property 'Dependency' -NE -Value $false)
    $applicationToUpdate = @($toInstall.Resolved | Where-Object -Property 'Dependency' -EQ -Value $false) | Select-Object -First 1

    # Install dependencies
    foreach ($d in $_deps) {
        Install-ScoopApplication -ResolvedObject $d -Architecture $architecture -Global:$Global -Suggested:$Suggested `
            -UseCache:$useCache -CheckHash:$checkHash
    }

    $manifest = $applicationToUpdate.ManifestObject
    $version = $manifest.version

    if ($version -eq 'nightly') {
        $version = nightly_version (Get-Date) $Quiet
        $checkHash = $false
    }

    # TODO: Could this ever happen?
    if (!$Force -and ($oldVersion -eq $version)) {
        throw [ScoopException] "The Latest version of '$App' ($version) is already installed." # TerminatingError thrown
    }

    # TODO:???
    # TODO: Case when bucket no longer have this application?
    if (!$version) {
        throw [ScoopException] "No manifest available for '$App'" # TerminatingError thrown
    }

    # Do not update if the new manifest does not support the installed architecture
    if (!(supports_architecture $manifest $architecture)) {
        throw [ScoopException] "Manifest no longer supports specific architecture '$architecture'" # TerminatingError thrown
    }

    Deny-ArmInstallation -Manifest $manifest -Architecture $architecture

    Write-UserMessage -Message "Updating '$App' ($oldVersion -> $version) [$architecture]" -Success

    #region Workaround of #2220
    # Remove and replace whole region after proper implementation
    Write-UserMessage -Message 'Downloading new version' -Output

    Invoke-ManifestScript -Manifest $manifest -ScriptName 'pre_download' -Architecture $architecture

    if (Test-Aria2Enabled) {
        dl_with_cache_aria2 $App $version $manifest $architecture $SCOOP_CACHE_DIRECTORY $manifest.cookie $true $checkHash
    } else {
        $urls = url $manifest $architecture

        foreach ($url in $urls) {
            dl_with_cache $App $version $url $null $manifest.cookie $true

            if ($checkHash) {
                $manifest_hash = hash_for_url $manifest $url $architecture
                $source = cache_path $App $version $url
                $ok, $err = check_hash $source $manifest_hash (show_app $App $bucket)

                if (!$ok) {
                    # Remove cached file
                    if (Test-Path $source) { Remove-Item $source -Force }
                    if ($url -like '*sourceforge.net*') {
                        Write-UserMessage -Message 'SourceForge.net is known for causing hash validation fails. Please try again before opening a ticket.' -Warning
                    }
                    throw [ScoopException] "Hash check failed|-$err" # TerminatingError thrown
                }
            }
        }
    }

    # There is no need to check hash again while installing
    $checkHash = $false
    #endregion Workaround of #2220

    $result = Uninstall-ScoopApplication -App $App -Global:$Global
    if ($result -eq $false) { throw [ScoopException] 'Ignore' }

    # Rename current version to .old if same version is installed
    if ($Force -and ($oldVersion -eq $version)) {
        $dir = versiondir $App $oldVersion $Global

        $old = Join-Path $dir "..\_$version.old"
        if (Test-Path -LiteralPath $old -PathType 'Container') {
            $i = 1
            while (Test-Path -LiteralPath "$old($i)" -PathType 'Container') { ++$i }
            Move-Item $dir "$old($i)"
        } else {
            Move-Item $dir $old
        }
    }

    Install-ScoopApplication -ResolvedObject $applicationToUpdate -Architecture $architecture -Global:$Global -Suggested:$Suggested `
        -UseCache:$useCache -CheckHash:$checkHash
}
