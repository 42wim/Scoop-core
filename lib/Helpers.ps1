
function Write-UserMessage {
    <#
    .SYNOPSIS
        Print message to the user using Write-Host.
    .DESCRIPTION
        Based on passed severity the message will have different color and prefix.
    .PARAMETER Message
        Specify the message to be displayed to user.
    .PARAMETER Severity
        Specify the severity of the message.
        Could be Message, Info, Warning, Error
    .PARAMETER Info
        Same as -Severity Info
    .PARAMETER Warning
        Same as -Severity warning
    .PARAMETER Err
        Same as -Severity Error
    #>
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromRemainingArguments, Position = 0)]
        [String[]] $Message,
        [ValidateSet('Message', 'Info', 'Warning', 'Error')]
        [String] $Severity = 'Message',
        [Switch] $Info,
        [Switch] $Warning,
        [Switch] $Err
    )
    if ($Info) { $Severity = 'Info' }
    if ($Warning) { $Severity = 'Warning' }
    if ($Err) { $Severity = 'Error' }

    switch ($Severity) {
        'Info' { $sev = 'INFO '; $color = 'DarkGray' }
        'Warning' { $sev = 'WARN '; $color = 'DarkYellow' }
        'Error' { $sev = 'ERROR '; $color = 'DarkRed' }
        default { $sev = ''; $color = 'White' }
    }

    $display = ($Message -replace '^', "$Sev") -join "`r`n"
    Write-Host $display -ForegroundColor $color
}
