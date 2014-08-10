# Path utils
function Test-Path-Throw($path, $type) {
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

function Parent-Path($path)
{
    for($p = $path ; $p -ne "" -and $p -ne "." -and $p -ne ".."; $p = Split-Path -Parent $p) { $p } 
}
