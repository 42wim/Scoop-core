@(
    @('core', 'Test-ScoopDebugEnabled'),
    @('Helpers', 'New-IssuePrompt'),
    @('autoupdate', 'Invoke-Autoupdate'),
    @('buckets', 'Get-KnownBucket'),
    @('json', 'ConvertToPrettyJson')
) | ForEach-Object {
    if (!([bool] (Get-Command $_[1] -ErrorAction 'Ignore'))) {
        Write-Verbose "Import of lib '$($_[0])' initiated from '$PSCommandPath'"
        . (Join-Path $PSScriptRoot "$($_[0]).ps1")
    }
}

$ALLOWED_MANIFEST_EXTENSION = @('json', 'yaml', 'yml')
$ALLOWED_MANIFEST_EXTENSION_REGEX = $ALLOWED_MANIFEST_EXTENSION -join '|'

function ConvertFrom-Manifest {
    <#
    .SYNOPSIS
        Parse manifest file into object.
    .PARAMETER Path
        Specifies the path to the file representing manifest.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCustomObject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [Alias('LiteralPath', 'File')]
        [System.IO.FileInfo] $Path
    )

    process {
        if (!(Test-Path $Path -PathType 'Leaf')) { return $null }

        $result = $null
        $content = Get-Content $Path -Encoding 'UTF8' -Raw

        switch ($Path.Extension) {
            '.json' {
                $result = ConvertFrom-Json -InputObject $content -ErrorAction 'Stop'
            }
            { $_ -in '.yaml', '.yml' } {
                if (!(Get-Module -Name 'powershell-yaml' -ErrorAction 'SilentlyContinue')) {
                    Join-Path $PSScriptRoot '..\supporting\yaml\bin\powershell-yaml.psd1' | Import-Module -Prefix 'CloudBase' -Verbose:$false
                }

                # Ugly hotfix to prevent ordering of properties and PSCustomObject
                $result = ConvertFrom-CloudBaseYaml -Yaml $content -Ordered | ConvertTo-Json -Depth 100 | ConvertFrom-Json
            }
            default {
                Write-UserMessage -Message "Not specific manifest extension ($_). Falling back to json" -Info
                $result = ConvertFrom-Json -InputObject $content -ErrorAction 'Stop'
            }
        }

        return $result
    }
}

function ConvertTo-Manifest {
    <#
    .SYNOPSIS
        Convert manifest object into string.
    .PARAMETER File
        Specifies the path to the file where manifest will be saved.
    .PARAMETER Manifest
        Specifies the manifest object.
    .PARAMETER Extension
        Specifies the structure of resulted string (json, yaml, yml)
        Ignored if File is provided.
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('Path', 'LiteralPath')]
        [System.IO.FileInfo] $File,
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('InputObject', 'Content')]
        $Manifest,
        [Parameter(ValueFromPipelineByPropertyName)]
        [String] $Extension
    )

    process {
        $ext = if ($File) { $File.Extension.TrimStart('.') } else { $Extension }
        $content = $null

        switch ($ext) {
            'json' {
                $content = $Manifest | ConvertToPrettyJson
                $content = $content -replace "`t", (' ' * 4)
            }
            { $_ -in 'yaml', 'yml' } {
                if (!(Get-Module -Name 'powershell-yaml')) {
                    Join-Path $PSScriptRoot '..\supporting\yaml\bin\powershell-yaml.psd1' | Import-Module -Prefix 'CloudBase' -Verbose:$false
                }

                # TODO: Try to adopt similar stuff like ConvertToPrettyJson
                $content = ConvertTo-CloudBaseYaml -Data $Manifest
                $content = $content.TrimEnd("`r`n") # For some reason it produces two line endings at the end
            }
            default {
                Write-UserMessage -Message "Not specific manifest extension ($_). Falling back to json" -Info
                $content = $Manifest | ConvertToPrettyJson
                $content = $content -replace "`t", (' ' * 4)
            }
        }

        if ($File) {
            Out-UTF8File -File $File.FullName -Content $content
        } else {
            return $content
        }
    }
}

function New-VersionedManifest {
    <#
    .SYNOPSIS
        Generate new manifest with specified version.
    .DESCRIPTION
        Path to the new manifest will be returned.
        Generated manifests will be saved into $env:SCOOP\manifests and named as '<OriginalName>-<Random>-<Random>.<OriginalExtension>'
    .PARAMETER Path
        Specifies the path to the original manifest.
    .PARAMETER Version
        Specifies the version to which manifest should be updated.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [Alias('LiteralPath')]
        [System.IO.FileInfo] $Path,
        [Parameter(Mandatory)]
        [String] $Version
    )

    process {
        $manifest = $newManifest = $null
        try {
            $manifest = ConvertFrom-Manifest -LiteralPath $Path
        } catch {
            throw [ScoopException]::new("Invalid manifest '$Path'")
        }

        $name = "$($Path.BaseName)-$_localAdditionalSeed$(Get-Random)-$(Get-Random)$($Path.Extension)"
        $outPath = Confirm-DirectoryExistence -LiteralPath $SHOVEL_GENERAL_MANIFESTS_DIRECTORY | Join-Path -ChildPath $name

        try {
            $newManifest = Invoke-Autoupdate $Path.Basename $null $manifest $Version $(${ }) $Path.Extension -IgnoreArchive
            if ($null -eq $newManifest) { throw 'trigger' }
        } catch {
            throw [ScoopException]::new("Cannot generate manifest with version '$Version'")
        }

        ConvertTo-Manifest -Path $outpath -Manifest $newManifest

        return $outPath
    }
}

#region Resolve Helpers
$_br = '[/\\]'
$_archivedManifestRegex = "${_br}bucket${_br}old${_br}(?<manifestName>.+?)${_br}(?<manifestVersion>.+?)\.(?<manifestExtension>$ALLOWED_MANIFEST_EXTENSION_REGEX)$"

$_bucketLookup = '(?<bucket>[a-zA-Z\d.-]+)'
$_applicationLookup = '(?<app>[a-zA-Z\d_.-]+)'
$_versionLookup = '@(?<version>.+)'
$_lookupRegex = "^($_bucketLookup/)?$_applicationLookup($_versionLookup)?$"

$_localAdditionalSeed = '258258--' # Everything before this seed and dash is considered as manifest name
$_localDownloadedRegex = "^$_applicationLookup-$_localAdditionalSeed.*\.($ALLOWED_MANIFEST_EXTENSION_REGEX)$"

function Get-LocalManifest {
    <#
    .SYNOPSIS
        Get "metadata" about local manifest with support for archived manifests.
    .PARAMETER Query
        Specifies the file path where manifest is stored.
    .PARAMETER Simple
        Specifies to return limited information about the resolved manifest.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param([Parameter(Mandatory, ValueFromPipeline)] [String] $Query, [Switch] $Simple)

    process {
        # TODO: Try to implement it without Get-Item, with regex approach
        # TODO: In this case the archived manifest regex could not work properly??
        $localPath = $reqVersion = $manifest = $null
        try {
            $localPath = Get-Item -LiteralPath $Query
        } catch {
            throw [ScoopException]::new("Cannot get file '$Query'")
        }

        $applicationName = $localPath.BaseName

        # Check if archived version was provided
        if ($localPath.FullName -match $_archivedManifestRegex) {
            $applicationName = $Matches['manifestName']
            $reqVersion = $Matches['manifestVersion']
        }
        # Check if downloaded manfiest was provided
        if ($localPath.Name -match $_localDownloadedRegex) {
            $applicationName = $Matches['app']
        }

        if (!$Simple) {
            try {
                $manifest = ConvertFrom-Manifest -LiteralPath $localPath.FullName
            } catch {
                throw [ScoopException]::new("File is not a valid manifest ($($_.Exception.Message))") # TerminatingError thrown
            }
        }

        return @{
            'Name'             = $applicationName
            'RequestedVersion' = $reqVersion
            'Manifest'         = $manifest
            'Path'             = $localPath
            'Print'            = $Query
        }
    }
}

function Get-RemoteManifest {
    <#
    .SYNOPSIS
        Download manifest from provided URL.
    .PARAMETER URL
        Specifies the URL pointing to manifest.
    .PARAMETER Simple
        Specifies to return limited information about the resolved manifest.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param([Parameter(Mandatory, ValueFromPipeline)] [String] $URL, [Switch] $Simple)

    process {
        # Parse name and extension from URL
        # TODO: Will this be enough? Consider more advanced approach
        $name = Split-Path $URL -Leaf
        $extension = ($name -split '\.')[-1]
        $name = $name -replace "\.($ALLOWED_MANIFEST_EXTENSION_REGEX)$"
        $requestedVersion = $null

        if ($URL -match $_archivedManifestRegex) {
            $name = $Matches['manifestName']
            $extension = $Matches['manifestExtension']
            $requestedVersion = $Matches['manifestVersion']
        }

        if ($Simple) {
            return @{
                'Name'             = $name
                'RequestedVersion' = $requestedVersion
                'Print'            = $URL
                'Manifest'         = $null
                'Path'             = $null
            }
        }

        $str = $null
        try {
            $wc = New-Object System.Net.Webclient
            $wc.Headers.Add('User-Agent', $SHOVEL_USERAGENT)
            $str = $wc.DownloadString($URL)
        } catch [System.Management.Automation.MethodInvocationException] {
            Write-UserMessage -Message "${URL}: $($_.Exception.InnerException.Message)" -Warning
        } catch {
            throw $_.Exception.Message
        }

        if (!$str) {
            throw [ScoopException]::new("'$URL' does not contain valid manifest") # TerminatingError thrown
        }

        Confirm-DirectoryExistence -Directory $SHOVEL_GENERAL_MANIFESTS_DIRECTORY | Out-Null

        $rand = "$_localAdditionalSeed$(Get-Random)-$(Get-Random)"
        $outName = "$name-$rand.$extension"
        $manifestFile = Join-Path $SHOVEL_GENERAL_MANIFESTS_DIRECTORY $outName

        # This use case should never happen. The probability should be really low.
        if (Test-Path $manifestFile) {
            # TODO: Consider while loop when it could be considered as real issue
            $new = "$name-$rand-$(Get-Random)"
            $manifestFile = Join-Path $SHOVEL_GENERAL_MANIFESTS_DIRECTORY "$new.$extension"

            Write-UserMessage -Message "Downloaded manifest file with name '$outName' already exists. Using '$new.$extension'." -Warning
        }

        Out-UTF8File -Path $manifestFile -Content $str
        $manifest = ConvertFrom-Manifest -Path $manifestFile

        return @{
            'Name'             = $name
            'Manifest'         = $manifest
            'Path'             = Get-Item -LiteralPath $manifestFile
            'RequestedVersion' = $requestedVersion
            'Print'            = $URL
        }
    }
}

function Get-ManifestFromLookup {
    <#
    .SYNOPSIS
        Lookup for manifest in all local buckets and return required information.
    .PARAMETER Query
        Specifies the lookup query.
    .PARAMETER Simple
        Specifies to return limited information about the resolved manifest.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param([Parameter(Mandatory, ValueFromPipeline)] [String] $Query, [Switch] $Simple)

    process {
        # Get all requested information
        $requestedBucket, $requestedName = $Query -split '/'
        if ($null -eq $requestedName) {
            $requestedName = $requestedBucket
            $requestedBucket = $null
        }
        $requestedName, $requestedVersion = $requestedName -split '@'
        $printableRepresentation = if ($requestedVersion) { "@$requestedVersion" } else { '' }

        if ($Simple) {
            return @{
                'Name'             = $requestedName
                'Bucket'           = $requestedBucket
                'RequestedVersion' = $requestedVersion
                'Print'            = "$requestedBucket/$requestedName$printableRepresentation"
                'Manifest'         = $null
                'Path'             = $null
            }
        }

        # Local manifest with specific name in all buckets
        $found = @()
        $buckets = Get-LocalBucket

        if ($requestedBucket -and ($requestedBucket -notin $buckets)) { throw [ScoopException]::new("'$requestedBucket' bucket cannot be found") }

        foreach ($b in $buckets) {
            $really = manifest_path $requestedName $b
            if ($really) {
                $found += @{
                    'Bucket' = $b
                    'Path'   = $really
                }
            }
        }

        # Pick the first one (as vanilla implementation)
        # TODO: Let user pick which bucket if there are more
        $valid = $found[0]
        if ($requestedBucket) { $valid = $found | Where-Object -Property 'Bucket' -EQ -Value $requestedBucket }

        if (!$valid) { throw [ScoopException]::new("No manifest found for '$Query'") }

        $manifestBucket = $valid.Bucket
        $manifestPath = $valid.Path

        # Select versioned manifest or generate it
        if ($requestedVersion) {
            try {
                $path = manifest_path -app $requestedName -bucket $manifestBucket -version $requestedVersion
                if ($null -eq $path) { throw 'trigger' }
                $manifestPath = $path
            } catch {
                $mess = if ($requestedBucket) { " in '$requestedBucket'" } else { '' }
                Write-UserMessage -Message "There is no archived version of manifest '$requestedName'$mes. Trying to generate the manifest" -Warning

                $generated = $null
                try {
                    $generated = New-VersionedManifest -Path $manifestPath -Version $requestedVersion
                } catch {
                    throw [ScoopException]::new($_.Exception.Message)
                }

                # This should not happen.
                if (!(Test-Path -LiteralPath $generated)) { throw [ScoopException]::new('Generated manifest cannot be found') }

                $manifestPath = $generated
            }
        }

        $name = $requestedName
        $manifest = $null
        try {
            $manifest = ConvertFrom-Manifest -LiteralPath $manifestPath
        } catch {
            throw [ScoopException]::new("'$manifestPath': Invalid manifest ($($_.Exception.Message))")
        }

        return @{
            'Name'             = $name
            'Bucket'           = $manifestBucket
            'RequestedVersion' = $requestedVersion
            'Print'            = "$manifestBucket/$name$printableRepresentation"
            'Manifest'         = $manifest
            'Path'             = (Get-Item -LiteralPath $manifestPath)
        }
    }
}
#endregion Resolve Helpers

function Resolve-ManifestInformation {
    <#
    .SYNOPSIS
        Find and parse manifest file according to search query. Return universal object with all relevant information about manifest.
    .PARAMETER ApplicationQuery
        Specifies the string used for looking for manifest.
    .PARAMETER Simple
        Specifies to return limited information about the resolved manifest.
    .EXAMPLE
        Resolve-ManifestInformation -ApplicationQuery 'pwsh'
        Resolve-ManifestInformation -ApplicationQuery 'pwsh@7.2.0'

        Resolve-ManifestInformation -ApplicationQuery 'Ash258/pwsh'
        Resolve-ManifestInformation -ApplicationQuery 'Ash258/pwsh@6.1.3'

        Resolve-ManifestInformation -ApplicationQuery '.\bucket\old\cosi\7.1.0.yaml'
        Resolve-ManifestInformation -ApplicationQuery '.\cosi.yaml'

        Resolve-ManifestInformation -ApplicationQuery 'https://raw.githubusercontent.com/Ash258/GithubActionsBucketForTesting/main/bucket/alfa.yaml'
        Resolve-ManifestInformation -ApplicationQuery 'https://raw.githubusercontent.com/Ash258/GithubActionsBucketForTesting/main/bucket/old/alfa/0.0.15-12060.yaml'
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory, ValueFromPipeline)] [String] $ApplicationQuery, [Switch] $Simple)

    process {
        $manifest = $applicationName = $applicationVersion = $requestedVersion = $bucket = $localPath = $url = $print = $calcBucket = $calcURL = $null

        if (Test-Path -LiteralPath $ApplicationQuery) {
            $res = Get-LocalManifest -Query $ApplicationQuery -Simple:$Simple
            $applicationName = $res.Name
            $applicationVersion = $res.Manifest.version
            $requestedVersion = $res.RequestedVersion
            $manifest = $res.Manifest
            $localPath = $res.Path
            $print = $res.Print
        } elseif ($ApplicationQuery -match '^https?://') {
            $res = Get-RemoteManifest -URL $ApplicationQuery -Simple:$Simple
            $applicationName = $res.Name
            $applicationVersion = $res.Manifest.version
            $requestedVersion = $res.RequestedVersion
            $manifest = $res.Manifest
            $localPath = $res.Path
            $url = $ApplicationQuery
            $print = $res.Print
        } elseif ($ApplicationQuery -match $_lookupRegex) {
            $res = Get-ManifestFromLookup -Query $ApplicationQuery -Simple:$Simple
            $applicationName = $res.Name
            $requestedVersion = $res.RequestedVersion
            $applicationVersion = $res.Manifest.version
            $manifest = $res.Manifest
            $localPath = $res.Path
            $bucket = $res.Bucket
            $print = $res.Print
        } else {
            throw 'Not supported way how to provide manifest'
        }

        debug $res

        # TODO: Validate manifest object
        if (!$Simple -and ($null -eq $manifest.version)) {
            debug $manifest
            throw [ScoopException]::new('Not a valid manifest') # TerminatingError thrown
        }

        return [Ordered] @{
            'ApplicationName'  = $applicationName
            'RequestedQuery'   = $ApplicationQuery
            'RequestedVersion' = $requestedVersion
            'Version'          = $applicationVersion
            'Bucket'           = $bucket
            'ManifestObject'   = $manifest
            'Url'              = $url
            'Print'            = $print
            'LocalPath'        = $localPath
            'CalculatedUrl'    = $calcURL
            'CalculatedBucket' = $calcBucket
            'Dependency'       = $false
        }
    }
}

function appname_from_url($url) { return (Split-Path $url -Leaf) -replace "\.($ALLOWED_MANIFEST_EXTENSION_REGEX)$" }

function manifest_path($app, $bucket, $version = $null) {
    $name = sanitary_path $app
    $buc = Find-BucketDirectory -Bucket $bucket
    $path = $file = $null

    try {
        $file = Get-ChildItem -LiteralPath $buc -Filter "$name.*" -ErrorAction 'Stop'
    } catch {
        return $path
    }

    if ($file) {
        if ($file.Count -gt 1) { $file = $file[0] }
        $path = $file.FullName

        # Look for archived version only if manifest exists
        if ($version) {
            $path = $null
            $versions = @()

            try {
                $versions = Get-ChildItem -LiteralPath "$buc\old\$name" -Filter "$version.*" -ErrorAction 'Stop'
            } catch {
                throw [ScoopException]::new("Bucket '$bucket' does not contain archived version '$version' for '$app'")
            }

            if ($versions.Count -gt 1) { $versions = $versions[0] }

            $path = $versions.FullName
        }
    }

    return $path
}

function parse_json {
    param([Parameter(Mandatory, ValueFromPipeline)] [System.IO.FileInfo] $Path)

    process {
        if (!(Test-Path $Path)) { return $null }

        return Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
}

function url_manifest($url) {
    $str = $null
    try {
        $wc = New-Object System.Net.Webclient
        $wc.Headers.Add('User-Agent', $SHOVEL_USERAGENT)
        $str = $wc.DownloadString($url)
    } catch [System.Management.Automation.MethodInvocationException] {
        Write-UserMessage -Message "${url}: $($_.Exception.InnerException.Message)" -Warning
    } catch {
        throw $_.Exception.Message
    }
    if (!$str) { return $null }

    # TODO: YAML
    return $str | ConvertFrom-Json
}

function manifest($app, $bucket, $url) {
    if ($url) { return url_manifest $url }

    $path = manifest_path $app $bucket
    try {
        $manifest = ConvertFrom-Manifest -Path $path
    } catch {
        $manifest = $null
    }

    return $manifest
}

function installed_manifest($app, $version, $global) {
    $d = versiondir $app $version $global

    #region Migration from non-generic file name
    $new = 'scoop-manifest.json'
    $old = 'manifest.json'
    $manifestPath = Join-Path $d $new
    $oldManifestPath = Join-Path $d $old

    if (!(Test-Path -LiteralPath $manifestPath -PathType 'Leaf') -and (Test-Path -LiteralPath $oldManifestPath -PathType 'Leaf')) {
        Write-UserMessage -Message "[$app] Migrating $old to $new" -Info
        debug $oldManifestPath
        Rename-Item -LiteralPath $oldManifestPath -NewName $new
    }
    #endregion Migration from non-generic file name

    # Different extension types
    if (!(Test-Path -LiteralPath $manifestPath -PathType 'Leaf')) {
        $installedManifests = @(Get-ChildItem "$d\scoop-manifest.*" -ErrorAction 'SilentlyContinue')
        if ($installedManifests.Count -gt 0) {
            $manifestPath = $installedManifests[0].FullName
        }
    }

    return ConvertFrom-Manifest -Path $manifestPath
}

# TODO: Deprecate
function install_info($app, $version, $global) {
    $d = versiondir $app $version $global
    $path = Join-Path $d 'scoop-install.json'
    $oldPath = Join-Path $d 'install.json'

    if (!(Test-Path -LiteralPath $path -PathType 'Leaf')) {
        if (Test-Path -LiteralPath $oldPath -PathType 'Leaf') {
            Write-UserMessage -Message "[$app] Migrating install.json to scoop-install.json" -Info
            debug $oldPath
            Rename-Item -LiteralPath $oldPath -NewName 'scoop-install.json'
        } else {
            return $null
        }
    }

    return parse_json $path
}

function default_architecture {
    $arch = get_config 'default-architecture'
    $system = if ([System.IntPtr]::Size -eq 8) { '64bit' } else { '32bit' }

    if ($SHOVEL_IS_ARM_ARCH) { $arch = 'arm' + ($system -replace 'bit') }

    if ($null -eq $arch) {
        $arch = $system
    } else {
        try {
            $arch = ensure_architecture $arch
        } catch {
            Write-UserMessage -Message 'Invalid default architecture configured. Determining default system architecture' -Warning
            $arch = $system
        }
    }

    return $arch
}

function arch_specific($prop, $manifest, $architecture) {
    if ($manifest.architecture) {
        $val = $manifest.architecture.$architecture.$prop
        if ($val) { return $val } # else fallback to generic prop
    }

    if ($manifest.$prop) { return $manifest.$prop }
}

function supports_architecture($manifest, $architecture) {
    return -not [String]::IsNullOrEmpty((arch_specific 'url' $manifest $architecture))
}

function Invoke-ManifestScript {
    <#
    .SYNOPSIS
        Execute script properties defined in manifest.
    .PARAMETER Manifest
        Specifies the manifest object.
    .PARAMETER ScriptName
        Specifies the property name.
    .PARAMETER Architecture
        Specifies the architecture.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [Alias('InputObject')]
        $Manifest,
        [Parameter(Mandatory)]
        [String] $ScriptName,
        [String] $Architecture
    )

    process {
        $script = arch_specific $ScriptName $Manifest $Architecture
        if (!$script) { return }

        $print = $ScriptName -replace '_', '-'
        Write-UserMessage -Message "Running $print script..." -Output:$false
        Invoke-Expression (@($script) -join "`r`n")
    }
}

function url($manifest, $arch) { arch_specific 'url' $manifest $arch }
function installer($manifest, $arch) { arch_specific 'installer' $manifest $arch }
function uninstaller($manifest, $arch) { arch_specific 'uninstaller' $manifest $arch }
function msi($manifest, $arch) { arch_specific 'msi' $manifest $arch }
function hash($manifest, $arch) { arch_specific 'hash' $manifest $arch }
function extract_dir($manifest, $arch) { arch_specific 'extract_dir' $manifest $arch }
function extract_to($manifest, $arch) { arch_specific 'extract_to' $manifest $arch }
