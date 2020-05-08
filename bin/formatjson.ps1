<#
.SYNOPSIS
    Format manifest.
.PARAMETER App
    Manifest to format.
.PARAMETER Dir
    Where to search for manifest(s).
.EXAMPLE
    PS BUCKETROOT> .\bin\formatjson.ps1
    Format all manifests inside bucket directory.
.EXAMPLE
    PS BUCKETROOT> .\bin\formatjson.ps1 7zip
    Format manifest '7zip' inside bucket directory.
#>
param(
    [SupportsWildcards()]
    [String] $App = '*',
    [Parameter(Mandatory = $true)]
    [ValidateScript( {
        if (!(Test-Path $_ -Type Container)) {
            throw "$_ is not a directory!"
        } else {
            $true
        }
    })]
    [String] $Dir
)

'core', 'manifest', 'json' | ForEach-Object {
    . "$PSScriptRoot\..\lib\$_.ps1"
}

$Dir = Resolve-Path $Dir

foreach ($m in Get-ChildItem $Dir "$App.json") {
    $path = $m.Fullname

    # beautify
    $manifest = parse_json $path | ConvertToPrettyJson

    # Convert to 4 spaces
    $json = $json -replace "`t", (4 * ' ')
    [System.IO.File]::WriteAllLines($path, $manifest)
}
