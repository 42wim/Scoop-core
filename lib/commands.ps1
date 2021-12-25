@(
    @('core', 'Test-ScoopDebugEnabled'),
    @('Helpers', 'New-IssuePrompt')
) | ForEach-Object {
    if (!([bool] (Get-Command $_[1] -ErrorAction 'Ignore'))) {
        Write-Verbose "Import of lib '$($_[0])' initiated from '$PSCommandPath'"
        . (Join-Path $PSScriptRoot "$($_[0]).ps1")
    }
}

function command_files {
    $libExec = Join-Path $PSScriptRoot '..\libexec'
    $shims = Join-Path $SCOOP_ROOT_DIRECTORY 'shims'

    Confirm-DirectoryExistence -LiteralPath $shims | Out-Null

    return Get-ChildItem -LiteralPath $libExec, $shims -ErrorAction 'SilentlyContinue' | Where-Object -Property 'Name' -Match -Value 'scoop-.*?\.ps1$'
}

function command_name($filename) {
    $filename.name | Select-String 'scoop-(.*?)\.ps1$' | ForEach-Object { $_.Matches[0].Groups[1].Value }
}

function commands {
    command_files | ForEach-Object { command_name $_ }
}

function command_path($cmd) {
    $cmd_path = Join-Path $PSScriptRoot "..\libexec\scoop-$cmd.ps1"

    # Built in commands
    if (!(Test-Path $cmd_path)) {
        # Get path from shim
        $shim_path = Join-Path $SCOOP_ROOT_DIRECTORY "shims\scoop-$cmd.ps1"
        if (!(Test-Path -LiteralPath $shim_path)) {
            throw [ScoopException]::new("Shim for alias '$cmd' does not exist") # TerminatingError thrown
        }

        $cmd_path = $shim_path
        $line = ((Get-Content -LiteralPath $shim_path -Encoding 'UTF8') | Where-Object { $_.StartsWith('$path') })
        if ($line) {
            # TODO: Drop Invoke-Expression
            Invoke-Expression -Command "$line"
            $cmd_path = $path
        }
    }

    return $cmd_path
}

function Invoke-ScoopCommand {
    param($cmd, $arguments)

    & (command_path $cmd) @arguments
}
