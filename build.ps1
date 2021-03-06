[cmdletbinding(DefaultParameterSetName='build')]
param(
    [Parameter(ParameterSetName='build',Position=0)]
    [string]$configuration = 'Release',

    [Parameter(ParameterSetName='build',Position=1)]
    [switch]$SkipInstallDotNet,

    [Parameter(ParameterSetName='build',Position=2)]
    [switch]$publishToNuget,

    [Parameter(ParameterSetName='build',Position=3)]
    [string]$nugetApiKey = ($env:NuGetApiKey),

    [Parameter(ParameterSetName='build',Position=4)]
    [Parameter(ParameterSetName='install',Position=1)]
    [string]$dotnetNugetFeedSource=$null,

    [Parameter(ParameterSetName='build',Position=5)]
    [Parameter(ParameterSetName='install',Position=2)]
    [string]$dotnetInstallChannel = 'preview',

    # TODO: Revert back to https://raw.githubusercontent.com/dotnet/cli/rel/1.0.0/scripts/obtain/install.ps1 when bug fixed
    [Parameter(ParameterSetName='build',Position=5)]
    [Parameter(ParameterSetName='install',Position=3)]
    [string]$dotnetInstallUrl = 'https://raw.githubusercontent.com/sayedihashimi/cli/issue2236/scripts/obtain/install.ps1',

    # version parameters
    [Parameter(ParameterSetName='setversion',Position=10)]
    [switch]$setversion,

    [Parameter(ParameterSetName='setversion',Position=11,Mandatory=$true)]
    [string]$newversion,

    [Parameter(ParameterSetName='getversion',Position=0)]
    [switch]$getversion
)

#$dotnetNugetFeedSource='https://dotnet.myget.org/f/dotnet-cli'
#$dotnetNugetFeedSource='https://api.nuget.org/v3/index.json'
$scriptDir = split-path -parent $MyInvocation.MyCommand.Definition

[System.IO.FileInfo]$slnfile = (join-path $scriptDir 'Microsoft.TemplateEngine.sln')
[System.IO.FileInfo[]]$csProjects = (Join-Path $scriptDir 'src\Microsoft.TemplateEngine.Net4\Microsoft.TemplateEngine.Net4.csproj')
$csProjects += (Join-Path $scriptDir 'test\Microsoft.TemplateEngine.Net4.UnitTests\Microsoft.TemplateEngine.Net4.UnitTests.csproj' )

[System.IO.FileInfo[]]$projectJsonToBuild = (Join-Path $scriptDir 'src\Microsoft.TemplateEngine.Core\project.json')
[System.IO.DirectoryInfo]$outputroot=(join-path $scriptDir 'OutputRoot')
[System.IO.DirectoryInfo]$outputPathNuget = (Join-Path $outputroot '_nuget-pkg')
[string]$localNugetFolder = 'c:\temp\nuget\local'
[string]$testFilePattern ='*Microsoft.TemplateEngine*test*.dll'
[string]$testResultsDir = (Join-Path $outputroot.FullName "vs\TestResults")
[string]$sayedToolsversion='0.0.3-beta'
<#
.SYNOPSIS
    You can add this to you build script to ensure that psbuild is available before calling
    Invoke-MSBuild. If psbuild is not available locally it will be downloaded automatically.
#>
function EnsurePsbuildInstlled{
    [cmdletbinding()]
    param(
        # TODO: Change to master when 1.1.9 gets there
        [string]$psbuildInstallUri = 'https://raw.githubusercontent.com/ligershark/psbuild/dev/src/GetPSBuild.ps1',

        [System.Version]$minVersion = (New-Object -TypeName 'system.version' -ArgumentList '1.1.9.1')
    )
    process{
        # see if there is already a version loaded
        $psbuildNeedsInstall = $true
        [System.Version]$installedVersion = $null
        try{
            Import-Module psbuild -ErrorAction SilentlyContinue | Out-Null
            $installedVersion = Get-PSBuildVersion
        }
        catch{
            $installedVersion = $null
        }

        if( ($installedVersion -ne $null) -and ($installedVersion.CompareTo($minVersion) -ge 0) ){
            'Skipping psbuild install because version [{0}] detected' -f $installedVersion.ToString() | Write-Verbose
        }
        else{
            'Installing psbuild from [{0}]' -f $psbuildInstallUri | Write-Verbose
            (new-object Net.WebClient).DownloadString($psbuildInstallUri) | iex

            # make sure it's loaded and throw if not
            if(-not (Get-Command "Invoke-MsBuild" -errorAction SilentlyContinue)){
                throw ('Unable to install/load psbuild from [{0}]' -f $psbuildInstallUri)
            }
        }
    }
}
function EnsureFileReplacerInstlled{
    [cmdletbinding()]
    param()
    begin{
        Import-NuGetPowershell
    }
    process{
        if(-not (Get-Command -Module file-replacer -Name Replace-TextInFolder -errorAction SilentlyContinue)){
            $fpinstallpath = (Get-NuGetPackage -name file-replacer -version '0.4.0-beta' -binpath)
            if(-not (Test-Path $fpinstallpath)){ throw ('file-replacer folder not found at [{0}]' -f $fpinstallpath) }
            Import-Module (Join-Path $fpinstallpath 'file-replacer.psm1') -DisableNameChecking
        }

        # make sure it's loaded and throw if not
        if(-not (Get-Command -Module file-replacer -Name Replace-TextInFolder -errorAction SilentlyContinue)){
            throw ('Unable to install/load file-replacer')
        }
    }
}

function InstallDotNetCli{
    [cmdletbinding()]
    param()
    process{
        $oldloc = Get-Location
        try{
            Set-Location ($slnfile.DirectoryName)
            $tempfile = '{0}.ps1' -f ([System.IO.Path]::GetTempFileName())
            (new-object net.webclient).DownloadFile($dotnetInstallUrl,$tempfile)
            $installArgs = ''
            if(-not ([string]::IsNullOrWhiteSpace($dotnetInstallChannel))){
                $installArgs = '-Channel ' + $dotnetInstallChannel
            }
            Invoke-Expression "& `"$tempfile`" $installArgs"
            $env:path+=";$env:localappdata\Microsoft\dotnet\bin"
            & dotnet --version
            Remove-Item $tempfile -ErrorAction SilentlyContinue
        }
        finally{
            Set-Location $oldloc
        }
    }
}

function InternalEnsure-DirectoryExists{
    param([Parameter(Position=0)][System.IO.DirectoryInfo]$path)
    process{
        if($path -ne $null){
            if(-not (Test-Path $path.FullName)){
                New-Item -Path $path.FullName -ItemType Directory
            }
        }
    }
}

function CleanOutputFolder{
    [cmdletbinding()]
    param()
    process{
        if( ($outputroot -eq $null) -or ([string]::IsNullOrWhiteSpace($outputroot.FullName))){
            return
        }
        elseif(Test-Path $outputroot.FullName){
            'Removing output folder at [{0}]' -f $outputroot.FullName | Write-Output
            Remove-Item $outputroot -Recurse -Force
        }
    }
}

function RestoreNuGetPackages{
    [cmdletbinding()]
    param()
    process{
        $oldloc = Get-Location
        try{
            'restoring nuget packages' | Write-Output
            Set-Location $slnfile.Directory.FullName
            dotnet restore --infer-runtimes --ignore-failed-sources
        }
        finally{
            Set-Location $oldloc
        }
    }
}

function PublishNuGetPackage{
    [cmdletbinding()]
    param(
        [Parameter(Mandatory=$true,ValueFromPipeline=$true)]
        [string]$nugetPackages,

        [Parameter(Mandatory=$true)]
        $nugetApiKey
    )
    process{
        foreach($nugetPackage in $nugetPackages){
            $pkgPath = (get-item $nugetPackage).FullName
            $cmdArgs = @('push',$pkgPath,$nugetApiKey,'-NonInteractive')

            'Publishing nuget package with the following args: [nuget.exe {0}]' -f ($cmdArgs -join ' ') | Write-Verbose
            &(Get-Nuget) $cmdArgs
        }
    }
}

function CopyStaticFilesToOutputDir{
    [cmdletbinding()]
    param()
    process{
        Get-ChildItem $scriptDir *.nuspec -File | Copy-Item -Destination $outputroot
    }
}

function Copy-PackagesToLocalNuGetFolder{
    [cmdletbinding()]
    param(
        $outputFolder = $outputPathNuget
    )
    process{
        if(Test-Path $localNugetFolder){
            Get-ChildItem $outputFolder *.nupkg -Recurse -File|Copy-Item -Destination $localNugetFolder
        }
    }
}

function Build-NuGetPackage{
    [cmdletbinding()]
    param()
    process{
        if(-not (Test-Path $outputPathNuget)){
            New-Item -Path $outputPathNuget -ItemType Directory
        }

        Push-Location
        try{
            [System.IO.FileInfo[]]$nuspecFilesToBuild = @()
            $nuspecFilesToBuild += ([System.IO.FileInfo](Get-ChildItem $outputRoot '*.nuspec' -Recurse -File))

            foreach($nufile in $nuspecFilesToBuild){
                Push-Location
                try{
                    Set-Location -Path ($nufile.Directory.FullName)
                    'Building nuget package for [{0}]' -f ($nufile.FullName) | Write-Verbose
                    Invoke-CommandString -command (Get-Nuget) -commandArgs @('pack',($nufile.Name),'-NoPackageAnalysis','-OutputDirectory',($outputPathNuget.FullName))
                }
                finally{
                    Pop-Location
                }
            }

            Copy-PackagesToLocalNuGetFolder
        }
        finally{
            Pop-Location
        }
    }
}

function BuildSolution{
    [cmdletbinding()]
    param()
    process{

        if(-not (Test-Path $slnfile.FullName)){
            throw ('Solution not found at [{0}]' -f $slnfile.FullName)
        }

        if($outputroot -eq $null){
            throw ('output path is null')
        }

        foreach($project in $csProjects){
            if(-not (Test-Path $project.FullName)){
                throw ('Project not found at [{0}]' -f $project.FullName)
            }
        }
        foreach($pj in $projectJsonToBuild){
        if(-not (Test-Path $pj.FullName)){
                throw ('Project not found at [{0}]' -f $pj.FullName)
            }
        }

        [System.IO.DirectoryInfo]$vsoutputpath = (Join-Path $outputroot.FullName "vs")
        InternalEnsure-DirectoryExists -path $vsoutputpath.FullName

        'Building projects at [{0}]' -f ($csProjects.FullName -join ';') | Write-Output
        if(-not ($onlyBuildDOtnetProjects -eq $true)){
            Invoke-MSBuild -projectsToBuild $csProjects.FullName -visualStudioVersion 14.0 -configuration $configuration -outputpath $vsoutputpath.FullName
        }

        [System.IO.DirectoryInfo]$dnoutputpath = (Join-Path $outputroot.FullName "dotnet")
        InternalEnsure-DirectoryExists -path $dnoutputpath.FullName

        $oldloc = Get-Location
        try{
            foreach($pj in $projectJsonToBuild){
                Set-Location $pj.DirectoryName
                $restoreArgs = ('restore')

                if(-not ([string]::IsNullOrWhiteSpace($dotnetNugetFeedSource))){
                    $restoreArgs += (' -s',$dotnetNugetFeedSource)
                }

                Invoke-CommandString -command dotnet -commandArgs $restoreArgs
                $buildargs = @('build','--configuration', $configuration,  '--build-base-path', $dnoutputpath.FullName, ' --no-incremental')
                Invoke-CommandString -command dotnet -commandArgs $buildargs

                # copy build results to output folder
                # \OutputRoot\dotnet\Microsoft.TemplateEngine.Core\bin\Release
                # Join-Path c:\temp one|join-path -ChildPath two|join-path -ChildPath three
                $buildBinFolder = (Join-Path $dnoutputpath -ChildPath 'Microsoft.TemplateEngine.Core'|Join-Path -ChildPath 'bin'|Join-Path -ChildPath $configuration)
                if( (-not [string]::IsNullOrWhiteSpace($buildBinFolder)) -and (Test-Path $buildBinFolder)){
                    # copy the folder to
                    Get-ChildItem $buildBinFolder | ForEach-Object{
                        Copy-Item $_.FullName -Destination $dnoutputpath -Recurse
                    }
                }
                else{
                    'bin folder not found for Microsoft.TemplateEngine.Core at [{0}]' -f $buildBinFolder | Write-Warning
                }

            }
        }
        finally{
            Set-Location $oldloc
        }
    }
}
function Update-FilesWithCommitId{
    [cmdletbinding()]
    param(
        [string]$commitId = ($env:APPVEYOR_REPO_COMMIT),

        [System.IO.DirectoryInfo]$dirToUpdate = ($outputroot),

        [Parameter(Position=2)]
        [string]$filereplacerVersion = '0.4.0-beta'
    )
    begin{
        EnsureFileReplacerInstlled
    }
    process{
        if([string]::IsNullOrEmpty($commitId)){
            try{
                $commitstr = (& git log --format="%H" -n 1)
                if($commitstr -match '\b[0-9a-f]{5,40}\b'){
                    $commitId = $commitstr
                }
            }
            catch{
                # do nothing
            }
        }

        if(![string]::IsNullOrWhiteSpace($commitId)){
            'Updating commitId from [{0}] to [{1}]' -f '$(COMMIT_ID)',$commitId | Write-Verbose

            $folder = $dirToUpdate
            $include = '*.nuspec'
            # In case the script is in the same folder as the files you are replacing add it to the exclude list
            $exclude = "$($MyInvocation.MyCommand.Name);"
            $replacements = @{
                '$(COMMIT_ID)'="$commitId"
            }
            Replace-TextInFolder -folder $folder -include $include -exclude $exclude -replacements $replacements | Write-Verbose
            'Replacement complete' | Write-Verbose
        }
    }
}

<#
.SYNOPSIS 
This will inspect the nuspec file and return the value for the Version element.
#>
function GetExistingVersion{
    [cmdletbinding()]
    param(
        [ValidateScript({test-path $_ -PathType Leaf})]
        $nuspecFile = (Join-Path $scriptDir 'Microsoft.TemplateEngine.nuspec')
    )
    process{
        ([xml](Get-Content $nuspecFile)).package.metadata.version
    }
}

function SetVersion{
    [cmdletbinding()]
    param(
        [Parameter(Position=1,Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$newversion,

        [Parameter(Position=2)]
        [ValidateNotNullOrEmpty()]
        [string]$oldversion = (GetExistingVersion),

        [Parameter(Position=3)]
        [string]$filereplacerVersion = '0.4.0-beta'
    )
    begin{
        EnsureFileReplacerInstlled
    }
    process{
        $folder = $scriptDir
        $include = '*.nuspec;*.ps*1'
        # In case the script is in the same folder as the files you are replacing add it to the exclude list
        $exclude = "$($MyInvocation.MyCommand.Name);"
        $exclude += ';build.ps1'
        $replacements = @{
            "$oldversion"="$newversion"
        }
        Replace-TextInFolder -folder $folder -include $include -exclude $exclude -replacements $replacements | Write-Verbose

        # update the .psd1 file if there is one
        $replacements = @{
            ($oldversion.Replace('-beta','.1'))=($newversion.Replace('-beta','.1'))
        }
        Replace-TextInFolder -folder $folder -include '*.psd1' -exclude $exclude -replacements $replacements | Write-Verbose
        'Replacement complete' | Write-Verbose
    }
}

# test related functions

function GetVsTestConsole{
    [cmdletbinding()]
    param(
        [string]$visualStudioVersion='14.0'
    )
    process{
        $vstest = "${env:ProgramFiles(x86)}\Microsoft Visual Studio $visualStudioVersion\Common7\IDE\CommonExtensions\Microsoft\TestWindow\vstest.console.exe"
        if(-not (Test-Path $vstest)){
            throw ('vstest runner not found at [{0}]' -f $vstest)
        }

        $vstest
    }
}

function Run-Tests{
    [cmdletbinding()]
    param(
        [switch]$disableCodeCoverage,
        [switch]$disableInIsolation,
        [switch]$disableTrx,
        [string]$frameworkValue = 'Framework45',
        [string]$testResultsDir = ($testResultsDir)
    )
    process{
        $vsoutroot = (Join-Path $outputroot 'vs')
        $testdlls = Get-ChildItem $vsoutroot $testFilePattern -Recurse -File

        if( ($testdlls -eq $null ) -or ($testdlls.Length -le 0)){
            'No tests .dlls files found [{0}] with pattern [{1}]' -f $vsoutroot,$testFilePattern | Write-Warning
            return
        }

        $vstestexe = GetVsTestConsole

        # vstest Microsoft.TemplateEngine.Net4.UnitTests.dll  /EnableCodeCoverage /InIsolation /Framework:Framework45 /logger:trx
        $testArgs = @()
        
        $testdlls.FullName|ForEach-Object {
            $testArgs += $_
        }

        if(-not $disableCodeCoverage){
            $testArgs += '/EnableCodeCoverage'
        }

        if(-not $disableInIsolation){
            $testArgs += '/InIsolation'
        }

        if(-not $disableTrx){
            $testArgs += '/logger:trx'
        }

        if($env:APPVEYOR -eq 'true'){
            $testArgs += '/logger:Appveyor'
        }

        $testArgs += ('/Framework:{0}' -f $frameworkValue)
        
        Push-Location
        try{
            Set-Location (Split-Path $testResultsDir -Parent)
            Invoke-CommandString -command $vstestexe -commandArgs $testArgs -ignoreErrors $true
        }
        finally{
            Pop-Location
        }

        if(-not $disableCodeCoverage){
            GetCoverageReport
        }
    }
}

function ConvertCoverageFileToXml{
    [cmdletbinding()]
    param(
        [string]$testResultsDir = (Join-Path $outputroot.FullName 'vs\TestResults'),        
        [string[]]$coverageFiles,
        [string]$assemblyDir = (Join-Path $outputroot.FullName 'vs\TestResults')
    )
    process{        
        if(-not (Test-Path $testResultsDir)){
            'Test results directory not fount at [{0}]' -f $testResultsDir | Write-Warning
            return
        }

        if($coverageFiles -eq $null){
            $coverageFiles = (Get-ChildItem $testResultsDir *.coverage -Recurse -File).FullName
        }

        if( ($coverageFiles -eq $null) -or ($coverageFiles.Length -le 0)){
            'No .coverage files found in [{0}]' -f $testResultsDir | Write-Warning
            return
        }
        
        $coverageexe = (GetCoverageConverterPath)

        foreach($cFile in $coverageFiles){
            $cFile = [System.IO.FileInfo]$cFile
            $xmloutputpath =(Join-Path $cFile.Directory.FullName ('{0}.coverage.xml' -f $cFile.BaseName))
            $convertArgs = @( ('"{0}"' -f $cfile.FullName), """$assemblyDir""", """$xmloutputpath""")
            Invoke-CommandString -command $coverageexe -commandArgs $convertArgs | Write-Verbose

            # return the path to the xml file
            $xmloutputpath
        }
    }
}

function GetReportGeneratorExe{
    [cmdletbinding()]
    param(
        [string]$reportGenVersion = '2.4.4'
    )
    process{
        $binpath = (Get-NuGetPackage -name 'ReportGenerator' -version $reportGenVersion -binpath)
        $reportgenexepath = (Join-Path $binpath 'ReportGenerator.exe')

        if(-not (Test-Path $reportgenexepath)){
            throw ('Unable to get ReportGenerator from NuGet, did not find file at [{1}]' -f $reportgenexepath)
        }

        $reportgenexepath
    }
}

function GetCoverageReport{
    [cmdletbinding()]
    param(
        [string]$reportTypes = 'HtmlSummary;CsvSummary'
    )
    process{
        $coverageXmlFiles = (ConvertCoverageFileToXml)
        $repgenexe = (GetReportGeneratorExe)        
        $coveragedir = (Join-Path $outputroot.FullName "vs\TestResults\coverage")
        if(-not (Test-Path $coveragedir)){
            New-Item -Path $coveragedir -ItemType Directory | Write-Verbose
        }
        # reportgen "-reports:C:\Data\mycode\Microsoft.TemplateEngine\OutputRoot\vs\TestResults\converted.coveragexml" -targetDir:C:\Data\mycode\Microsoft.TemplateEngine\OutputRoot\vs\TestResults\report\ "-reporttypes:Html;HtmlSummary;CsvSummary"

        $reportArgs = @()
        $reportArgs += ('"-reports:{0}"' -f ($coverageXmlFiles -join ';'))
        $reportArgs += ('"-targetDir:{0}"' -f $coveragedir)
        $reportArgs += ('-reporttypes:{0}' -f $reportTypes)
        Invoke-CommandString -command $repgenexe -commandArgs $reportArgs

        Add-AppveyorArtifact -pathToAdd ((Get-ChildItem -Path $coveragedir -Recurse -File).FullName)

        $summaryfile = (([System.IO.FileInfo](Join-Path $coveragedir 'Summary.csv')).FullName)
        if(Test-Path $summaryfile){
            '************** Code Coverage Report **************' | write-Output
            Get-Content $summaryfile | Write-Output
            '**************************************************' | write-Output
        }
    }
}

function Add-AppveyorArtifact{
    [cmdletbinding()]
    param(
        [string[]]$pathToAdd
    )
    process{
        $pushartifactcommand = (get-command 'Push-AppveyorArtifact' -ErrorAction SilentlyContinue)
        if($pushartifactcommand -ne $null){
            foreach($artifactPath in $pathToAdd){           
                try{
                    Push-AppveyorArtifact $artifactPath
                }
                catch{
                    'Unable to add appveyor artifact [{0}]. Error [{1}]' -f $artifactPath,$_.Exception | Write-Warning
                }    
            }
        }
    }
}

function GetCoverageConverterPath{
    [cmdletbinding()]
    param(
        [string]$sayedToolsVersion=($sayedToolsVersion)
    )
    process{
        $binpath = (Get-NuGetPackage -name 'sayed-tools' -version $sayedToolsVersion -binpath)
        $exepath = (([System.IO.FileInfo](Join-Path $binpath 'CoverageConverter.exe')).FullName)

        if(-not (Test-Path $exepath)){
            throw ('Unable to find exe at [{0}]' -f $exepath)
        }

        # return the path
        $exepath
    }
}

function FullBuild{
    [cmdletbinding()]
    param()
    process{
        EnsurePsbuildInstlled
        CleanOutputFolder
        InternalEnsure-DirectoryExists -path $outputroot
        Import-NuGetPowershell

        if(-not ($SkipInstallDotNet) ){
            InstallDotNetCli
        }

        RestoreNuGetPackages

        CopyStaticFilesToOutputDir

        BuildSolution
        Update-FilesWithCommitId
        
        try{
            Run-Tests
        }
        catch{
            '**********************************************' | Write-Output
            $_.Exception | Write-Output
            '**********************************************' | Write-Output
            $publishToNuget = $false
        }
        
        'Building NuGet package' | Write-Output
        Build-NuGetPackage

        if($publishToNuget){
            (Get-ChildItem -Path ($outputPathNuget) 'Microsoft.*.nupkg').FullName | PublishNuGetPackage -nugetApiKey $nugetApiKey
        }
    }
}

try{
    if($getversion -eq $true){
        GetExistingVersion
    }
    elseif($setversion -eq $true){
        SetVersion -newversion $newversion
    }
    else{
        FullBuild
    }
}
catch{
    throw ("{0}`r`n{1}" -f $_.Exception,(Get-PSCallStack|format-table|Out-String))
}

