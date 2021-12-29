@(
    @('core', 'Test-ScoopDebugEnabled'),
    @('Helpers', 'New-IssuePrompt'),
    @('json', 'ConvertToPrettyJson'),
    @('manifest', 'Resolve-ManifestInformation'),
    @('Dependencies', 'Resolve-DependsProperty'),
    @('Versions', 'Clear-InstalledVersion')
) | ForEach-Object {
    if (!([bool] (Get-Command $_[1] -ErrorAction 'Ignore'))) {
        Write-Verbose "Import of lib '$($_[0])' initiated from '$PSCommandPath'"
        . (Join-Path $PSScriptRoot "$($_[0]).ps1")
    }
}

#region Application instalaltion info file
function Get-InstalledApplicationInformation {
    <#
    .SYNOPSIS
        Get stored information about installed application.
    .PARAMETER AppName
        Specifies the application name.
    .PARAMETER Version
        Specifies the version of the application.
        Use 'CURRENT_' to lookup for the currently used version. (Respecting NO_JUNCTIONS and different version)
    .PARAMETER Global
        Specifies globally installed application.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [String] $AppName,
        [String] $Version = 'CURRENT_',
        [Switch] $Global
    )

    process {
        if ($Version -ceq 'CURRENT_') { $Version = Select-CurrentVersion -AppName $AppName -Global:$Global }
        $applicationDirectory = versiondir $AppName $Version $Global
        $installInfoPath = Join-Path $applicationDirectory 'scoop-install.json'

        if (!(Test-Path $installInfoPath)) {
            $old = Join-Path $applicationDirectory 'install.json'
            # Migrate from old scoop's 'install.json'
            if (Test-Path $old) {
                Write-UserMessage -Message 'Migrating ''install.json'' to ''scoop-install.json''' -Info
                Rename-Item $old 'scoop-install.json'
            } else {
                return $null
            }
        }

        return parse_json $installInfoPath
    }
}

function Get-InstalledApplicationInformationPropertyValue {
    <#
    .SYNOPSIS
        Get specific property stored in application's information file.
    .PARAMETER AppName
        Specifies the application name.
    .PARAMETER Version
        Specifies the version of the application.
        Use 'CURRENT_' to lookup for the currently used version. (Respecting NO_JUNCTIONS and different version)
    .PARAMETER Global
        Specifies globally installed application.
    .PARAMETER Property
        Specifies the property name to be evaluated.
    .PARAMETER InputObject
        Specifies the installation information object to be fed instead of loading it from file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [String] $AppName,
        [String] $Version = 'CURRENT_',
        [Switch] $Global,
        [Parameter(Mandatory)]
        [String] $Property,
        [Object] $InputObject
    )

    process {
        $info = if ($InputObject) { $InputObject } else { Get-InstalledApplicationInformation -AppName $AppName -Version $Version -Global:$Global }
        $prop = $null

        if ($info) {
            $properties = @($info | Get-Member -MemberType 'NoteProperty' | Select-Object -ExpandProperty 'Name')
            if ($properties -and $properties.Contains($Property)) { $prop = $info.$Property }
        }

        return $prop
    }
}

function Set-InstalledApplicationInformationPropertyValue {
    <#
    .SYNOPSIS
        Set specific property to be preserved in application's information file.
    .PARAMETER AppName
        Specifies the application name.
    .PARAMETER Version
        Specifies the version of application.
        Use 'CURRENT_' to lookup for the currently used version. (Respecting NO_JUNCTIONS and different version)
    .PARAMETER Global
        Specifies globally installed application.
    .PARAMETER Property
        Specifies the property name to be saved.
    .PARAMETER Value
        Specifies the value to be saved.
    .PARAMETER Force
        Specifies to override the value saved in the file.
    .PARAMETER InputObject
        Specifies to feed installation information object instead of loading it all the time from file.
    .PARAMETER PassThru
        Specifies to return the new object from the function.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [String] $AppName,
        [String] $Version = 'CURRENT_',
        [Switch] $Global,
        [Parameter(Mandatory)]
        [String[]] $Property,
        [Parameter(Mandatory)]
        [Object[]] $Value,
        [Switch] $Force,
        [Object] $InputObject,
        [Switch] $PassThru
    )

    begin {
        if ($Version -ceq 'CURRENT_') { $Version = Select-CurrentVersion -AppName $AppName -Global:$Global }
        $info = if ($InputObject) { $InputObject } else { Get-InstalledApplicationInformation -AppName $AppName -Version $Version -Global:$Global }
        if (!$info) { $info = @{ } }
        if ($Property.Count -ne $Value.Count) {
            throw [ScoopException]::new('Property and value mismatch')
        }
    }

    process {
        for ($i = 0; $i -lt $Property.Count; ++$i) {
            $prop = $Property[$i]
            $val = $Value[$i]
            $properties = @($info | Get-Member -MemberType 'NoteProperty' | Select-Object -ExpandProperty 'Name')

            if ($properties -and $properties.Contains($prop)) {
                if ($Force) {
                    $info.$prop = $val
                } else {
                    throw [ScoopException]::new("Property '$prop' is already set")
                }
            } else {
                $info | Add-Member -MemberType 'NoteProperty' -Name $prop -Value $val
            }
        }
    }

    end {
        $appDirectory = versiondir $AppName $Version $Global
        # TODO: Trim nulls
        # TODO: Out-InstalledApplicationInfoFile
        $info | ConvertToPrettyJson | Out-UTF8File -Path (Join-Path $appDirectory 'scoop-install.json')

        if ($PassThru) { return $info }
    }
}
#endregion Application instalaltion info file

function app_status($app, $global) {
    $status = @{ }
    $status.installed = (installed $app $global)
    $status.version = Select-CurrentVersion -AppName $app -Global:$global
    $status.latest_version = $status.version

    $install_info = install_info $app $status.version $global

    $status.install_info = $install_info
    $status.failed = (!$install_info -or !$status.version)
    $status.hold = ($install_info.hold -eq $true)
    $status.bucket = $install_info.bucket
    $status.removed = $false

    $todo = $app
    if ($install_info.bucket) {
        $todo = "$($install_info.bucket)/$app"
    } elseif ($install_info.url) {
        $todo = $install_info.url
    }
    $manifest = $null
    try {
        $manifest = (Resolve-ManifestInformation -ApplicationQuery $todo).ManifestObject
    } catch {
        $status.removed = $true
    }

    if ($manifest.version) { $status.latest_version = $manifest.version }

    $status.outdated = $false
    if ($status.version -and $status.latest_version) {
        $status.outdated = (Compare-Version -ReferenceVersion $status.version -DifferenceVersion $status.latest_version) -ne 0
    }

    $status.missing_deps = @()
    # TODO: This is not correct. Why would you check dependencies of the potential newer version of application?
    #   scoop-manifest should be used instead
    # TODO: Better handle different dependencies version
    $deps = @(Resolve-DependsProperty -Manifest $manifest) | Where-Object {
        try {
            $res = Resolve-ManifestInformation -ApplicationQuery $_ -Simple
            return !(installed $res.ApplicationName)
        } catch {
            return $true
        }
    }

    if ($deps) { $status.missing_deps += , $deps }

    return $status
}

function Confirm-InstallationStatus {
    <#
    .SYNOPSIS
        Get status of specific applications.
        Returns array of 3 item arrays (appliation name, globally installed, bucket name)
    .PARAMETER Apps
        Specifies the array of applications to be evalueated.
    .PARAMETER Global
        Specifies to check globally installed applications.
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory)]
        [String[]] $Apps,
        [Switch] $Global
    )
    $Global | Out-Null # PowerShell/PSScriptAnalyzer#1472
    $installed = @()

    foreach ($app in $Apps | Select-Object -Unique | Where-Object -Property 'Name' -NE -Value 'scoop' | Where-Object { $_ -ne 'scoop' }) {
        $info = install_info $app (Select-CurrentVersion -AppName $app -Global:$Global) $Global
        $buc = $info.bucket

        if ($Global) {
            if (installed $app $true) {
                $installed += , @($app, $true, $buc)
            } elseif (installed $app $false) {
                Write-UserMessage -Message "'$app' isn't installed globally, but it is installed for your account." -Err
                Write-UserMessage -Message 'Try again without the --global (or -g) flag instead.' -Warning
            } else {
                Write-UserMessage -Message "'$app' isn't installed." -Err
            }
        } else {
            if (installed $app $false) {
                $installed += , @($app, $false, $buc)
            } elseif (installed $app $true) {
                Write-UserMessage -Message "'$app' isn't installed for your account, but it is installed globally." -Err
                Write-UserMessage -Message 'Try again with the --global (or -g) flag instead.' -Warning
            } else {
                Write-UserMessage -Message "'$app' isn't installed." -Err
            }
        }
    }

    return , $installed
}

function Test-ResolvedObjectIsInstalled {
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param($ResolvedObject, [Switch] $Global)

    process {
        $app = $ResolvedObject.ApplicationName
        $gf = if ($Global) { ' --global' } else { '' }

        if (installed $app $Global) {
            $installedVersion = Select-CurrentVersion -AppName $app -Global:$Global
            $info = install_info $app $installedVersion $Global

            if ($info.hold -and ($info.hold -eq $true)) {
                Write-UserMessage -Message @(
                    "'$app' is being held."
                    "Use 'scoop unhold$gf $app' to unhold the application first and then try again."
                ) -Warning

                return $true
            }

            # Test if explicitly provided version is installed
            if ($ResolvedObject.RequestedVersion) {
                $all = @(Get-InstalledVersion -AppName $app -Global:$Global)

                $verdict = $all -contains $ResolvedObject.RequestedVersion
                if ($verdict) {
                    Write-UserMessage -Message "'$app' ($($ResolvedObject.RequestedVersion)) is already installed." -Warning
                }

                return $verdict
            }

            if (!$info) {
                Write-UserMessage -Err -Message @(
                    "It looks like a previous installation of '$app' failed."
                    "Run 'scoop uninstall$gf $app' before retrying the install."
                )

                return $true
            }

            Write-UserMessage -Message @(
                "'$app' ($installedVersion) is already installed.",
                "Use 'scoop update$gc $app' to install a new version."
            ) -Warning

            return $true
        }

        return $false
    }
}
