#!/usr/bin/env pwsh
param($Folder, [Switch] $Https)

$REPOSITORIES = @(
    @('Ash258/Scoop-Core', 'CORE'),
    @('shovel-org/GenericBucket', 'GenericBucket'),
    @('shovel-org/GithubActions', 'GithubActions'),
    @('shovel-org/Dockers', 'Dockers'),
    @('shovel-org/Vagrants', 'Vagrants'),
    @('shovel-org/Validator', 'Validator'),
    @('shovel-org/Shim', 'Shim'),
    @('shovel-org/Base', 'Base'),
    @('shovel-org/Sysinternals-Bucket', 'Sysinternals'),
    @('Ash258/Scoop-NirSoft', 'NirSoft'),
    @('Ash258/Scoop-JetBrains', 'JetBrains'),
    @('Ash258/Shovel-Licenses', 'Licenses'),
    @('Ash258/Shovel-Ash258', 'Ash258'),
    @('Ash258/GithubActionsBucketForTesting', 'GithubActionsBucketForTesting')
)

$GH = 'git@github.com:'
if ($Https) { $GH = 'https://github.com/' }

$ind = 0
foreach ($repo in $REPOSITORIES) {
    ++$ind
    Write-Progress -Id 1 -Activity 'Clonning' -Status $repo[0] -PercentComplete ($ind * (100 / $REPOSITORIES.Count))
    $origin = $targetname = $Ash = $target = $null

    $origin = $GH + $repo[0]
    $targetname = $repo[1]
    $Ash = $repo[2]
    $target = Join-Path $Folder $targetname

    if (!(Test-Path $target)) { git clone $origin $target }
    $alreadyAdded = git -C $target remote get-url --all Ash 2>$null
    if ($Ash -and ($null -eq $alreadyAdded)) { git -C $target remote add 'Ash' "$GH$Ash" }
    git -C $target fetch --all
}
