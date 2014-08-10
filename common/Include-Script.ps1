$mp = [Environment]::GetEnvironmentVariable("PSModulePath")
$mp += ";" + (Split-Path -Parent $PSCommandPath)
[Environment]::SetEnvironmentVariable("PSModulePath", $mp)

function Include-Script($script)
{
	[System.IO.Path]::GetFilenameWithoutExtension($script)
	New-Module -Name ([System.IO.Path]::GetFilenameWithoutExtension($script)) -ScriptBlock {
		. $script
	}
}
