@(
    @('core', 'Test-ScoopDebugEnabled'),
    @('Helpers', 'New-IssuePrompt'),
    @('autoupdate', 'Invoke-Autoupdate'),
    @('buckets', 'Get-KnownBucket'),
    @('decompress', 'Expand-7zipArchive'),
    @('manifest', 'Resolve-ManifestInformation'),
    @('Versions', 'Clear-InstalledVersion'),
    @('ManifestHelpers', 'Test-Persistence')
) | ForEach-Object {
    if (!([bool] (Get-Command $_[1] -ErrorAction 'Ignore'))) {
        Write-Verbose "Import of lib '$($_[0])' initiated from '$PSCommandPath'"
        . (Join-Path $PSScriptRoot "$($_[0]).ps1")
    }
}

function Deny-ArmInstallation {
    param($Manifest, $Architecture)

    process {
        if ($SHOVEL_IS_ARM_ARCH) {
            if (($Architecture -eq 'arm64') -and !($Manifest.'architecture'.'arm64')) {
                throw [ScoopException]::new("Manifest does not explicitly support 'arm64' architecture. Try to install with '--arch 32bit' or '--arch 64bit' to use Windows arm emulation.")
            }
        } else {
            if ($Architecture -eq 'arm64') {
                if ($true -eq (get_config 'dbgBypassArmCheck' $false)) { return }
                throw [ScoopException]::new("Installation of 'arm64' version is not supported on x86 based system")
            }
        }
    }
}

function Get-HelperPath {
    <#
    .SYNOPSIS
        Get full path to the often used application's executables.
    .PARAMETER Helper
        Specifies the name of helper application.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateSet('7zip', 'Lessmsi', 'Innounp', 'Dark', 'Aria2', 'Zstd', 'Innoextract')]
        [String] $Helper
    )

    process {
        $helperPath = $null
        switch ($Helper) {
            'Aria2' { $helperPath = Get-AppFilePath 'aria2' 'aria2c.exe' }
            'Innounp' { $helperPath = Get-AppFilePath 'innounp' 'innounp.exe' }
            'Lessmsi' { $helperPath = Get-AppFilePath 'lessmsi' 'lessmsi.exe' }
            'Zstd' { $HelperPath = Get-AppFilePath 'zstd' 'zstd.exe' }
            'Innoextract' { $HelperPath = Get-AppFilePath 'innoextract' 'innoextract.exe' }
            '7zip' {
                $helperPath = Get-AppFilePath '7zip' '7z.exe'
                if ([String]::IsNullOrEmpty($helperPath)) {
                    $helperPath = Get-AppFilePath '7zip-zstd' '7z.exe'
                }
            }
            'Dark' {
                $helperPath = Get-AppFilePath 'dark' 'dark.exe'
                if ([String]::IsNullOrEmpty($helperPath)) {
                    $helperPath = Get-AppFilePath 'wixtoolset' 'dark.exe'
                }
            }
        }

        return $helperPath
    }
}

function Test-HelperInstalled {
    <#
    .SYNOPSIS
        Test if specified widely used application is installed.
    .PARAMETER Helper
        Specifies the name of application.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [ValidateSet('7zip', 'Lessmsi', 'Innounp', 'Dark', 'Aria2', 'Zstd', 'Innoextract')]
        [String] $Helper
    )

    process { return ![String]::IsNullOrWhiteSpace((Get-HelperPath -Helper $Helper)) }
}

function Get-AppFilePath {
    <#
    .SYNOPSIS
        Get full path to the specific executable under specific application installed via scoop.
    .PARAMETER App
        Specifies the scoop's application name.
    .PARAMETER File
        Specifies the executable name.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    param(
        [Parameter(Mandatory)]
        [String] $App,
        [Parameter(Mandatory)]
        [String] $File
    )

    # Normal path to file
    $path = versiondir $App (Select-CurrentVersion -AppName $App) $false | Join-Path -ChildPath $File
    if (Test-Path -LiteralPath $path -PathType 'Leaf') { return $path }

    # Global path to file
    $path = versiondir $App (Select-CurrentVersion -AppName $App -Global) $true | Join-Path -ChildPath $File
    if (Test-Path -LiteralPath $path -PathType 'Leaf') { return $path }

    # Try path
    $path = Get-Command -Name $File -ErrorAction 'SilentlyContinue'
    if ($path -and (Test-Path -LiteralPath $path.Source -PathType 'Leaf')) {
        Write-UserMessage -Message "Application '$App' is not installed via Scoop. Trying to use '$($path.Source)'" -Warning
        return $path
    }

    # Not found
    return $null
}

function Test-Aria2Enabled {
    <#
    .SYNOPSIS
        Test if aria2 application is installed and enabled.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    process { return (Test-HelperInstalled -Helper 'Aria2') -and (get_config 'aria2-enabled' $true) }
}

#region TODO: Extract lib/Download.ps1
function dl_with_cache($app, $version, $url, $to, $cookies = $null, $use_cache = $true) {
    $cached = cache_path $app $version $url
    debug $cached

    if (!(Test-Path $cached) -or !$use_cache) {
        Confirm-DirectoryExistence -LiteralPath $SCOOP_CACHE_DIRECTORY | Out-Null
        try {
            do_dl $url "$cached.download" $cookies
        } catch {
            throw [ScoopException]::new($_.Exception.Message, $version) # TerminatingError thrown
        }
        Move-Item "$cached.download" $cached -Force
    } else { Write-UserMessage -Message "Loading $(url_remote_filename $url) from cache" }

    if (!($null -eq $to)) { Copy-Item $cached $to }
}

function do_dl($url, $to, $cookies) {
    $progress = ([System.Console]::IsOutputRedirected -eq $false) -and ($Host.name -ne 'Windows PowerShell ISE Host')

    try {
        $url = handle_special_urls $url
        dl $url $to $cookies $progress
    } catch {
        $e = $_.Exception
        if ($e.InnerException) { Write-UserMessage -Message $e.InnerException -Err }
        throw [ScoopException]::new("Download failed|-$($e.Message)") # TerminatingError thrown
    }
}
#endregion TODO: Extract lib/Download.ps1

#region TODO: Extract lib/Download.aria.ps1
function aria_exit_code($exitcode) {
    $codes = @{
        0  = 'All downloads were successful'
        1  = 'An unknown error occurred'
        2  = 'Timeout'
        3  = 'Resource was not found'
        4  = 'Aria2 saw the specified number of "resource not found" error. See --max-file-not-found option'
        5  = 'Download aborted because download speed was too slow. See --lowest-speed-limit option'
        6  = 'Network problem occurred.'
        7  = 'There were unfinished downloads. This error is only reported if all finished downloads were successful and there were unfinished downloads in a queue when aria2 exited by pressing Ctrl-C by an user or sending TERM or INT signal'
        8  = 'Remote server did not support resume when resume was required to complete download'
        9  = 'There was not enough disk space available'
        10 = 'Piece length was different from one in .aria2 control file. See --allow-piece-length-change option'
        11 = 'Aria2 was downloading same file at that moment'
        12 = 'Aria2 was downloading same info hash torrent at that moment'
        13 = 'File already existed. See --allow-overwrite option'
        14 = 'Renaming file failed. See --auto-file-renaming option'
        15 = 'Aria2 could not open existing file'
        16 = 'Aria2 could not create new file or truncate existing file'
        17 = 'File I/O error occurred'
        18 = 'Aria2 could not create directory'
        19 = 'Name resolution failed'
        20 = 'Aria2 could not parse Metalink document'
        21 = 'FTP command failed'
        22 = 'HTTP response header was bad or unexpected'
        23 = 'Too many redirects occurred'
        24 = 'HTTP authorization failed'
        25 = 'Aria2 could not parse bencoded file (usually ".torrent" file)'
        26 = '".torrent" file was corrupted or missing information that aria2 needed'
        27 = 'Magnet URI was bad'
        28 = 'Bad/unrecognized option was given or unexpected option argument was given'
        29 = 'The remote server was unable to handle the request due to a temporary overloading or maintenance'
        30 = 'Aria2 could not parse JSON-RPC request'
        31 = 'Reserved. Not used'
        32 = 'Checksum validation failed'
    }
    if ($null -eq $codes[$exitcode]) {
        return 'An unknown error occurred'
    }

    return $codes[$exitcode]
}

function get_filename_from_metalink($file) {
    $XML_MAGIC = '3C3F786D6C'
    # Check if file starts with '<?xml'
    if (!(Get-MagicByte -File $file -Pretty -Glue '').StartsWith($XML_MAGIC)) { return $null }

    # Add System.Xml for reading metalink files
    Add-Type -AssemblyName 'System.Xml'
    $xr = [System.Xml.XmlReader]::Create($file)
    $filename = $null
    try {
        $xr.ReadStartElement('metalink')
        if ($xr.ReadToFollowing('file') -and $xr.MoveToFirstAttribute()) {
            $filename = $xr.Value
        }
    } catch [System.Xml.XmlException] {
        return $null
    } finally {
        $xr.Close()
    }

    return $filename
}

function dl_with_cache_aria2($app, $version, $manifest, $architecture, $dir, $cookies = $null, $use_cache = $true, $check_hash = $true) {
    $data = @{ }
    $urls = @(url $manifest $architecture)

    # aria2 input file
    $urlstxt = Join-Path $SCOOP_CACHE_DIRECTORY "$app.txt"
    $urlstxt_content = ''
    $has_downloads = $false

    # aria2 options
    $options = @(
        "--input-file='$urlstxt'"
        "--user-agent='$SHOVEL_USERAGENT'"
        '--allow-overwrite=true'
        '--auto-file-renaming=false'
        "--retry-wait=$(get_config 'aria2-retry-wait' 2)"
        "--split=$(get_config 'aria2-split' 5)"
        "--max-connection-per-server=$(get_config 'aria2-max-connection-per-server' 5)"
        "--min-split-size=$(get_config 'aria2-min-split-size' '5M')"
        '--console-log-level=warn'
        '--enable-color=false'
        '--no-conf=true'
        '--follow-metalink=true'
        '--metalink-preferred-protocol=https'
        '--min-tls-version=TLSv1.2'
        "--stop-with-process=$PID"
        '--continue'
        '--summary-interval 0'
    )

    if ($cookies) {
        $options += "--header='Cookie: $(cookie_header $cookies)'"
    }

    $proxy = get_config 'proxy' 'none'
    if ($proxy -ne 'none') {
        $defaultWebProxy = [System.Net.WebRequest]::DefaultWebProxy
        if ($defaultWebProxy.Address) {
            $options += "--all-proxy='$($defaultWebProxy.Address.Authority)'"
        }
        if ($defaultWebProxy.Credentials.UserName) {
            $options += "--all-proxy-user='$($defaultWebProxy.Credentials.UserName)'"
        }
        if ($defaultWebProxy.Credentials.Password) {
            $options += "--all-proxy-passwd='$($defaultWebProxy.Credentials.Password)'"
        }
    }

    $more_options = get_config 'aria2-options'
    if ($more_options) {
        $options += $more_options
    }

    foreach ($url in $urls) {
        $data.$url = @{
            'filename'  = url_filename $url
            'target'    = "$dir\$(url_filename $url)"
            'cachename' = fname (cache_path $app $version $url)
            'source'    = cache_path $app $version $url
        }

        if (!(Test-Path $data.$url.source)) {
            $has_downloads = $true
            # create aria2 input file content
            $urlstxt_content += "$(handle_special_urls $url)`n"
            if (($url -notlike '*sourceforge.net*') -and ($url -notlike '*portableapps.com*')) {
                $urlstxt_content += "    referer=$(strip_filename $url)`n"
            }
            $urlstxt_content += "    dir=$SCOOP_CACHE_DIRECTORY`n"
            $urlstxt_content += "    out=$($data.$url.cachename)`n"
        } else {
            Write-Host 'Loading ' -NoNewline
            Write-Host $(url_remote_filename $url) -ForegroundColor Cyan -NoNewline
            Write-Host ' from cache.'
        }
    }

    if ($has_downloads) {
        # Write aria2 input file
        Out-UTF8File -Path $urlstxt -Content $urlstxt_content

        # Build aria2 command
        # TODO: Adopt better approach
        $aria2 = "& '$(Get-HelperPath -Helper Aria2)' $($options -join ' ')"

        debug $aria2
        # Handle aria2 console output
        Write-Host 'Starting download with aria2 ...'

        [System.Console]::CursorVisible = $false
        Invoke-Expression $aria2 | ForEach-Object {
            # Skip blank lines
            if ([String]::IsNullOrWhiteSpace($_)) { return }

            # Prevent potential overlaping of text when one line is shorter
            $len = $Host.UI.RawUI.WindowSize.Width - $_.Length - 20
            $blank = if ($len -gt 0) { ' ' * $len } else { '' }
            $color = 'Gray'

            if ($_.StartsWith('(OK):')) {
                $noNewLine = $true
                $color = 'Green'
            } elseif ($_.StartsWith('[') -and $_.EndsWith(']')) {
                $noNewLine = $true
                $color = 'Cyan'
            } elseif ($_.StartsWith('Download Results:')) {
                $noNewLine = $false
            }

            # Update latest line
            Write-Host "`rDownload: $_$blank" -ForegroundColor $color -NoNewline:$noNewLine
        }
        Write-Host ''
        [System.Console]::CursorVisible = $true

        if ($LASTEXITCODE -gt 0) {
            $mes = "Download failed! (Error $LASTEXITCODE) $(aria_exit_code $LASTEXITCODE)"
            Write-UserMessage -Err -Message @(
                $mes
                $urlstxt_content
                $aria2
            )

            throw [ScoopException]::new("Download via aria2 failed|-$mes", $version) # TerminatingError thrown
        }

        # Remove aria2 input file when done
        if (Test-Path $urlstxt) { Remove-Item $urlstxt }
    }

    foreach ($url in $urls) {
        $metalink_filename = get_filename_from_metalink $data.$url.source
        if ($metalink_filename) {
            Remove-Item $data.$url.source -Force
            Join-Path $SCOOP_CACHE_DIRECTORY $metalink_filename | Rename-Item -NewName $data.$url.source -Force
        }

        # Run hash checks
        if ($check_hash) {
            $manifest_hash = hash_for_url $manifest $url $architecture
            $ok, $err = check_hash $data.$url.source $manifest_hash $(show_app $app $bucket)
            if (!$ok) {
                if (Test-Path $data.$url.source) { Remove-Item $data.$url.source -Force }
                if ($url.Contains('sourceforge.net')) {
                    Write-UserMessage -Message 'SourceForge.net is known for causing hash validation fails. Please try again before opening a ticket.' -Color Yellow
                }

                throw [ScoopException]::new("Hash check failed|-$err", $version) # TerminatingError thrown
            }
        }

        # Copy or move file to target location
        if (!(Test-Path $data.$url.source) ) { throw [ScoopException]::new('Cached file not found') } # TerminatingError thrown

        if ($dir -ne $SCOOP_CACHE_DIRECTORY) {
            if ($use_cache) {
                Copy-Item $data.$url.source $data.$url.target
            } else {
                Move-Item $data.$url.source $data.$url.target -Force
            }
        }
    }
}
#endregion TODO: Extract lib/Download.aria.ps1

#region TODO: Extract lib/Download.ps1
# Download with filesize and progress indicator
function dl($url, $to, $cookies, $progress) {
    $reqUrl = ($url -split '#')[0]
    $wreq = [System.Net.WebRequest]::Create($reqUrl)
    if ($wreq -is [System.Net.HttpWebRequest]) {
        $wreq.UserAgent = $SHOVEL_USERAGENT
        # Do not send referer to sourceforge, portbleapps
        if (($url -notlike '*sourceforge.net*') -and ($url -notlike '*portableapps.com*')) {
            $wreq.Referer = strip_filename $url
        }
        if ($cookies) {
            $wreq.Headers.Add('Cookie', (cookie_header $cookies))
        }
    }

    try {
        $wres = $wreq.GetResponse()
    } catch [System.Net.WebException] {
        $exc = $_.Exception
        $handledCodes = @(
            [System.Net.HttpStatusCode]::MovedPermanently, # HTTP 301
            [System.Net.HttpStatusCode]::Found, # HTTP 302
            [System.Net.HttpStatusCode]::SeeOther, # HTTP 303
            [System.Net.HttpStatusCode]::TemporaryRedirect  # HTTP 307
        )

        # Only handle redirection codes
        $redirectRes = $exc.Response
        if ($handledCodes -notcontains $redirectRes.StatusCode) {
            throw $exc
        }

        # Get the new location of the file
        if ((-not $redirectRes.Headers) -or ($redirectRes.Headers -notcontains 'Location')) {
            throw $exc
        }

        $newUrl = $redirectRes.Headers['Location']
        Write-UserMessage -Message "Following redirect to $newUrl..." -Info

        # Handle manual file rename
        if ($url -like '*#/*') {
            $null, $postfix = $url -split '#/'
            $newUrl = "$newUrl#/$postfix"
        }

        dl $newUrl $to $cookies $progress
        return
    }

    $total = $wres.ContentLength
    if (($total -eq -1) -and ($wreq -is [System.Net.FtpWebRequest])) {
        $total = ftp_file_size $url
    }

    if ($progress -and ($total -gt 0)) {
        [System.Console]::CursorVisible = $false
        function dl_onProgress($read) {
            dl_progress $read $total $url
        }
    } else {
        Write-UserMessage -Message "Downloading $url ($(filesize $total))..." -Output:$false
        function dl_onProgress {
            #no op
        }
    }

    try {
        $s = $wres.GetResponseStream()
        $fs = [System.IO.File]::OpenWrite($to)
        $buffer = New-Object byte[] 2048
        $totalRead = 0
        $sw = [System.Diagnostics.StopWatch]::StartNew()

        dl_onProgress $totalRead
        while (($read = $s.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $fs.Write($buffer, 0, $read)
            $totalRead += $read
            if ($sw.ElapsedMilliseconds -gt 100) {
                $sw.Restart()
                dl_onProgress $totalRead
            }
        }
        $sw.Stop()
        dl_onProgress $totalRead
    } finally {
        if ($progress) {
            [System.Console]::CursorVisible = $true
            Write-Host
        }
        if ($fs) { $fs.Close() }
        if ($s) { $s.Close() }
        $wres.Close()
    }
}

function dl_progress_output($url, $read, $total, $console) {
    $filename = url_remote_filename $url

    # Calculate current percentage done
    $p = [System.Math]::Round($read / $total * 100, 0)

    # Pre-generate LHS and RHS of progress string
    # So we know how much space we have
    $left = "$filename ($(filesize $total))"
    $right = [String]::Format('{0,3}%', $p)

    # Calculate remaining width for progress bar
    $midwidth = $console.BufferSize.Width - ($left.Length + $right.Length + 8)

    # Calculate how many characters are completed
    $completed = [System.Math]::Abs([System.Math]::Round(($p / 100) * $midwidth, 0) - 1)

    # Generate dashes to symbolise completed
    if ($completed -gt 1) {
        $dashes = [string]::Join('', ((1..$completed) | ForEach-Object { '=' }))
    }

    # This is why we calculate $completed - 1 above
    $dashes += switch ($p) {
        100 { '=' }
        default { '>' }
    }

    # The remaining characters are filled with spaces
    $spaces = switch ($dashes.Length) {
        $midwidth { [string]::Empty }
        default {
            [string]::Join('', ((1..($midwidth - $dashes.Length)) | ForEach-Object { ' ' }))
        }
    }

    "$left [$dashes$spaces] $right"
}

function dl_progress($read, $total, $url) {
    $console = $host.UI.RawUI
    $left = $console.CursorPosition.X
    $top = $console.CursorPosition.Y
    $width = $console.BufferSize.Width

    if ($read -eq 0) {
        $maxOutputLength = (dl_progress_output $url 100 $total $console).Length
        if (($left + $maxOutputLength) -gt $width) {
            # not enough room to print progress on this line
            # print on new line
            Write-Host
            $left = 0
            $top = $top + 1
            # Prevent oveflow
            if ($top -gt $console.CursorPosition.Y) { $top = $console.CursorPosition.Y }
        }
    }

    Write-Host $(dl_progress_output $url $read $total $console) -NoNewline
    [System.Console]::SetCursorPosition($left, $top)
}

function dl_urls($app, $version, $manifest, $bucket, $architecture, $dir, $use_cache = $true, $check_hash = $true) {
    # We only want to show this warning once
    if (!$use_cache) { Write-UserMessage -Message 'Cache is being ignored.' -Warning }

    # Can be multiple urls: if there are, then msi or installer should go last,
    # So that $fname is set properly
    $urls = @(url $manifest $architecture)

    # Can be multiple cookies: they will be used for all HTTP requests
    $cookies = $manifest.cookie

    $fname = $null

    # extract_dir and extract_to in manifest are like queues: for each url that
    # needs to be extracted, will get the next dir from the queue
    $extract_dirs = @(extract_dir $manifest $architecture)
    $extract_tos = @(extract_to $manifest $architecture)
    $extracted = 0

    try {
        Confirm-DirectoryExistence -LiteralPath $SCOOP_CACHE_DIRECTORY | Out-Null
    } catch {
        throw [ScoopException]::new("Could not create cache directory: '$SCOOP_CACHE_DIRECTORY'")
    }

    # Download first
    if (Test-Aria2Enabled) {
        dl_with_cache_aria2 $app $version $manifest $architecture $dir $cookies $use_cache $check_hash
    } else {
        foreach ($url in $urls) {
            $fname = url_filename $url

            dl_with_cache $app $version $url (Join-Path $dir $fname) $cookies $use_cache

            if ($check_hash) {
                $manifest_hash = hash_for_url $manifest $url $architecture
                $ok, $err = check_hash (Join-Path $dir $fname) $manifest_hash $(show_app $app $bucket)
                if (!$ok) {
                    $cached = cache_path $app $version $url
                    if (Test-Path $cached) {
                        # rm cached file
                        Remove-Item $cached -Force
                    }
                    if ($url.Contains('sourceforge.net')) {
                        Write-Host -f yellow 'SourceForge.net is known for causing hash validation fails. Please try again before opening a ticket.'
                    }
                    throw [ScoopException]::new("Hash check failed|-$err", $version) # TerminatingError thrown
                }
            }
        }
    }

    foreach ($url in $urls) {
        $fname = url_filename $url

        $extract_dir = $extract_dirs[$extracted]
        $extract_to = $extract_tos[$extracted]

        # Work out extraction method, if applicable
        $extract_fn = $null
        if ($manifest.innosetup) {
            $extract_fn = 'Expand-InnoArchive'
        } elseif ($fname -match '\.zip$') {
            # Use 7zip when available (more fast)
            if (((get_config '7ZIPEXTRACT_USE_EXTERNAL' $false) -and (Test-CommandAvailable '7z')) -or (Test-HelperInstalled -Helper '7zip')) {
                $extract_fn = 'Expand-7zipArchive'
            } else {
                $extract_fn = 'Expand-ZipArchive'
            }
        } elseif ($fname -match '\.msi$') {
            # Check manifest doesn't use deprecated install method
            if (msi $manifest $architecture) {
                Write-UserMessage -Message 'MSI install is deprecated. If you maintain this manifest, please refer to the manifest reference docs.' -Warning
            } else {
                $extract_fn = 'Expand-MsiArchive'
            }
        } elseif (Test-7zipRequirement -File $fname) {
            # 7zip
            $extract_fn = 'Expand-7zipArchive'
        } elseif (Test-ZstdRequirement -File $fname) {
            # Zstd
            $extract_fn = 'Expand-ZstdArchive'
        }

        if ($extract_fn) {
            Write-Host 'Extracting ' -NoNewline
            Write-Host $fname -ForegroundColor Cyan -NoNewline
            Write-Host ' ... ' -NoNewline
            & $extract_fn -Path (Join-Path $dir $fname) -DestinationPath (Join-Path $dir $extract_to) -ExtractDir $extract_dir -Removal
            Write-Host 'done.' -ForegroundColor Green
            $extracted++
        }
    }

    $fname # The last downloaded file
}

function cookie_header($cookies) {
    if (!$cookies) { return }

    $vals = $cookies.PsObject.Properties | ForEach-Object {
        "$($_.Name)=$($_.Value)"
    }

    [string]::Join(';', $vals)
}

function is_in_dir($dir, $check) {
    $check -match "^$([System.Text.RegularExpressions.Regex]::Escape("$dir"))(\\|`$)"
}

function ftp_file_size($url) {
    $request = [System.Net.FtpWebRequest]::Create($url)
    $request.Method = [System.Net.WebRequestMethods+Ftp]::GetFileSize
    return $request.GetResponse().ContentLength
}

# hashes
function hash_for_url($manifest, $url, $arch) {
    $hashes = @(hash $manifest $arch) | Where-Object { $null -ne $_ };

    if ($hashes.Length -eq 0) { return $null }

    $urls = @(url $manifest $arch)

    $index = [array]::IndexOf($urls, $url)
    if ($index -eq -1) { throw [ScoopException]::new("Invalid manifest|-Could not find hash in manifest for '$url'.") } # TerminatingError thrown

    return @($hashes)[$index]
}

# returns (ok, err)
function check_hash($file, $hash, $app_name) {
    if (!$hash) {
        Write-UserMessage -Message "No hash in manifest. SHA256 for '$(fname $file)' is:`n    $(compute_hash $file 'sha256')" -Warning
        return $true, $null
    }

    Write-Host 'Checking hash of ' -NoNewline
    Write-Host $(url_remote_filename $url) -ForegroundColor Cyan -NoNewline
    Write-Host ' ... ' -NoNewline
    $algorithm, $expected = get_hash $hash
    if ($null -eq $algorithm) {
        return $false, "Hash type '$algorithm' isn't supported."
    }

    $actual = compute_hash $file $algorithm
    $expected = $expected.ToLower()

    if ($actual -ne $expected) {
        $msg = "Hash check failed!`n"
        $msg += "App:         $app_name`n"
        $msg += "URL:         $url`n"
        if (Test-Path $file) {
            $msg += "First bytes: $(Get-MagicByte -File $file)`n"
        }
        if ($expected -or $actual) {
            $msg += "Expected:    $expected`n"
            $msg += "Actual:      $actual"
        }
        return $false, $msg
    }
    Write-Host 'ok.' -ForegroundColor Green
    return $true, $null
}

function compute_hash($file, $algname) {
    try {
        if (Test-CommandAvailable Get-FileHash) {
            return (Get-FileHash -Path $file -Algorithm $algname).Hash.ToLower()
        } else {
            $fs = [System.IO.File]::OpenRead($file)
            $alg = [System.Security.Cryptography.HashAlgorithm]::Create($algname)
            $hexbytes = $alg.Computehash($fs) | ForEach-Object { $_.tostring('x2') }
            return [string]::join('', $hexbytes)
        }
    } catch {
        Write-UserMessage -Message $_.Exception.Message -Err
    } finally {
        if ($fs) { $fs.Dispose() }
        if ($alg) { $alg.Dispose() }
    }

    return ''
}
#endregion TODO: Extract lib/Download.ps1

# for dealing with installers
function args($config, $dir, $global) {
    if ($config) {
        return $config | ForEach-Object { (format $_ @{ 'dir' = $dir; 'global' = $global }) }
    }
    return @()
}

function run_installer($fname, $manifest, $architecture, $dir, $global) {
    # MSI or other installer
    $msi = msi $manifest $architecture
    $installer = installer $manifest $architecture
    $script = $installer.script

    if ($script) {
        # Skip installer if installer property specifies only 1 property == script
        # If there is file or args next to the script, both should be called, script first
        $props = @($installer.PSObject.Properties | Where-Object -Property 'MemberType' -EQ -Value 'NoteProperty' | Select-Object -ExpandProperty 'Name')
        if ($props -and ($props.Count -eq 1) -and ($props -contains 'script')) {
            $skipInstaller = $true
        }
    }

    if ($msi) {
        install_msi $fname $dir $msi
    } elseif ($installer -and !$skipInstaller) {
        install_prog $fname $dir $installer $global
    }

    # Run installer.script after installer.file
    # This allow to modify files after installer was executed and before binaries/shortcuts are created/linked
    if ($script) {
        Write-UserMessage -Message 'Running installer script...' -Output:$false
        Invoke-Expression (@($script) -join "`r`n")
    }
}

# deprecated (see also msi_installed)
function install_msi($fname, $dir, $msi) {
    $msifile = Join-Path $dir (coalesce $msi.File "$fname")

    if (!(is_in_dir $dir $msifile)) { throw [ScoopException]::new("Invalid manifest|-MSI file '$msifile' is outside the app directory.") } # TerminatingError thrown
    if (!($msi.code)) { throw [ScoopException]::new('Invalid manifest|-Could not find MSI code.') } # TerminatingError thrown
    if (msi_installed $msi.code) { throw [ScoopException]::new('The MSI package is already installed on this system.') } # TerminatingError thrown

    $logfile = Join-Path $dir 'install.log'

    $arg = @("/i `"$msifile`"", '/norestart', "/lvp `"$logfile`"", "TARGETDIR=`"$dir`"", "INSTALLDIR=`"$dir`"") + @(args $msi.args $dir)

    if ($msi.silent) { $arg += '/qn', 'ALLUSERS=2', 'MSIINSTALLPERUSER=1' }
    else { $arg += '/qb-!' }

    $continue_exit_codes = @{ 3010 = 'a restart is required to complete installation' }

    $installed = Invoke-ExternalCommand 'msiexec' $arg -Activity 'Running installer...' -ContinueExitCodes $continue_exit_codes
    if (!$installed) {
        throw [ScoopException]::new("Installation aborted. You might need to run 'scoop uninstall $app' before trying again.") # TerminatingError thrown
    }
    Remove-Item $logfile
    Remove-Item $msifile
}

# deprecated
# get-wmiobject win32_product is slow and checks integrity of each installed program,
# so this uses the [wmi] type accelerator instead
# http://blogs.technet.com/b/heyscriptingguy/archive/2011/12/14/use-powershell-to-find-and-uninstall-software.aspx
function msi_installed($code) {
    $path = "hklm:\software\microsoft\windows\currentversion\uninstall\$code"
    if (!(Test-Path $path)) { return $false }
    $key = Get-Item $path
    $name = $key.GetValue('displayname')
    $version = $key.GetValue('displayversion')
    $classkey = "IdentifyingNumber=`"$code`",Name=`"$name`",Version=`"$version`""
    try { $wmi = [wmi]"Win32_Product.$classkey"; $true } catch { $false }
}

function install_prog($fname, $dir, $installer, $global) {
    $prog = Join-Path $dir (coalesce $installer.file "$fname")
    if (!(is_in_dir $dir $prog)) {
        throw [ScoopException]::new("Invalid manifest|-Installer '$prog' is outside the app directory.") # TerminatingError thrown
    }
    $arg = @(args $installer.args $dir $global)

    if ($prog.EndsWith('.ps1')) {
        Write-UserMessage -Message "Running installer file '$prog'" -Output:$false
        & $prog @arg
        if ($LASTEXITCODE -ne 0) {
            throw [ScoopException]::new("Installation failed with exit code $LASTEXITCODE") # TerminatingError thrown
        }
    } else {
        $installed = Invoke-ExternalCommand $prog $arg -Activity 'Running installer...'
        if (!$installed) {
            throw [ScoopException]::new("Installation aborted. You might need to run 'scoop uninstall $app' before trying again.") # TerminatingError thrown
        }
    }

    # Do not remove installer if "keep" flag is set to true
    if ($installer.keep -ne 'true') { Remove-Item $prog }
}

function run_uninstaller($manifest, $architecture, $dir) {
    $msi = msi $manifest $architecture
    $uninstaller = uninstaller $manifest $architecture
    $version = $manifest.version

    if ($uninstaller.script) {
        Write-UserMessage -Message 'Running uninstaller script...' -Output:$false
        Invoke-Expression (@($uninstaller.script) -join "`r`n")
        return
    }

    if ($msi -or $uninstaller) {
        $exe = $null
        $arg = $null
        $continue_exit_codes = @{ }

        if ($msi) {
            $code = $msi.code
            $exe = 'msiexec'
            $arg = @('/norestart', "/x $code")
            if ($msi.silent) {
                $arg += '/qn', 'ALLUSERS=2', 'MSIINSTALLPERUSER=1'
            } else {
                $arg += '/qb-!'
            }

            $continue_exit_codes.1605 = 'not installed, skipping'
            $continue_exit_codes.3010 = 'restart required'
        } elseif ($uninstaller) {
            $exe = Join-Path $dir $uninstaller.file
            $arg = args $uninstaller.args
            if (!(is_in_dir $dir $exe)) {
                Write-UserMessage -Message "Error in manifest: Installer $exe is outside the app directory, skipping." -Warning
                $exe = $null
            } elseif (!(Test-Path $exe)) {
                Write-UserMessage -Message "Uninstaller $exe is missing, skipping." -Warning
                $exe = $null
            }
        }

        if ($exe) {
            if ($exe.endswith('.ps1')) {
                & $exe @arg
            } else {
                $uninstalled = Invoke-ExternalCommand $exe $arg -Activity 'Running uninstaller...' -ContinueExitCodes $continue_exit_codes
                if (!$uninstalled) { throw [ScoopException]::new('Uninstallation aborted.') } # TerminatingError thrown
            }
        }
    }
}

# get target, name, arguments for shim
function shim_def($item) {
    if ($item -is [array]) { return $item }
    return $item, (strip_ext (fname $item)), $null
}

function create_shims($manifest, $dir, $global, $arch) {
    $shims = @(arch_specific 'bin' $manifest $arch)
    $shims | Where-Object { $_ -ne $null } | ForEach-Object {
        $target, $name, $arg = shim_def $_
        Write-UserMessage -Message "Creating shim for '$name'." -Output:$false

        $bin = Join-Path $dir $target
        if (Test-Path -LiteralPath $bin -PathType 'Leaf') {
            $bin = $bin
        } elseif (Test-Path -LiteralPath $target -PathType 'Leaf') {
            $bin = $target
        } else {
            $bin = search_in_path $target
        }

        if (!$bin) { throw [ScoopException]::new("Shim creation fail|-Cannot shim '$target': File does not exist") } # TerminatingError thrown

        shim $bin $global $name (Invoke-VariableSubstitution -Entity $arg -Substitutes @{ '$dir' = $dir; '$original_dir' = $original_dir; '$persist_dir' = $persist_dir })
    }
}

function rm_shim($name, $shimdir) {
    $shim = Join-Path $shimdir "$name.ps1"

    # Handle no shim from failed install
    if (Test-Path $shim) {
        Write-UserMessage -Message "Removing shim for '$name'." -Output:$false
        Remove-Item $shim
    } else {
        Write-UserMessage -Message "Shim for '$name' is missing. Skipping." -Warning
    }

    # Other shim types might be present
    '', '.exe', '.shim', '.cmd' | ForEach-Object {
        $p = Join-Path $shimdir "$name$_"
        if (Test-Path -LiteralPath $p -PathType 'Leaf') { Remove-Item $p }
    }
}

function rm_shims($manifest, $global, $arch) {
    $shims = @(arch_specific 'bin' $manifest $arch)

    $shims | Where-Object { $_ -ne $null } | ForEach-Object {
        $target, $name, $null = shim_def $_
        $shimdir = shimdir $global

        rm_shim $name $shimdir
    }
}

# Gets the path for the 'current' directory junction for
# the specified version directory.
function current_dir($versiondir) {
    return Split-Path -LiteralPath $versiondir | Join-Path -ChildPath 'current'
}


# Creates or updates the directory junction for [app]/current,
# pointing to the specified version directory for the app.
#
# Returns the 'current' junction directory if in use, otherwise
# the version directory.
function link_current($versiondir) {
    if (get_config 'NO_JUNCTIONS') { return $versiondir }

    $currentdir = current_dir $versiondir

    Write-UserMessage -Message "Linking $(friendly_path $currentdir) => $(friendly_path $versiondir)" -Output:$false

    if ($currentdir -eq $versiondir) {
        throw [ScoopException]::new("Version 'current' is not allowed!") # TerminatingError thrown
    }

    if (Test-Path -LiteralPath $currentdir -PathType 'Container') {
        Remove-DirectoryJunctionLink -LinkName $currentdir
    }

    New-DirectoryJunctionLink -Target $versiondir -LinkName $currentdir | Out-Null

    return $currentdir
}

# Removes the directory junction for [app]/current which
# points to the current version directory for the app.
#
# Returns the 'current' junction directory (if it exists),
# otherwise the normal version directory.
function unlink_current($versiondir) {
    if (get_config 'NO_JUNCTIONS') { return $versiondir }
    $currentdir = current_dir $versiondir

    if (Test-Path -LiteralPath $currentdir -PathType 'Container') {
        Write-UserMessage -Message "Unlinking $(friendly_path $currentdir)" -Output:$false

        Remove-DirectoryJunctionLink -LinkName $currentdir

        return $currentdir
    }

    return $versiondir
}

#region TODO: Extract lib/Installation.ps1 / lib/Environment.ps1
# to undo after installers add to path so that scoop manifest can keep track of this instead
function ensure_install_dir_not_in_path($dir, $global) {
    # TODO: Properly handle unix
    if ($SHOVEL_IS_UNIX) { return }

    $path = (env 'path' $global)

    $fixed, $removed = find_dir_or_subdir $path "$dir"
    if ($removed) {
        $removed | ForEach-Object { Write-UserMessage -Message "Installer added '$(friendly_path $_)' to path. Removing." -Output:$false }
        env 'path' $global $fixed
    }

    if (!$global) {
        $fixed, $removed = find_dir_or_subdir (env 'path' $true) "$dir"
        if ($removed) {
            $removed | ForEach-Object { Write-UserMessage -Message "Installer added '$_' to system path. You might want to remove this manually (requires admin permission)." -Warning }
        }
    }
}

function find_dir_or_subdir($path, $dir) {
    $dir = $dir.TrimEnd('\')
    $fixed = @()
    $removed = @()
    $path -split ';' | ForEach-Object {
        if ($_) {
            if (($_ -eq $dir) -or ($_ -like "$dir\*")) { $removed += $_ }
            else { $fixed += $_ }
        }
    }
    return [string]::join(';', $fixed), $removed
}

function env_add_path($manifest, $dir, $global, $arch) {
    # TODO: Properly handle unix
    if ($SHOVEL_IS_UNIX) {
        Write-UserMessage -Message 'Environment variable manipulations are not supported on *nix' -Info
        return
    }

    $env_add_path = arch_specific 'env_add_path' $manifest $arch

    if ($env_add_path) {
        # Reverse the path
        [Array]::Reverse($env_add_path)
        $env_add_path | Where-Object { $_ } | ForEach-Object {
            $path_dir = Join-Path $dir $_
            if (!(is_in_dir $dir $path_dir)) {
                throw [ScoopException]::new("Invalid manifest|-env_add_path '$_' is outside the app directory.") # TerminatingError thrown
            }
            add_first_in_path $path_dir $global
        }
    }
}

function env_rm_path($manifest, $dir, $global, $arch) {
    # TODO: Properly handle unix
    if ($SHOVEL_IS_UNIX) {
        Write-UserMessage -Message 'Environment variable manipulations are not supported on *nix' -Info
        return
    }

    $env_add_path = arch_specific 'env_add_path' $manifest $arch
    $env_add_path | Where-Object { $_ } | ForEach-Object {
        $path_dir = Join-Path $dir $_

        remove_from_path $path_dir $global
    }
}

function env_set($manifest, $dir, $global, $arch) {
    # TODO: Properly handle unix
    if ($SHOVEL_IS_UNIX) {
        Write-UserMessage -Message 'Environment variable manipulations are not supported on *nix' -Info
        return
    }

    $env_set = arch_specific 'env_set' $manifest $arch
    if ($env_set) {
        $env_set | Get-Member -Member NoteProperty | ForEach-Object {
            $name = $_.name;
            $val = format $env_set.$($_.name) @{ 'dir' = $dir }
            env $name $global $val
            Set-Content env:\$name $val
        }
    }
}

function env_rm($manifest, $global, $arch) {
    # TODO: Properly handle unix
    if ($SHOVEL_IS_UNIX) {
        Write-UserMessage -Message 'Environment variable manipulations are not supported on *nix' -Info
        return
    }

    $env_set = arch_specific 'env_set' $manifest $arch
    if ($env_set) {
        $env_set | Get-Member -Member NoteProperty | ForEach-Object {
            $name = $_.name
            env $name $global $null
            if (Test-Path env:\$name) { Remove-Item env:\$name }
        }
    }
}
#endregion TODO: Extract lib/Installation.ps1 / lib/Environment.ps1

# TODO: Move to Installation and rename
function show_notes($manifest, $dir, $original_dir, $persist_dir) {
    if ($manifest.notes) {
        Write-UserMessage -Output:$false -Message @(
            'Notes'
            '-----'
            (wraptext (Invoke-VariableSubstitution -Entity $manifest.notes -Substitutes @{ '$dir' = $dir; '$original_dir' = $original_dir; '$persist_dir' = $persist_dir }))
        )
    }
}

# TODO: Move to Installation and rename
function show_suggestions($suggested) {
    $installed_apps = (installed_apps $true) + (installed_apps $false)

    foreach ($app in $suggested.keys) {
        $features = $suggested[$app] | Get-Member -Type NoteProperty | ForEach-Object { $_.name }
        foreach ($feature in $features) {
            $feature_suggestions = $suggested[$app].$feature

            $fulfilled = $false
            foreach ($suggestion in $feature_suggestions) {
                try {
                    $resolved = Resolve-ManifestInformation -ApplicationQuery $suggestion -Simple
                } catch {
                    continue
                }

                if ($installed_apps -contains $resolved.ApplicationName) {
                    $fulfilled = $true
                    break
                }
            }

            if (!$fulfilled) {
                Write-UserMessage -Message "'$app' suggests installing '$([string]::join("' or '", $feature_suggestions))'." -Output:$false
            }
        }
    }
}

#region TODO: Extract lib/Persist.ps1
# Persistent data
function persist_def($persist) {
    if ($persist -is [Array]) {
        $source = $persist[0]
        $target = $persist[1]
    } else {
        $source = $persist
        $target = $null
    }

    if (!$target) {
        $target = $source
    }

    return $source, $target
}

function persist_data($manifest, $original_dir, $persist_dir) {
    # TODO: Architecture specific persist?? Are there any apps, that would benefit?
    $persist = $manifest.persist
    if (!$persist) { return }

    $persist_dir = Confirm-DirectoryExistence -LiteralPath $persist_dir

    if ($persist -is [String]) { $persist = @($persist) }

    foreach ($p in $persist) {
        $source, $target = persist_def $p

        Write-UserMessage -Message "Persisting $source" -Output:$false

        $source = $source.TrimEnd('/').TrimEnd('\\')

        $source = Join-Path $original_dir $source
        $target = Join-Path $persist_dir $target

        # if we have had persist data in the store, just create link and go
        if (Test-Path $target) {
            # if there is also a source data, rename it (to keep a original backup)
            if (Test-Path $source) {
                Move-Item $source "$source.original" -Force
            }
            # we don't have persist data in the store, move the source to target, then create link
        } elseif (Test-Path $source) {
            # ensure target parent folder exist
            Split-Path $target | Confirm-DirectoryExistence | Out-Null
            Move-Item $source $target
            # we don't have neither source nor target data! we need to crate an empty target,
            # but we can't make a judgement that the data should be a file or directory...
            # so we create a directory by default. to avoid this, use pre_install
            # to create the source file before persisting (DO NOT use post_install)
        } else {
            $target = New-Object System.IO.DirectoryInfo($target)
            Confirm-DirectoryExistence -LiteralPath $target | Out-Null
        }

        # Mklink throw 'The system cannot find the path specified.' if the full path of the link does not exist.
        $splitted = Split-Path $source -Parent
        if ($splitted -ne $original_dir) { Confirm-DirectoryExistence -LiteralPath $splitted | Out-Null }

        # create link
        if (is_directory $target) {
            # target is a directory, create junction
            New-DirectoryJunctionLink -LinkName $source -Target $target | Out-Null
        } else {
            # target is a file, create hard link
            New-FileHardLink -LinkName $source -Target $target | Out-Null
        }
    }
}

function unlink_persist_data($dir) {
    # unlink all junction / hard link in the directory
    foreach ($file in Get-ChildItem -Recurse $dir) {
        if ($null -ne $file.LinkType) {
            $filepath = $file.FullName
            # directory (junction)
            if ($file -is [System.IO.DirectoryInfo]) {
                Remove-DirectoryJunctionLink -LinkName $filepath -Recurse
            } else {
                # remove the hard link
                Remove-FileHardLink -LinkName $filepath
            }
        }
    }
}

# check whether write permission for Users usergroup is set to global persist dir, if not then set
function persist_permission($manifest, $global) {
    if ($global -and $manifest.persist -and (is_admin)) {
        $path = persistdir $null $global
        $user = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-545'
        $target_rule = New-Object System.Security.AccessControl.FileSystemAccessRule($user, 'Write', 'ObjectInherit', 'none', 'Allow')
        $acl = Get-Acl -Path $path
        $acl.SetAccessRule($target_rule)
        $acl | Set-Acl -Path $path
    }
}
#endregion TODO: Extract lib/Persist.ps1
