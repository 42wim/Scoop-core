function Write-UserMessage {
    <#
    .SYNOPSIS
        Print message to the user using Write-Host.
    .DESCRIPTION
        Based on passed severity the message will have different color and prefix.
    .PARAMETER Message
        Specifies the message to be displayed to user.
    .PARAMETER Severity
        Specifies the severity of the message.
        Could be Message, Info, Warning, Error, Success
    .PARAMETER Output
        Specifies the Write-Output cmdlet is used instead of Write-Host
    .PARAMETER Info
        Same as -Severity Info
    .PARAMETER Warning
        Same as -Severity warning
    .PARAMETER Err
        Same as -Severity Error
    .PARAMETER Success
        Same as -Severity Success
    .PARAMETER SkipSeverity
        Specifies the output will not contains severity prefix.
    #>
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromRemainingArguments, Position = 0)]
        [AllowEmptyString()]
        [String[]] $Message,
        [ValidateSet('Message', 'Info', 'Warning', 'Error', 'Success')]
        [String] $Severity = 'Message',
        [Switch] $Output,
        [Switch] $Info,
        [Switch] $Warning,
        [Switch] $Err,
        [Switch] $Success,
        [Switch] $SkipSeverity,
        [System.ConsoleColor] $Color = 'White'
    )

    begin {
        if ($Info) { $Severity = 'Info' }
        if ($Warning) { $Severity = 'Warning' }
        if ($Err) { $Severity = 'Error' }
        if ($Success) { $Severity = 'Success' }

        switch ($Severity) {
            'Info' { $sev = 'INFO  '; $foreColor = 'DarkGray' }
            'Warning' { $sev = 'WARN  '; $foreColor = 'DarkYellow' }
            'Error' { $sev = 'ERROR '; $foreColor = 'DarkRed' }
            'Success' { $sev = ''; $foreColor = 'DarkGreen' }
            default {
                $sev = ''
                $foreColor = 'White'
                if ($Color -ne 'White') {
                    $foreColor = $Color
                } else {
                    $Output = $true
                }
            }
        }
        $display = @()
    }

    process {
        $m = if ($SkipSeverity) { $Message } else { $Message -replace '^', "$sev" }
        $display += $m
    }

    end {
        $display = $display -join "`r`n"
        if ($Output) {
            Write-Output $display
        } else {
            Write-Host $display -ForegroundColor $foreColor
        }
    }
}

function Out-UTF8File {
    param(
        [Parameter(Mandatory)]
        [Alias('Path')]
        [System.IO.FileInfo] $File,
        [Parameter(Mandatory, ValueFromPipeline)]
        $Content
    )
    process {
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            Set-Content -LiteralPath $File -Value $Content -Encoding utf8
        } else {
            [System.IO.File]::WriteAllLines($File, ($Content -join "`r`n"))
        }
    }
}

function Get-MagicBytes {
    <#
    .SYNOPSIS
        Get file's first 8 bytes.
    .PARAMETER File
        Specifies the file.
    .PARAMETER Pretty
        Specifies to return 'x2' representation of each byte.
    .PARAMETER Glue
        Specifies the characters used to join the bytes representation.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] $File,
        [Switch] $Pretty,
        [String] $Glue = ' '
    )

    process {
        if (!(Test-Path $File -PathType Leaf)) { return '' }

        if ((Get-Command Get-Content).Parameters.ContainsKey('AsByteStream')) {
            # PowerShell Core (6.0+) '-Encoding byte' is replaced by '-AsByteStream'
            $key = 'AsByteStream'
            $value = $true
        } else {
            $key = 'Encoding'
            $value = 'Byte'
        }
        $par = @{
            'LiteralPath' = $File
            'TotalCount'  = 8
            "$key"        = $value
        }

        $cont = Get-Content @par
        if ($Pretty) { $cont = $cont | ForEach-Object { $_.ToString('x2') } }
        $cont = $cont -join $Glue

        return $cont.ToUpper()
    }
}
