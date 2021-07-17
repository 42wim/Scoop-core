. "$PSScriptRoot\Scoop-TestLib.ps1"
. "$PSScriptRoot\..\lib\getopt.ps1"

Describe 'getopt' -Tag 'Scoop' {
    It 'handle short option with required argument missing' {
        $null, $null, $err = Resolve-GetOpt '-x' 'x:' ''
        $err | Should -be 'Option -x requires an argument.'

        $null, $null, $err = Resolve-GetOpt '-xy' 'x:y' ''
        $err | Should -be 'Option -x requires an argument.'
    }

    It 'handle long option with required argument missing' {
        $null, $null, $err = Resolve-GetOpt '--arb' '' 'arb='
        $err | Should -be 'Option --arb requires an argument.'
    }

    It 'handle unrecognized short option' {
        $null, $null, $err = Resolve-GetOpt '-az' 'a' ''
        $err | Should -be 'Option -z not recognized.'
    }

    It 'handle unrecognized long option' {
        $null, $null, $err = Resolve-GetOpt '--non-exist' '' ''
        $err | Should -be 'Option --non-exist not recognized.'

        $null, $null, $err = Resolve-GetOpt '--global', '--another' 'abc:de:' 'global', 'one'
        $err | Should -be 'Option --another not recognized.'
    }

    It 'remaining args returned' {
        $opt, $rem, $err = Resolve-GetOpt '-g', 'rem' 'g' ''
        $err | Should -benullorempty
        $opt.g | Should -betrue
        $rem | Should -not -benullorempty
        $rem.length | Should -be 1
        $rem[0] | Should -be 'rem'
    }

    It 'get a long flag and a short option with argument' {
        $a = '--global -a 32bit test' -split ' '
        $opt, $rem, $err = Resolve-GetOpt $a 'ga:' 'global', 'arch='

        $err | Should -benullorempty
        $opt.global | Should -betrue
        $opt.a | Should -be '32bit'
    }

    It 'handles regex characters' {
        $a = '-?'
        { $opt, $rem, $err = Resolve-GetOpt $a 'ga:' 'global' 'arch=' } | Should -not -throw
        { $null, $null, $null = Resolve-GetOpt $a '?:' 'help' | Should -not -throw }
    }

    It 'handles short option without required argument' {
        $null, $null, $err = Resolve-GetOpt '-x' 'x' ''
        $err | Should -benullorempty
    }

    It 'handles long option without required argument' {
        $opt, $null, $err = Resolve-GetOpt '--long-arg' '' 'long-arg'
        $err | Should -benullorempty
        $opt.'long-arg' | Should -betrue
    }

    It 'handles long option with required argument' {
        $opt, $null, $err = Resolve-GetOpt '--long-arg', 'test' '' 'long-arg='
        $err | Should -benullorempty
        $opt.'long-arg' | Should -be 'test'
    }
}
