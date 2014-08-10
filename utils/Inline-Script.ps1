param(
    [parameter(mandatory=$true)]$source,
    [parameter(mandatory=$true)]$destination
)

. ..\common\Path.ps1

function Inline-Script($source, $destination)
{
    Test-Path-Throw -type Leaf -path $source
    $src = Convert-Path $source
    $sd = Split-Path -Parent $src
 
    Set-Content $destination (
        Get-Content $src | % {
            if ($_ -match "^\s*\.\s+(?<script>.*)$") {
                $mp = Join-Path $sd $matches['script']
                Test-Path-Throw -type Leaf -path $mp
                $_ = Get-Content $mp
            }
            $_
        })
}

Inline-Script $source $destination
