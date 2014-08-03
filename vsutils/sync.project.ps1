#param
#(
#    [parameter(mandatory=$true)][string] $project,
#    [parameter(mandatory=$true)][string] $source
#)

# Path utils
function Test-Path-Throw([string]$path, [Microsoft.Powershell.Commands.TestPathType]$type) {
    if(!(Test-Path -PathType $type $path)) { 
        $(throw "$path of type $type not found") 
    }
}

function Split-Path-Recursive([string]$path, [string[]]$components = @()) {
    if($path -eq "") { 
        return $components[-1..-$components.Length] 
    }
    
    $p = Split-Path $path -Parent
    $c = Split-Path $path -Leaf

    return Split-Path-Recursive $p ($components += $c)
}

function Join-Path-Array($components)
{
    $join = {
        param($p, $c); 
        
        if($p -eq $null) { 
            return $c 
        } else { 
            Join-Path $p $c 
        }
    }

    Aggregate $components $null $join
}

function Find-Path-Relative([string]$source, [string]$path)
{
    $s = Split-Path-Recursive $source
    $p = Split-Path-Recursive $path

    $r = (Find-RootIndex $s $p)
    if($r -eq -1) { # not found
        return $path
    }
    if($r -eq -2) { # equals
        return ""
    }
    if($r -eq ($s.Length - 1)) {
        return Join-Path-Array $p[($r + 1) .. ($p.Length - 1)]
    }

    $sr = ($r + 1) .. ($s.Length - 1)
    $pr = ($r + 1) .. ($p.Length - 1)

    return Join-Path-Array (@($sr | %{ ".." }) + $p[$pr])
}

# array utils
function Zip($a, $b)
{
    $type = 'Tuple[' + $a[0].GetType() + ',' + $b[0].GetType() + ']'
    $r = @()
    0..(($a, $b | Measure-Object -Property Length -Maximum).Maximum - 1) | % { $r += New-Object $type ($a[$_], $b[$_]) }
    $r
}

function Aggregate ($a, $c, $op)
{
    $a | % { $c = Invoke-Command -ScriptBlock $op -ArgumentList $c, $_  }
    $c
}

function Find-RootIndex($a, $b)
{
    (Zip $a $b | % { $_.Item1 -eq $_.Item2 }).IndexOf($false) - 1
}


# project utils
function Get-SourceItems($root, $path, $filter)
{
    $hdr = @{}
    Get-ChildItem -Recurse -Path $path -File -Include $filter | % { 
        [string[]]$hdr[$_.Directory] += (Find-Path-Relative $root $_.FullName) 
    }
    $hdr
}

# xml utils
function Remove-Child($ns, $doc, $path)
{
    $doc.SelectNodes($path, $ns) | % { $_.ParentNode.RemoveChild($_) } | Out-Null
}

function Clean-Project($ns, $doc)
{
    $e = @("//ms:ClInclude", "//ms:ClCompile", "//ms:Filter", "//ms:ItemGroup[not(*)]")

    $e | % { Remove-Child $ns $doc $_ }
}

function Create-Item($nsu, $doc, $name, $customize)
{
    $i = $doc.CreateElement($name, $nsu)
    Invoke-Command -ScriptBlock $customize -ArgumentList $nsu, $doc, $i
    $i
}

function Create-ItemGroup($nsu, $doc, $items, $createitem)
{
    $items.GetEnumerator() | % {
        $ig = $doc.CreateElement("ItemGroup", $nsu)
        $key = $_.Key
        $_.Value | % {
            $value = $_
            $e = Invoke-Command -ScriptBlock $createitem -ArgumentList $nsu, $doc, $key, $value
            $ig.AppendChild($e) | Out-Null
        }
        $doc.Project.AppendChild($ig) | Out-Null
    }
}

function Use-Resource($r, $op)
{
    try
    {
       Invoke-Command -ScriptBlock $op -ArgumentList $r
    }
    finally
    {
        $r.Dispose()
    }
}

function Update-Xml($path, $update)
{
    [xml]$doc = Get-Content $path
    
    Invoke-Command -ScriptBlock $update -ArgumentList $doc

    Use-Resource (New-Object IO.FileStream $path, Create, Write) {
        param($fs)
        Use-Resource (New-Object Xml.XmlTextWriter $fs, $null) {
            param($xw)
            $xw.Formatting = "indented"
            $doc.WriteContentTo($xw)
        }
    }
}



$project = Convert-Path $project
$source = Convert-Path $source

Test-Path-Throw $project Leaf
Test-Path-Throw $source Container

$pd = Split-Path -Parent $project
$rs = Find-Path-Relative $pd $source
Test-Path-Throw (Join-Path $pd $rs) Container

$headers = @("*.hpp", "*.h")
$sources = @("*.cpp", "*.c")

$hdr = Get-SourceItems $pd $source $headers
$src = Get-SourceItems $pd $source $sources

$p = "aa.vcxproj.1"
$d = "aa.vcxproj"
Copy-Item $p $d


$nsu = "http://schemas.microsoft.com/developer/msbuild/2003"

Update-Xml $d { 
    param($doc)

    $nsmgr = New-Object Xml.XmlNamespaceManager $doc.NameTable
    $nsmgr.AddNamespace("ms", $nsu)

    Clean-Project $nsmgr $doc

    $item = {
        param($nsu, $doc, $k, $v, $type)
        Create-Item $nsu $doc $type {
            param($nsu, $doc, $i)
            $i.SetAttribute("Include", $v)
        }
    }

    $clcompile = { param($nsu, $doc, $k, $v); Invoke-Command -Scriptblock $item -ArgumentList $nsu, $doc, $k, $v, "ClInclude" }
    $clinclude = { param($nsu, $doc, $k, $v); Invoke-Command -Scriptblock $item -ArgumentList $nsu, $doc, $k, $v, "ClCompile" }

    Create-ItemGroup $nsu $doc $hdr $clcompile
    Create-ItemGroup $nsu $doc $src $clinclude
}

$pf = "aa.vcxproj.filters.1"
$df = "aa.vcxproj.filters"
Copy-Item $pf $df

Update-Xml $df {
    param($doc)

    $nsmgr = New-Object Xml.XmlNamespaceManager $doc.NameTable
    $nsmgr.AddNamespace("ms", $nsu)

    Clean-Project $nsmgr $doc
 
    $item = {
        param($nsu, $doc, $k, $v, $type)
        Create-Item $nsu $doc $type {
            param($nsu, $doc, $i)
            $i.SetAttribute("Include", $v)
            $e = $doc.CreateElement("Filter", $nsu)
            $e.InnerText = (Find-Path-Relative $source $k) #(Split-Path -Parent $source) $k)
            $i.AppendChild($e) | Out-Null
        }
    }

    $filter = {
        param($nsu, $doc, $k, $v, $type)
        Create-Item $nsu $doc $type {
            param($nsu, $doc, $i)
            $i.SetAttribute("Include", $v)
            $e = $doc.CreateElement("UniqueIdentifier", $nsu)
            $e.InnerText = "{" + [guid]::NewGuid() + "}"
            $i.AppendChild($e) | Out-Null
        }
    }

    $filters = { param($nsu, $doc, $k, $v); Invoke-Command -Scriptblock $filter -ArgumentList $nsu, $doc, $k, $v, "Filter" }
    $clinclude = { param($nsu, $doc, $k, $v); Invoke-Command -Scriptblock $item -ArgumentList $nsu, $doc, $k, $v, "ClInclude" }
    $clcompile = { param($nsu, $doc, $k, $v); Invoke-Command -Scriptblock $item -ArgumentList $nsu, $doc, $k, $v, "ClCompile" }

    $dirs = ($src.Keys + $hdr.Keys) | % { Find-Path-Relative $source $_ } | ? { $_ -ne "" } | Sort-Object -Unique

    Create-ItemGroup $nsu $doc @{""=$dirs} $filters 
    Create-ItemGroup $nsu $doc $hdr $clinclude
    Create-ItemGroup $nsu $doc $src $clcompile    
}

#Write-Host
#Find-Path-Relative (Split-Path -Parent $project) (Join-Path (Split-Path -Parent $project) "foo")
#Find-Path-Relative (Split-Path -Parent $project) "D:\bar"
