# Usage: scoop alias add|list|rm [<args>]
# Summary: Manage scoop aliases
# Help: Add, remove or list Scoop aliases
#
# Aliases are custom Scoop subcommands that can be created to make common tasks
# easier.
#
# To add an Alias:
#     scoop alias add <name> <command> <description>
#
# e.g.:
#     scoop alias add rm 'scoop uninstall $args[0]' 'Uninstalls an app'
#     scoop alias add upgrade 'scoop update *' 'Updates all apps, just like brew or apt'
#
# Options:
#   -v, --verbose   Show alias description and table headers (works only for 'list')

param(
    [String] $Option,
    [String] $Name,
    $Command,
    [String] $Description,
    [Switch] $Verbose
)

'core', 'help', 'Alias' | ForEach-Object {
    . "$PSScriptRoot\..\lib\$_.ps1"
}

$exitCode = 0

switch ($Option) {
    'add' {
        try {
            Add-Alias -Name $Name -Command $Command -Description $Description
        } catch {
            Write-UserMessage -Message $_.Exception.Message -Err
            $exitCode = 2
        }
    }
    'rm' {
        try {
            Remove-Alias -Name $Name
        } catch {
            Write-UserMessage -Message $_.Exception.Message -Err
            $exitCode = 2
        }
    }
    'list' { Get-Alias -Verbose:$Verbose }
    default { my_usage; $exitCode = 1 }
}

exit $exitCode
