. "$PSScriptRoot\Helpers.ps1"

function Get-AbsolutePath {
    <#
    .SYNOPSIS
        Gets absolute path.
    .PARAMETER Path
        Specifies the path to evaluate.
    .OUTPUTS
        System.String
            Absolute path, may or maynot existed.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    param([Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)] [String] $Path)

    process { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
}

function Show-DeprecatedWarning {
    <#
    .SYNOPSIS
        Print deprecated warning for functions, which will be deleted in near future.
    .PARAMETER Invocation
        Invocation to identify location of line.
        Just pass $MyInvocation.
    .PARAMETER New
        New command name.
    #>
    [CmdletBinding()]
    param($Invocation, [Parameter(ValueFromPipeline)] [String] $New)

    process {
        Write-UserMessage -Message ('"{0}" will be deprecated. Please change your code/manifest to use "{1}"' -f $Invocation.MyCommand.Name, $New) -Warning
        Write-UserMessage -Message "      -> $($Invocation.PSCommandPath):$($Invocation.ScriptLineNumber):$($Invocation.OffsetInLine)" -Color DarkGray
    }
}

function Optimize-SecurityProtocol {
    # .NET Framework 4.7+ has a default security protocol called 'SystemDefault',
    # which allows the operating system to choose the best protocol to use.
    # If SecurityProtocolType contains 'SystemDefault' (means .NET4.7+ detected)
    # and the value of SecurityProtocol is 'SystemDefault', just do nothing on SecurityProtocol,
    # 'SystemDefault' will use TLS 1.2 if the webrequest requires.
    $isNewerNetFramework = ([System.Enum]::GetNames([System.Net.SecurityProtocolType]) -contains 'SystemDefault')
    $isSystemDefault = ([System.Net.ServicePointManager]::SecurityProtocol.Equals([System.Net.SecurityProtocolType]::SystemDefault))

    # If not, change it to support TLS 1.2
    if (!($isNewerNetFramework -and $isSystemDefault)) {
        # Set to TLS 1.2 (3072), then TLS 1.1 (768), and TLS 1.0 (192). Ssl3 has been superseded,
        # https://docs.microsoft.com/en-us/dotnet/api/system.net.securityprotocoltype?view=netframework-4.5
        [System.Net.ServicePointManager]::SecurityProtocol = 3072 -bor 768 -bor 192
    }
}

function Get-UserAgent {
    return "Scoop/1.0 (+http://scoop.sh/) PowerShell/$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor) (Windows NT $([System.Environment]::OSVersion.Version.Major).$([System.Environment]::OSVersion.Version.Minor); $(if($env:PROCESSOR_ARCHITECTURE -eq 'AMD64'){'Win64; x64; '})$(if($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64'){'WOW64; '})$PSEdition)"
}

function load_cfg($file) {
    if (!(Test-Path $file)) { return $null }

    try {
        return (Get-Content $file -Raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-UserMessage -Message "Loading ${file}: $($_.Exception.Message)" -Err
    }
}

function get_config($name, $default) {
    if ($null -eq $scoopConfig.$name -and $null -ne $default) { return $default }

    return $scoopConfig.$name
}

function set_config($name, $value) {
    if ($null -eq $scoopConfig -or $scoopConfig.Count -eq 0) {
        ensure (Split-Path -Path $configFile) | Out-Null
        $scoopConfig = New-Object PSObject
        $scoopConfig | Add-Member -MemberType NoteProperty -Name $name -Value $value
    } else {
        if ($value -eq [bool]::TrueString -or $value -eq [bool]::FalseString) {
            $value = [System.Convert]::ToBoolean($value)
        }
        if ($null -eq $scoopConfig.$name) {
            $scoopConfig | Add-Member -MemberType NoteProperty -Name $name -Value $value
        } else {
            $scoopConfig.$name = $value
        }
    }

    if ($null -eq $value) { $scoopConfig.PSObject.Properties.Remove($name) }

    ConvertTo-Json $scoopConfig | Set-Content $configFile -Encoding ASCII

    return $scoopConfig
}

function setup_proxy() {
    # note: '@' and ':' in password must be escaped, e.g. 'p@ssword' -> p\@ssword'
    $proxy = get_config 'proxy'
    if (!$proxy) { return }

    try {
        $credentials, $address = $proxy -split '(?<!\\)@'
        if (!$address) {
            $address, $credentials = $credentials, $null # no credentials supplied
        }

        if ($address -eq 'none') {
            [System.System.Net.WebRequest]::DefaultWebProxy = $null
        } elseif ($address -ne 'default') {
            [System.Net.WebRequest]::DefaultWebProxy = New-Object System.Net.WebProxy "http://$address"
        }

        if ($credentials -eq 'currentuser') {
            [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
        } elseif ($credentials) {
            $username, $password = $credentials -split '(?<!\\):' | ForEach-Object { $_ -replace '\\([@:])', '$1' }
            [System.Net.WebRequest]::DefaultWebProxy.Credentials = New-Object System.Net.NetworkCredential($username, $password)
        }
    } catch {
        Write-UserMessage -Message "Failed to use proxy '$proxy': $($_.Exception.Message)" -Warning
    }
}

# helper functions
function coalesce($a, $b) { if ($a) { return $a } $b }

function format($str, $hash) {
    $hash.keys | ForEach-Object { Set-Variable $_ $hash[$_] }

    $executionContext.InvokeCommand.ExpandString($str)
}
function is_admin {
    $admin = [Security.Principal.WindowsBuiltInRole]::Administrator
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()

    return ([Security.Principal.WindowsPrincipal]($id)).IsInRole($admin)
}

# messages
function abort($msg, [int] $exit_code = 1) { Write-Host $msg -ForegroundColor Red; exit $exit_code }
function error($msg) { Write-Host "ERROR $msg" -ForegroundColor DarkRed }
function warn($msg) { Write-Host "WARN  $msg" -ForegroundColor DarkYellow }
function info($msg) { Write-Host "INFO  $msg" -ForegroundColor DarkGray }
function message($msg) { Write-Host "$msg" }

function Test-ScoopDebugEnabled {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $configDebug = (get_config 'debug' $false) -eq [bool]::TrueString
    $envDebug = $env:SCOOP_DEBUG
    $envDebug = ([bool] $envDebug) -or (($envDebug -eq [bool]::TrueString) -or ($envDebug -eq 1))

    return $configDebug -or $envDebug
}

function debug($obj) {
    if (!(Test-ScoopDebugEnabled)) { return }

    $prefix = "DEBUG[$(Get-Date -UFormat %s)]"
    $param = $MyInvocation.Line.Replace($MyInvocation.InvocationName, '').Trim()
    $msg = $obj | Out-String -Stream

    if ($null -eq $obj -or $null -eq $msg) {
        Write-Host "$prefix $param = " -ForegroundColor DarkCyan -NoNewline
        Write-Host '$null' -ForegroundColor DarkYellow -NoNewline
        Write-Host " -> $($MyInvocation.PSCommandPath):$($MyInvocation.ScriptLineNumber):$($MyInvocation.OffsetInLine)" -ForegroundColor DarkGray
        return
    }

    if ($msg.GetType() -eq [System.Object[]]) {
        Write-Host "$prefix $param ($($obj.GetType()))" -ForegroundColor DarkCyan -NoNewline
        Write-Host " -> $($MyInvocation.PSCommandPath):$($MyInvocation.ScriptLineNumber):$($MyInvocation.OffsetInLine)" -ForegroundColor DarkGray
        $msg | Where-Object { ![String]::IsNullOrWhiteSpace($_) } |
        Select-Object -Skip 2 | # Skip headers
        ForEach-Object {
            Write-Host "$prefix $param.$($_)" -ForegroundColor DarkCyan
        }
    } else {
        Write-Host "$prefix $param = $($msg.Trim())" -ForegroundColor DarkCyan -NoNewline
        Write-Host " -> $($MyInvocation.PSCommandPath):$($MyInvocation.ScriptLineNumber):$($MyInvocation.OffsetInLine)" -ForegroundColor DarkGray
    }
}

function success($msg) { Write-Host $msg -ForegroundColor DarkGreen }

function filesize($length) {
    $gb = [Math]::Pow(2, 30)
    $mb = [Math]::Pow(2, 20)
    $kb = [Math]::Pow(2, 10)

    $res = "$($length) B"
    if ($length -gt $gb) {
        $res = "{0:n1} GB" -f ($length / $gb)
    } elseif ($length -gt $mb) {
        $res = "{0:n1} MB" -f ($length / $mb)
    } elseif ($length -gt $kb) {
        $res = "{0:n1} KB" -f ($length / $kb)
    }

    return $res
}

# dirs
function basedir($global) { if ($global) { return $globaldir } else { return $scoopdir } }
function appsdir($global) { return "$(basedir $global)\apps" }
function shimdir($global) { return "$(basedir $global)\shims" }
function appdir($app, $global) { return "$(appsdir $global)\$app" }
function versiondir($app, $version, $global) { return "$(appdir $app $global)\$version" }
function persistdir($app, $global) { return "$(basedir $global)\persist\$app" }
function usermanifestsdir { return "$(basedir)\workspace" }
function usermanifest($app) { return "$(usermanifestsdir)\$app.json" }
function cache_path($app, $version, $url) { return "$cachedir\$app#$version#$($url -replace '[^\w\.\-]+', '_')" }

# apps
function sanitary_path($path) { return [Regex]::Replace($path, '[/\\?:*<>|]', '') }

function installed($app, $global = $null) {
    if ($null -eq $global) { return (installed $app $true) -or (installed $app $false) }
    # Dependencies of the format "bucket/dependency" install in a directory of form
    # "dependency". So we need to extract the bucket from the name and only give the app
    # name to is_directory
    $app = $app.split('/')[-1]

    return is_directory (appdir $app $global)
}

function installed_apps($global) {
    $dir = appsdir $global

    if (Test-Path $dir) { return (Get-ChildItem $dir -Directory | Where-Object { $_.Name -ne 'scoop' }).Name }
}

function Get-AppFilePath {
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [String] $App,
        [Parameter(Mandatory, Position = 1)]
        [String] $File
    )

    process {
        # Normal path to file
        $path = "$(versiondir $App 'current' $false)\$File"
        if (Test-Path $path) { return $path }

        # Global path to file
        $path = "$(versiondir $App 'current' $true)\$File"
        if (Test-Path $path) { return $path }

        # not found
        return $null
    }
}

Function Test-CommandAvailable {
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param ([Parameter(ValueFromPipeline)] [Alias('Command')] [String] $Name)

    process { return [bool](Get-Command $Name -ErrorAction Ignore) }
}

function Get-HelperPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [ValidateSet('7zip', 'Lessmsi', 'Innounp', 'Dark', 'Aria2')]
        [String] $Helper
    )

    process {
        $helperPath = $null
        switch ($Helper) {
            'Aria2' { $helperPath = Get-AppFilePath 'aria2' 'aria2c.exe' }
            'Innounp' { $helperPath = Get-AppFilePath 'innounp' 'innounp.exe' }
            'Lessmsi' { $helperPath = Get-AppFilePath 'lessmsi' 'lessmsi.exe' }
            '7zip' {
                $helperPath = Get-AppFilePath '7zip' '7z.exe'
                if ([String]::IsNullOrEmpty($helperPath)) { $helperPath = Get-AppFilePath '7zip-zstd' '7z.exe' }
            }
            'Dark' {
                $helperPath = Get-AppFilePath 'dark' 'dark.exe'
                if ([String]::IsNullOrEmpty($helperPath)) { $helperPath = Get-AppFilePath 'wixtoolset' 'dark.exe' }
            }
        }

        return $helperPath
    }
}

function Test-HelperInstalled {
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [ValidateSet('7zip', 'Lessmsi', 'Innounp', 'Dark', 'Aria2')]
        [String] $Helper
    )

    return ![String]::IsNullOrWhiteSpace((Get-HelperPath -Helper $Helper))
}

function Test-Aria2Enabled {
    return (Test-HelperInstalled -Helper Aria2) -and (get_config 'aria2-enabled' $true)
}

function app_status($app, $global) {
    $status = @{ }
    $status.installed = (installed $app $global)
    $status.version = Select-CurrentVersion -AppName $app -Global:$global
    $status.latest_version = $status.version

    $install_info = install_info $app $status.version $global

    $status.failed = (!$install_info -or !$status.version)
    $status.hold = ($install_info.hold -eq $true)

    $manifest = manifest $app $install_info.bucket $install_info.url
    $status.removed = (!$manifest)
    if ($manifest.version) {
        $status.latest_version = $manifest.version
    }

    $status.outdated = $false
    if ($status.version -and $status.latest_version) {
        $status.outdated = (Compare-Version -ReferenceVersion $status.version -DifferenceVersion $status.latest_version) -ne 0
    }

    $status.missing_deps = @()
    $deps = @(runtime_deps $manifest) | Where-Object {
        $app, $bucket, $null = parse_app $_
        return !(installed $app)
    }
    if ($deps) {
        $status.missing_deps += , $deps
    }

    return $status
}

function appname_from_url($url) { return (Split-Path $url -Leaf) -replace '.json$', '' }

# paths
function fname($path) { return Split-Path $path -Leaf }

function strip_ext($fname) { return $fname -replace '\.[^\.]*$', '' }

function strip_filename($path) { return $path -replace [Regex]::Escape((fname $path)) }

function strip_fragment($url) { return $url -replace (New-Object uri $url).Fragment }

function url_filename($url) { return (Split-Path $url -Leaf).split('?') | Select-Object -First 1 }

# Unlike url_filename which can be tricked by appending a
# URL fragment (e.g. #/dl.7z, useful for coercing a local filename),
# this function extracts the original filename from the URL.
function url_remote_filename($url) {
    $uri = (New-Object URI $url)
    $basename = Split-Path $uri.PathAndQuery -Leaf
    if ($basename -match '.*[?=]+([\w._-]+)') {
        $basename = $matches[1]
    }
    if (($basename -notlike '*.*') -or ($basename -match '^[v.\d]+$')) {
        $basename = Split-Path $uri.AbsolutePath -Leaf
    }
    if (($basename -notlike '*.*') -and ($uri.Fragment -ne '')) {
        $basename = $uri.Fragment.Trim('/', '#')
    }

    return $basename
}

function ensure($dir) {
    if (!(Test-Path $dir)) { New-Item -Path $dir -ItemType Directory | Out-Null }

    return Resolve-Path $dir
}

function relpath($path) { return "$($MyInvocation.PSScriptRoot)\$path" } # relative to calling script

function friendly_path($path) {
    $h = (Get-PSProvider 'FileSystem').Home
    if (!$h.EndsWith('\')) { $h += '\' }
    if ($h -eq '\') { return $path }

    return "$path" -replace ([Regex]::Escape($h)), '~\'
}

function is_local($path) { return ($path -notmatch '^https?://') -and (Test-Path $path) }

# operations

function Invoke-ExternalCommand {
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    [OutputType([Boolean])]
    param (
        [Parameter(Mandatory, Position = 0)]
        [Alias('Path')]
        [ValidateNotNullOrEmpty()]
        [String] $FilePath,
        [Parameter(Position = 1)]
        [Alias('Args')]
        [String[]] $ArgumentList,
        [Parameter(ParameterSetName = 'UseShellExecute')]
        [Switch] $RunAs,
        [Alias('Msg')]
        [String] $Activity,
        [Alias('cec')]
        [Hashtable] $ContinueExitCodes,
        [Parameter(ParameterSetName = 'Default')]
        [Alias('Log')]
        [String] $LogPath
    )
    if ($Activity) { Write-Host "$Activity " -NoNewline }

    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo.FileName = $FilePath
    $Process.StartInfo.Arguments = ($ArgumentList | Select-Object -Unique) -join ' '
    $Process.StartInfo.UseShellExecute = $false
    if ($LogPath) {
        if ($FilePath -match '(^|\W)msiexec($|\W)') {
            $Process.StartInfo.Arguments += " /lwe `"$LogPath`""
        } else {
            $Process.StartInfo.RedirectStandardOutput = $true
            $Process.StartInfo.RedirectStandardError = $true
        }
    }
    if ($RunAs) {
        $Process.StartInfo.UseShellExecute = $true
        $Process.StartInfo.Verb = 'RunAs'
    }
    try {
        $Process.Start() | Out-Null
    } catch {
        if ($Activity) { Write-UserMessage -Message 'error.' -Color DarkRed }
        Write-UserMessage -Message $_.Exception.Message -Err
        return $false
    }
    if ($LogPath -and ($FilePath -notmatch '(^|\W)msiexec($|\W)')) {
        Out-File -FilePath $LogPath -Encoding ASCII -Append -InputObject $Process.StandardOutput.ReadToEnd()
    }
    $Process.WaitForExit()
    if ($Process.ExitCode -ne 0) {
        if ($ContinueExitCodes -and ($ContinueExitCodes.ContainsKey($Process.ExitCode))) {
            if ($Activity) { Write-UserMessage -Message 'done.' -Color DarkYellow }
            Write-UserMessage -Message $ContinueExitCodes[$Process.ExitCode] -Warning

            return $true
        } else {
            if ($Activity) { Write-UserMessage -Message 'error.' -Color DarkRed }
            Write-UserMessage -Message "Exit code was $($Process.ExitCode)!" -Err
            return $false
        }
    }
    if ($Activity) { Write-UserMessage -Message 'done.' -Color Green }

    return $true
}

function dl($url, $to) {
    $wc = New-Object Net.Webclient
    $wc.headers.add('Referer', (strip_filename $url))
    $wc.Headers.Add('User-Agent', (Get-UserAgent))
    $wc.downloadFile($url, $to)
}

function env($name, $global, $val = '__get') {
    $target = if ($global) { 'Machine' } else { 'User' }

    if ($val -eq '__get') {
        [Environment]::GetEnvironmentVariable($name, $target)
    } else {
        [Environment]::SetEnvironmentVariable($name, $val, $target)
    }
}

function isFileLocked([string]$path) {
    $file = New-Object System.IO.FileInfo $path

    if (!(Test-Path -Path $path)) { return $false }

    try {
        $stream = $file.Open([System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        if ($stream) { $stream.Close() }

        return $false
    } catch {
        # file is locked by a process.
        return $true
    }
}

function is_directory([String] $path) {
    return (Test-Path $path) -and ((Get-Item $path) -is [System.IO.DirectoryInfo])
}

function movedir($from, $to) {
    $from = $from.trimend('\')
    $to = $to.trimend('\')

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo.FileName = 'robocopy.exe'
    $proc.StartInfo.Arguments = "`"$from`" `"$to`" /e /move"
    $proc.StartInfo.RedirectStandardOutput = $true
    $proc.StartInfo.RedirectStandardError = $true
    $proc.StartInfo.UseShellExecute = $false
    $proc.StartInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $proc.Start()
    $out = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()

    if ($proc.ExitCode -ge 8) {
        debug $out
        throw "Could not find '$(fname $from)'! (error $($proc.ExitCode))"
    }

    # wait for robocopy to terminate its threads
    1..10 | ForEach-Object {
        if (Test-Path $from) { Start-Sleep -Milliseconds 100 }
    }
}

function get_app_name($path) {
    $result = ''
    if ($path -match '([^/\\]+)[/\\]current[/\\]') { $result = $matches[1].Tolower() }

    return $result
}

function get_app_name_from_ps1_shim($shim_ps1) {
    if (!(Test-Path $shim_ps1)) { return '' }
    $content = (Get-Content $shim_ps1 -Encoding utf8) -join ' '

    return get_app_name $content
}

function warn_on_overwrite($shim_ps1, $path) {
    if (!(Test-Path $shim_ps1)) { return }
    $shim_app = get_app_name_from_ps1_shim $shim_ps1
    $path_app = get_app_name $path
    if ($shim_app -eq $path_app) { return }

    $filename = [System.IO.Path]::GetFileName($path)
    Write-UserMessage -Message "Overwriting shim to $filename installed from $shim_app" -Warning
}

function shim($path, $global, $name, $arg) {
    if (!(Test-Path $path)) { abort "Can't shim '$(fname $path)': couldn't find '$path'." }
    $abs_shimdir = ensure (shimdir $global)
    if (!$name) { $name = strip_ext (fname $path) }

    $shim = "$abs_shimdir\$($name.tolower())"

    warn_on_overwrite "$shim.ps1" $path

    # convert to relative path
    Push-Location $abs_shimdir
    $relative_path = Resolve-Path $path -Relative
    Pop-Location
    $resolved_path = Resolve-Path $path

    # if $path points to another drive resolve-path prepends .\ which could break shims
    if ($relative_path -match "^(.\\[\w]:).*$") {
        Write-Output "`$path = `"$path`"" | Out-File "$shim.ps1" -encoding utf8
    } else {
        # Setting PSScriptRoot in Shim if it is not defined, so the shim doesn't break in PowerShell 2.0
        Write-Output "if (!(Test-Path Variable:PSScriptRoot)) { `$PSScriptRoot = Split-Path `$MyInvocation.MyCommand.Path -Parent }" | Out-File "$shim.ps1" -Encoding utf8
        Write-Output "`$path = join-path `"`$PSScriptRoot`" `"$relative_path`"" | Out-File "$shim.ps1" -Encoding utf8 -Append
    }

    if ($path -match '\.jar$') {
        "if(`$myinvocation.expectingInput) { `$input | & java -jar `$path $arg @args } else { & java -jar `$path $arg @args }" | Out-File "$shim.ps1" -encoding utf8 -append
    } else {
        "if(`$myinvocation.expectingInput) { `$input | & `$path $arg @args } else { & `$path $arg @args }" | Out-File "$shim.ps1" -encoding utf8 -append
    }

    if ($path -match '\.(exe|com)$') {
        # for programs with no awareness of any shell
        Copy-Item "$(versiondir 'scoop' 'current')\supporting\shimexe\bin\shim.exe" "$shim.exe" -force
        Write-Output "path = $resolved_path" | Out-File "$shim.shim" -encoding utf8
        if ($arg) {
            Write-Output "args = $arg" | Out-File "$shim.shim" -encoding utf8 -append
        }
    } elseif ($path -match '\.(bat|cmd)$') {
        # shim .bat, .cmd so they can be used by programs with no awareness of PSH
        "@`"$resolved_path`" $arg %*" | Out-File "$shim.cmd" -encoding ascii

        "#!/bin/sh`nMSYS2_ARG_CONV_EXCL=/C cmd.exe /C `"$resolved_path`" $arg `"$@`"" | Out-File $shim -encoding ascii
    } elseif ($path -match '\.ps1$') {
        # make ps1 accessible from cmd.exe
        "@echo off
setlocal enabledelayedexpansion
set args=%*
:: replace problem characters in arguments
set args=%args:`"='%
set args=%args:(=``(%
set args=%args:)=``)%
set invalid=`"='
if !args! == !invalid! ( set args= )
powershell -noprofile -ex unrestricted `"& '$resolved_path' $arg %args%;exit `$lastexitcode`"" | Out-File "$shim.cmd" -encoding ascii

        "#!/bin/sh`npowershell.exe -noprofile -ex unrestricted `"$resolved_path`" $arg `"$@`"" | Out-File $shim -encoding ascii
    } elseif ($path -match '\.jar$') {
        "@java -jar `"$resolved_path`" $arg %*" | Out-File "$shim.cmd" -encoding ascii
        "#!/bin/sh`njava -jar `"$resolved_path`" $arg `"$@`"" | Out-File $shim -encoding ascii
    }
}

function search_in_path($target) {
    $path = (env 'PATH' $false) + ";" + (env 'PATH' $true)
    foreach ($dir in $path.split(';')) {
        if (Test-Path "$dir\$target" -PathType Leaf) { return "$dir\$target" }
    }
}

function ensure_in_path($dir, $global) {
    $path = env 'PATH' $global
    if ($path -notmatch [regex]::escape($dir)) {
        Write-UserMessage -Message "Adding $(friendly_path $dir) to $(if($global){'global'}else{'your'}) path."

        env 'PATH' $global "$dir;$path" # for future sessions...
        $env:PATH = "$dir;$env:PATH" # for this session
    }
}

function ensure_architecture($architecture_opt) {
    if (!$architecture_opt) { return default_architecture }

    $architecture_opt = $architecture_opt.ToString().ToLower()
    switch ($architecture_opt) {
        { @('64bit', '64', 'x64', 'amd64', 'x86_64', 'x86-64') -contains $_ } { return '64bit' }
        { @('32bit', '32', 'x86', 'i386', '386', 'i686') -contains $_ } { return '32bit' }
        default { throw [System.ArgumentException] "Invalid architecture: '$architecture_opt'" }
    }
}

function Confirm-InstallationStatus {
    <#
    .SYNOPSIS
        Test application's installation status
    .PARAMETER Apps
        Specifies application to check.
    .PARAMETER Global
        Specifies globally installed application.
    #>
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory)]
        [String[]] $Apps,
        [Switch] $Global
    )

    begin { $installed = @() }

    process {
        $Apps | Select-Object -Unique | Where-Object { $_.Name -ne 'scoop' } | ForEach-Object {
            $app, $null, $null = parse_app $_
            if ($Global) {
                if (installed $app $true) {
                    $installed += , @($app, $true)
                } elseif (installed $app $false) {
                    Write-UserMessage -Message "'$app' isn't installed globally, but it is installed for your account." -Err
                    Write-UserMessage -Message "Try again without the --global (or -g) flag instead." -Warning
                } else {
                    Write-UserMessage -Message "'$app' isn't installed." -Err
                }
            } else {
                if (installed $app $false) {
                    $installed += , @($app, $false)
                } elseif (installed $App $true) {
                    Write-UserMessage -Message "'$app' isn't installed for your account, but it is installed globally." -Err
                    Write-UserMessage -Message "Try again with the --global (or -g) flag instead." -Warning
                } else {
                    Write-UserMessage -Message "'$app' isn't installed." -Err
                }
            }
        }
    }

    end { return , $installed }
}

function strip_path($orig_path, $dir) {
    if ($null -eq $orig_path) { $orig_path = '' }
    $stripped = [String]::Join(';', @( $orig_path.split(';') | Where-Object { $_ -and $_ -ne $dir } ))

    return ($stripped -ne $orig_path), $stripped
}

function add_first_in_path($dir, $global) {
    # Future sessions
    $null, $currpath = strip_path (env 'path' $global) $dir
    env 'path' $global "$dir;$currpath"

    # This session
    $null, $env:PATH = strip_path $env:PATH $dir
    $env:PATH = "$dir;$env:PATH"
}

function remove_from_path($dir, $global) {
    # Future sessions
    $was_in_path, $newpath = strip_path (env 'path' $global) $dir
    if ($was_in_path) {
        Write-UserMessage -Message "Removing $(friendly_path $dir) from your path."
        env 'path' $global $newpath
    }

    # Current session
    $was_in_path, $newpath = strip_path $env:PATH $dir
    if ($was_in_path) { $env:PATH = $newpath }
}

function ensure_scoop_in_path($global) {
    $abs_shimdir = ensure (shimdir $global)
    # be aggressive (b-e-aggressive) and install scoop first in the path
    ensure_in_path $abs_shimdir $global
}

function ensure_robocopy_in_path {
    if (!(Test-CommandAvailable robocopy)) { shim "C:\Windows\System32\Robocopy.exe" $false }
}

function wraptext($text, $width) {
    if (!$width) { $width = $host.ui.rawui.buffersize.width };
    $width -= 1 # be conservative: doesn't seem to print the last char

    $text -split '\r?\n' | ForEach-Object {
        $line = ''
        $_ -split ' ' | ForEach-Object {
            if ($line.length -eq 0) { $line = $_ }
            elseif ($line.length + $_.length + 1 -le $width) { $line += " $_" }
            else { $lines += , $line; $line = $_ }
        }
        $lines += , $line
    }

    $lines -join "`n"
}

function pluralize($count, $singular, $plural) {
    $word = if ($count -eq 1) { $singular } else { $plural }

    return $word
}

function reset_alias($name, $value) {
    if ($existing = Get-Alias -Name $name -ErrorAction Ignore | Where-Object { $_.Options -match 'readonly' }) {
        if ($existing.Definition -ne $value) { Write-UserMessage -Message "Alias $name is read-only; can't reset it." -Color DarkYellow }
        return # already set
    }
    if ($value -is [scriptblock]) {
        if (!(Test-Path "function:script:$name")) { New-Item -Path function: -Name "script:$name" -Value $value | Out-Null }
        return
    }

    Set-Alias -Name $name -Value $value -Scope Script -Option AllScope
}

function reset_aliases() {
    # for aliases where there's a local function, re-alias so the function takes precedence
    $aliases = Get-Alias | Where-Object { $_.options -notmatch 'readonly|allscope' } | ForEach-Object { $_.name }
    Get-ChildItem function: | ForEach-Object {
        $fn = $_.name
        if ($aliases -contains $fn) { Set-Alias $fn local:$fn -Scope Script }
    }

    # for dealing with user aliases
    $default_aliases = @{
        'cp'     = 'copy-item'
        'echo'   = 'write-output'
        'gc'     = 'get-content'
        'gci'    = 'get-childitem'
        'gcm'    = 'get-command'
        'gm'     = 'get-member'
        'iex'    = 'invoke-expression'
        'ls'     = 'get-childitem'
        'mkdir'  = { New-Item -Type Directory @args }
        'mv'     = 'move-item'
        'rm'     = 'remove-item'
        'sc'     = 'set-content'
        'select' = 'select-object'
        'sls'    = 'select-string'
    }

    # set default aliases
    $default_aliases.keys | ForEach-Object { reset_alias $_ $default_aliases[$_] }
}

# convert list of apps to list of ($app, $global) tuples
function applist($apps, $global) {
    if (!$apps) { return @() }

    return , @($apps | ForEach-Object { , @($_, $global) })
}

function parse_app([string] $app) {
    if ($app -match '(?:(?<bucket>[a-zA-Z0-9-]+)\/)?(?<app>.*.json$|[a-zA-Z0-9-_.]+)(?:@(?<version>.*))?') {
        return $matches['app'], $matches['bucket'], $matches['version']
    }

    return $app, $null, $null
}

function show_app($app, $bucket, $version) {
    if ($bucket) { $app = "$bucket/$app" }
    if ($version) { $app = "$app@$version" }

    return $app
}

function last_scoop_update {
    # PowerShell 6 returns an DateTime Object
    # FIXME
    $lastUpdate = scoop config 'lastupdate'

    if (($null -ne $lastUpdate) -and ($lastUpdate.GetType() -eq [System.String])) {
        try {
            $lastUpdate = [System.DateTime]::Parse($lastUpdate)
        } catch {
            $lastUpdate = $null
        }
    }

    return $lastUpdate
}

function is_scoop_outdated {
    $lastUpdate = last_scoop_update
    $now = [System.DateTime]::Now

    if ($null -eq $lastUpdate) {
        # FIXME
        scoop config 'lastupdate' $now.ToString('o')
        # enforce an update for the first time
        return $true
    }

    return $lastUpdate.AddHours(3) -lt $now.ToLocalTime()
}

function substitute($entity, [Hashtable] $params, [Bool]$regexEscape = $false) {
    if ($entity -is [Array]) {
        return $entity | ForEach-Object { substitute $_ $params $regexEscape }
    } elseif ($entity -is [String]) {
        $params.GetEnumerator() | ForEach-Object {
            if ($regexEscape -eq $false -or $null -eq $_.Value) {
                $entity = $entity.Replace($_.Name, $_.Value)
            } else {
                $entity = $entity.Replace($_.Name, [Regex]::Escape($_.Value))
            }
        }

        return $entity
    }
}

function format_hash([String] $hash) {
    $hash = $hash.toLower()
    switch ($hash.Length) {
        32 { $hash = "md5:$hash" } # md5
        40 { $hash = "sha1:$hash" } # sha1
        64 { $hash = $hash } # sha256
        128 { $hash = "sha512:$hash" } # sha512
        default { $hash = $null }
    }

    return $hash
}

function format_hash_aria2([String] $hash) {
    $hash = $hash -split ':' | Select-Object -Last 1
    switch ($hash.Length) {
        32 { $hash = "md5=$hash" } # md5
        40 { $hash = "sha-1=$hash" } # sha1
        64 { $hash = "sha-256=$hash" } # sha256
        128 { $hash = "sha-512=$hash" } # sha512
        default { $hash = $null }
    }

    return $hash
}

function get_hash([String] $multihash) {
    $type, $hash = $multihash -split ':'
    if (!$hash) {
        # no type specified, assume sha256
        $type, $hash = 'sha256', $multihash
    }

    if (@('md5', 'sha1', 'sha256', 'sha512') -notcontains $type) {
        return $null, "Hash type '$type' isn't supported."
    }

    return $type, $hash.ToLower()
}

function handle_special_urls($url) {
    # FossHub.com
    if ($url -match '^(?:.*fosshub.com\/)(?<name>.*)(?:\/|\?dwl=)(?<filename>.*)$') {
        $Body = @{
            'projectUri'      = $Matches.name
            'fileName'        = $Matches.filename
            'isLatestVersion' = $true
        }
        if ((Invoke-RestMethod -Uri $url) -match '"p":"(?<pid>[a-f0-9]{24}).*?"r":"(?<rid>[a-f0-9]{24})') {
            $Body.Add('projectId', $Matches.pid)
            $Body.Add('releaseId', $Matches.rid)
        }
        $url = Invoke-RestMethod -Uri 'https://api.fosshub.com/download/' -Method Post -ContentType 'application/json' -Body (ConvertTo-Json $Body -Compress)
        if ($null -eq $url.error) { $url = $url.data.url }
    }

    # Sourceforge.net
    if ($url -match '(?:downloads\.)?sourceforge.net\/projects?\/(?<project>[^\/]+)\/(?:files\/)?(?<file>.*?)(?:$|\/download|\?)') {
        # Reshapes the URL to avoid redirections
        $url = "https://downloads.sourceforge.net/project/$($matches['project'])/$($matches['file'])"
    }

    return $url
}

#region Deprecated
function run($exe, $arg, $msg, $continue_exit_codes) {
    Show-DeprecatedWarning $MyInvocation 'Invoke-ExternalCommand'
    Invoke-ExternalCommand -FilePath $exe -ArgumentList $arg -Activity $msg -ContinueExitCodes $continue_exit_codes
}

function get_magic_bytes($file) {
    Show-DeprecatedWarning $MyInvocation 'Get-MagicByte'
    return Get-MagicByte -File $file
}

function get_magic_bytes_pretty($file, $glue = ' ') {
    Show-DeprecatedWarning $MyInvocation 'Get-MagicByte'
    return Get-MagicByte -File $file -Glue $glue -Pretty
}

function fullpath($path) {
    Show-DeprecatedWarning $MyInvocation 'Get-AbsolutePath'
    return Get-AbsolutePath -Path $path
}

function file_path($app, $file) {
    Show-DeprecatedWarning $MyInvocation 'Get-AppFilePath'
    return Get-AppFilePath -App $app -File $file
}
#endregion Deprecated

##################
# Core Bootstrap #
##################

# Note: Github disabled TLS 1.0 support on 2018-02-23. Need to enable TLS 1.2
#       for all communication with api.github.com
Optimize-SecurityProtocol

# Scoop root directory
$scoopdir = $env:SCOOP, (get_config 'rootPath'), "$env:USERPROFILE\scoop" | Where-Object { -not [String]::IsNullOrEmpty($_) } | Select-Object -First 1
$SCOOP_ROOT_DIRECTORY = $scoopdir

# Scoop global apps directory
$globaldir = $env:SCOOP_GLOBAL, (get_config 'globalPath'), "$env:ProgramData\scoop" | Where-Object { -not [String]::IsNullOrEmpty($_) } | Select-Object -first 1
$SCOOP_GLOBAL_ROOT_DIRECTORY = $globaldir

# Scoop cache directory
# Note: Setting the SCOOP_CACHE environment variable to use a shared directory
#       is experimental and untested. There may be concurrency issues when
#       multiple users write and access cached files at the same time.
#       Use at your own risk.
$cachedir = $env:SCOOP_CACHE, (get_config 'cachePath'), "$scoopdir\cache" | Where-Object { -not [String]::IsNullOrEmpty($_) } | Select-Object -first 1
$SCOOP_CACHE_DIRECTORY = $cachedir

# Scoop config file migration
$configHome = $env:XDG_CONFIG_HOME, "$env:USERPROFILE\.config" | Select-Object -First 1
$configFile = "$configHome\scoop\config.json"
if ((Test-Path "$env:USERPROFILE\.scoop") -and !(Test-Path $configFile)) {
    New-Item -ItemType Directory (Split-Path -Path $configFile) -ErrorAction Ignore | Out-Null
    Move-Item "$env:USERPROFILE\.scoop" $configFile
    Write-UserMessage -Warning -Message @(
        "Scoop configuration has been migrated from '~/.scoop'"
        "to '$configFile'"
    )
}

# Load Scoop config
$scoopConfig = load_cfg $configFile

# Setup proxy globally
setup_proxy
