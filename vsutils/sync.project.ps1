param
(
    [parameter(mandatory=$true)][string] $project,
    [parameter(mandatory=$true)][string[]] $source,
    [string[]] $exclude = @()
)

. ..\common\Path.ps1

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
function Get-SourceItems($root, $path, $filter, $exclude = @())
{
    $d = Get-ChildItem -File -Recurse -Path $path -Include $filter -Exclude $exclude | 
        ? { 
            $p = $_ 
            ($exclude | ? { $p.FullName.Contains($_) }).Count -eq 0 } |
        Group-Object -AsHashtable -Property Directory
    $d.GetEnumerator() | % { 
        $key = Find-Path-Relative $source $_.Key
        $value = $_.Value | % { Find-Path-Relative $root $_ }
        @{ "key" = $key; "value" = $value }
    }
}

# xml utils
function Remove-Child($doc, $nsmgr, $path)
{
    $doc.SelectNodes($path, $nsmgr) | 
        % { $_.ParentNode.RemoveChild($_) } | Out-Null
}

function Clean-Project($nsmgr, $doc)
{
    $e = @(
        "//defns:IncludePath", 
        "//defns:ItemGroup/defns:ClInclude", 
        "//defns:ItemGroup/defns:ClCompile", 
        "//defns:Filter", 
        "//defns:ItemGroup[not(*)]",
        "//defns:PropertyGroup[not(*)]")

    $e | % { Remove-Child $doc $nsmgr $_ }
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

function Get-NamespaceManager($doc)
{
    $nsmgr = New-Object Xml.XmlNamespaceManager $doc.NameTable
    $doc.DocumentElement.Attributes | 
        ? { $_.Name.StartsWith("xmlns") } | 
        % {
            $p = $_.Name.Split(':')[1]
            if([string]::IsNullOrEmpty($p)) { 
                $p = "defns"
            }
            $nsmgr.AddNamespace($p, $_.Value)
          }
    ,$nsmgr
}

filter Create-Element ($doc, $ns)
{
    $doc.CreateElement($_, $ns)
}

filter Append-Attribute($name, $value)
{
    $_.SetAttribute($name, $value)
    $_
}

filter Set-InnerText($value)
{
    $_.InnerText = $value
    $_
}

filter Append-ElementTo($p)
{
    $p.AppendChild($_) | Out-Null
    $p
}

function Save-Xml($doc, $path)
{
    Use-Resource (New-Object IO.FileStream $path, Create, Write) {
        param($fs)
        Use-Resource (New-Object Xml.XmlTextWriter $fs, $null) {
            param($xw)
            $xw.Formatting = "indented"
            $doc.WriteContentTo($xw)
        }
    }
}

function Open-Xml($path)
{
    [xml]$doc = Get-Content $path
    $doc
}

function Create-Xml($ns, $root)
{
    $doc = New-Object Xml.XmlDocument
    $root | Create-Element $doc $ns | Append-ElementTo $doc
}

function Update-Xml($path, $update)
{
    $doc = Open-Xml $path
    $nsmgr = Get-NamespaceManager $doc

    Invoke-Command -ScriptBlock $update -ArgumentList $doc, $nsmgr | Out-Null

    Save-Xml $doc $path
}

# msbuild
filter Append-Element($doc, $ns, $name, $text)
{
    $p = $_
    $name | Create-Element $doc $ns | Set-InnerText $text | Append-ElementTo $p
}

filter Append-Filter($doc, $ns, $value)
{
    $_ | Append-Element $doc $ns "Filter" $value
}

filter Append-Guid($doc, $ns, $guid)
{
    $_ | Append-Element $doc $ns "UniqueIdentifier" ("{" + [guid]::NewGuid() + "}")
}

filter Pass-Item($doc, $ns, $value)
{
    $_
}

filter Create-Item($doc, $ns, $name, $update, $data)
{
    $value = $_
    $name | 
        Create-Element $doc $ns | 
        Append-Attribute "Include" $value | 
        & $update $doc $ns $data
}

filter Process-Source($doc, $process_item)
{
    $ns = $nsmgr.LookupNamespace("defns")

    $type = $_.Key
    $_.Value.GetEnumerator() | 
        % { 
            $group = "ItemGroup" | Create-Element $doc $ns
            $_.Value | 
                Create-Item $doc $ns $type $process_item $_.Key | 
                Append-ElementTo $group |
                Append-ElementTo $doc.DocumentElement
        }
}

function Main($project, $source, $exclude)
{
    $project = Convert-Path $project
    $source = Convert-Path $source

    Test-Path-Throw $project Leaf
    Test-Path-Throw $source Container

    $pd = Split-Path -Parent $project
    $rs = Find-Path-Relative $pd $source
    Test-Path-Throw (Join-Path $pd $rs) Container

    $pn = [System.IO.Path]::GetFileNameWithoutExtension($project)

    $headers = @("*.hpp", "*.h")
    $sources = @("*.cpp", "*.c")

    $data = @{
        "ClInclude"=Get-SourceItems $pd $source $headers $exclude; 
        "ClCompile"=Get-SourceItems $pd $source $sources $exclude}

    $p = Join-Path $pd "$pn.vcxproj"

    Update-Xml $p { 
        param($doc, $nsmgr)

        Clean-Project $nsmgr $doc                
        $data.GetEnumerator() | Process-Source $doc ${function:Pass-Item}
    }
    
    $pf = Join-Path $pd "$pn.vcxproj.filters"

    Update-Xml $pf {
        param($doc, $nsmgr)

        Clean-Project $nsmgr $doc
        $data.GetEnumerator() | Process-Source $doc ${function:Append-Filter}

        (@{"Filter" = @{Value=$data.Values | 
            % { $_.GetEnumerator() | 
            % { $_.Key } } |
            % { Parent-Path $_ } | 
            Sort-Object -Unique }}).GetEnumerator() | 
            Process-Source $doc ${function:Append-Guid}
    }

    $ph = Join-Path $pd "$pn.Headers.props"
    $ns = "http://schemas.microsoft.com/developer/msbuild/2003"
    $doc = Create-Xml $ns "Project"
    $doc.DocumentElement | 
        Append-Attribute "DefaultTargets" "Build" | 
        Append-Attribute "ToolsVersion" "12.0" | Out-Null

    $data["ClInclude"].GetEnumerator() | 
        % { $_.Value | % { Split-Path -Parent $_ } } | % { Parent-Path $_ } |
        Sort-Object -Unique |
        % { "ProjectInclude" | Create-Element $doc $ns | Set-InnerText "$_;`$(ProjectInclude)" } | 
        Append-ElementTo ("PropertyGroup" | Create-Element $doc $ns) | 
        Append-ElementTo $doc.DocumentElement | Out-Null

    "AdditionalIncludeDirectories" | 
        Create-Element $doc $ns | 
        Set-InnerText "`$(ProjectInclude);%(AdditionalIncludeDirectories)" |
        Append-ElementTo ("ClCompile" | Create-Element $doc $ns) |
        Append-ElementTo ("ItemDefinitionGroup" | Create-Element $doc $ns) |
        Append-ElementTo $doc.DocumentElement | Out-Null

    Save-Xml $doc $ph
}

Main $project $source $exclude
