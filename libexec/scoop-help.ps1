# Usage: scoop help [<OPTIONS>] [<COMMAND>]
# Summary: Show help for specific scoop command or scoop itself.
#
# Options:
#   -h, --help      Show help for this command.

param($cmd)

# TODO: getopt adoption

'help', 'Helpers' | ForEach-Object {
    . (Join-Path $PSScriptRoot "..\lib\$_.ps1")
}

Reset-Alias

$exitCode = 0
$commands = commands

if (!($cmd)) {
    Write-UserMessage -Output -Message @(
        'Usage: scoop [<OPTIONS>] [<COMMAND>]'
        ''
        'Windows command line installer'
        ''
        'General exit codes'
        '   0 - Everything OK'
        '   1 - No parameter provided or usage shown'
        '   2 - Argument parsing error'
        '   3 - General execution error'
        '   4 - Permission/Privileges related issue'
        '   10 + - Number of failed actions (installations, updates, ...)'
        ''
        'Type ''scoop help <COMMAND>'' to get help for a specific command.'
        ''
        'Available commands are:'
    )
    print_summaries
} elseif ($commands -contains $cmd) {
    print_help $cmd
} else {
    $exitCode = 3
    Write-UserMessage -Message "scoop help: no such command '$cmd'" -Output
}

exit $exitCode

