param
(
    [parameter(mandatory=$true)][string] $file,
    [parameter(mandatory=$true)][string] $search,
    [parameter(mandatory=$true)][string] $replace
)

(Get-Content $file | % { $_ -replace "$search", "$replace" }) | Set-Content $file
