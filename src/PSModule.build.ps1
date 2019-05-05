<#
.SYNOPSIS
    An Invoke-Build Build file.
.DESCRIPTION
    This build file is configured with the intent of running AWS CodeBuild builds, but will work locally as well.

    Build steps can include:
        - Clean
        - ValidateRequirements
        - Analyze
        - Test
        - CreateHelp
        - Build
        - Archive
.EXAMPLE
    Invoke-Build

    This will perform the default build tasks: see below for the default task execution
.EXAMPLE
    Invoke-Build -Task Analyze,Test

    This will perform only the Analyze and Test tasks.
.NOTES
    This build will pull in configurations from the "<module>.Settings.ps1" file as well, where users can more easily customize the build process if required.
    The 'InstallDependencies' task isn't present here. pre-requisite modules are installed at a previous step in the pipeline.
#>

#Include: Settings
$ModuleName = (Split-Path -Path $BuildFile -Leaf).Split('.')[0]
. "./$ModuleName.Settings.ps1"

#Default Build
<%
If ($PLASTER_PARAM_CodingStyle -ne 'None') {
    @'
task . Clean, ValidateRequirements, Format, Analyze, Test, CreateHelpStart, Build, Archive
'@
}
else {
    @'
task . Clean, ValidateRequirements, Analyze, Test, CreateHelpStart, Build, Archive
'@
}
%>

#Local testing build process
task TestLocal Clean, Analyze, Test

#Local help file creation process
task HelpLocal CreateHelp, UpdateCBH

# Pre-build variables to be used by other portions of the script
Enter-Build {
    $script:ModuleName = (Split-Path -Path $BuildFile -Leaf).Split('.')[0]

    # Identify other required paths
    $script:ModuleSourcePath = Join-Path -Path $BuildRoot -ChildPath $script:ModuleName
    $script:ModuleFiles = Join-Path -Path $script:ModuleSourcePath -ChildPath '*'

    $script:ModuleManifestFile = Join-Path -Path $script:ModuleSourcePath -ChildPath "$($script:ModuleName).psd1"

    $manifestInfo = Import-PowerShellDataFile -Path $script:ModuleManifestFile
    $script:ModuleVersion = $manifestInfo.ModuleVersion
    $script:ModuleDescription = $manifestInfo.Description
    $Script:FunctionsToExport = $manifestInfo.FunctionsToExport

    $script:TestsPath = Join-Path -Path $BuildRoot -ChildPath 'Tests'
    $script:UnitTestsPath = Join-Path -Path $script:TestsPath -ChildPath 'Unit'
    $script:InfraTestsPath = Join-Path -Path $script:TestsPath -ChildPath 'Infrastructure'

    $script:ArtifactsPath = Join-Path -Path $BuildRoot -ChildPath 'Artifacts'
    $script:ArchivePath = Join-Path -Path $BuildRoot -ChildPath 'Archive'

    $script:BuildModuleRootFile = Join-Path -Path $script:ArtifactsPath -ChildPath "$($script:ModuleName).psm1"
}#Enter-Build

#Synopsis: Validate system requirements are met
task ValidateRequirements {
    #running at least powershell 5?
    assert ($PSVersionTable.PSVersion.Major.ToString() -ge '5') 'At least Powershell 5 is required for this build to function properly'
}#ValidateRequirements

#Synopsis: Clean Artifacts Directory
task Clean {
    Write-Host "      Clean up our Artifacts/Archive directory"

    $null = Remove-Item $script:ArtifactsPath -Force -Recurse -ErrorAction 0
    $null = New-Item $script:ArtifactsPath -ItemType:Directory
    $null = Remove-Item $script:ArchivePath -Force -Recurse -ErrorAction 0
    $null = New-Item $script:ArchivePath -ItemType:Directory

    Write-Host -ForegroundColor Green '...Clean Complete!'
    <#
    foreach ($path in $script:ArtifactsPath,$script:ArchivePath) {
        if (Test-Path -Path $path) {
            $null = Remove-Item -Path $path -Recurse -Force
        }
        $null = New-Item -ItemType Directory -Path $path -Force
    }
    #>
}#Clean

task Format {
    Write-Host "      Performing code styling checks"
    #Copy-Item -Path "$script:ModuleSourcePath\*" -Destination $script:ArtifactsPath -Exclude *.psd1, *.psm1 -Recurse -ErrorAction Stop
    $a = Get-ChildItem -Path $script:ModuleSourcePath -Exclude *.psd1, *.psm1 -Recurse -ErrorAction Stop | Where-Object { -not $_.PSIsContainer }
    foreach ($file in $a) {
        $raw = $null
        $eval = $null
        $raw = Get-Content -Path $file.FullName -Raw
        $eval = Compare-Object -ReferenceObject $raw -DifferenceObject (Invoke-Formatter -ScriptDefinition $raw)
        if ($null -ne $eval) {
            throw "$($file.Name) does not adhere to styling guidelines."
        }
    }
    Write-Host -ForegroundColor Green '...Code styling checks complete!'
}

#Synopsis: Invokes Script Analyzer against the Module source path
task Analyze {
    Write-Host "      Performing Module ScriptAnalyzer checks"
    $scriptAnalyzerParams = @{
        Path    = $script:ModuleSourcePath
        Setting = "PSScriptAnalyzerSettings.psd1"
        Recurse = $true
        Verbose = $false
    }

    $scriptAnalyzerResults = Invoke-ScriptAnalyzer @scriptAnalyzerParams

    if ($scriptAnalyzerResults) {
        $scriptAnalyzerResults | Format-Table
        throw 'One or more PSScriptAnalyzer errors/warnings where found.'
    }
    else {
        Write-Host -ForegroundColor Green '...Module Analyze Complete!'
    }
}#Analyze

#Synopsis: Invokes Script Analyzer against the Tests path if it exists
task AnalyzeTests -After Analyze {
    if (Test-Path -Path $script:TestsPath) {
        Write-Host "      Performing Test ScriptAnalyzer checks"
        $scriptAnalyzerParams = @{
            Path    = $script:TestsPath
            Setting = "PSScriptAnalyzerSettings.psd1"
            Recurse = $true
            Verbose = $false
        }

        $scriptAnalyzerResults = Invoke-ScriptAnalyzer @scriptAnalyzerParams

        if ($scriptAnalyzerResults) {
            $scriptAnalyzerResults | Format-Table
            throw 'One or more PSScriptAnalyzer errors/warnings where found.'
        }
        else {
            Write-Host -ForegroundColor Green '...Test Analyze Complete!'
        }
    }
}#AnalyzeTests

#Synopsis: Invokes all Pester Unit Tests in the Tests\Unit folder (if it exists)
task Test {
    $codeCovPath = "$script:ArtifactsPath\ccReport\"
    if (-not(Test-Path $codeCovPath)) {
        New-Item -Path $codeCovPath -ItemType Directory | Out-Null
    }
    if (Test-Path -Path $script:UnitTestsPath) {
        Write-Host -NoNewLine "      Performing Pester Unit Tests"
        $invokePesterParams = @{
            Path                         = 'Tests\Unit'
            Strict                       = $true
            PassThru                     = $true
            Verbose                      = $false
            EnableExit                   = $false
            CodeCoverage                 = "$ModuleName\*\*.ps1"
            CodeCoverageOutputFile       = "$codeCovPath\codecoverage.xml"
            CodeCoverageOutputFileFormat = 'JaCoCo'
        }

        # Publish Test Results as NUnitXml
        $testResults = Invoke-Pester @invokePesterParams

        # This will output a nice json for each failed test (if running in CodeBuild)
        if ($env:CODEBUILD_BUILD_ARN) {
            $testResults.TestResult | ForEach-Object {
                if ($_.Result -ne 'Passed') {
                    ConvertTo-Json -InputObject $_ -Compress
                }
            }
        }

        $numberFails = $testResults.FailedCount
        assert($numberFails -eq 0) ('Failed "{0}" unit tests.' -f $numberFails)

        # Ensure our builds fail until if below a minimum defined code test coverage threshold
        $coverageThreshold = 50

        if ($testResults.CodeCoverage.NumberOfCommandsExecuted -ne 0) {
            $coveragePercent = '{0:N2}' -f ($testResults.CodeCoverage.NumberOfCommandsExecuted / $testResults.CodeCoverage.NumberOfCommandsAnalyzed * 100)

            <#
            if ($testResults.CodeCoverage.NumberOfCommandsMissed -gt 0) {
                'Failed to analyze "{0}" commands' -f $testResults.CodeCoverage.NumberOfCommandsMissed
            }
            Write-Host "PowerShell Commands not tested:`n$(ConvertTo-Json -InputObject $testResults.CodeCoverage.MissedCommands)"
            #>
            if ([Int]$coveragePercent -lt $coverageThreshold) {
                throw ('Failed to meet code coverage threshold of {0}% with only {1}% coverage' -f $coverageThreshold, $coveragePercent)
            }
            else {
                Write-Host "$('Covered {0}% of {1} analyzed commands in {2} files.' -f $coveragePercent,$testResults.CodeCoverage.NumberOfCommandsAnalyzed,$testResults.CodeCoverage.NumberOfFilesAnalyzed)"
                Write-Host -ForegroundColor Green '...Pester Unit Tests Complete!'
            }
        }
        else {
            # account for new module build condition
            Write-Host "Code coverage check skipped. No commands to execute." -ForegroundColor Magenta
        }

    }
    if (Test-Path -Path $script:InfraTestsPath) {
        Write-Host -NoNewLine "      Performing Pester Infrastructure Tests"
        $invokePesterParams = @{
            Path       = '..\..\Tests\Infrastructure'
            Strict     = $true
            PassThru   = $true
            Verbose    = $false
            EnableExit = $false
        }
        Write-Host $invokePesterParams.path
        # Publish Test Results as NUnitXml
        $testResults = Invoke-Pester @invokePesterParams

        # This will output a nice json for each failed test (if running in CodeBuild)
        if ($env:CODEBUILD_BUILD_ARN) {
            $testResults.TestResult | ForEach-Object {
                if ($_.Result -ne 'Passed') {
                    ConvertTo-Json -InputObject $_ -Compress
                }
            }
        }

        $numberFails = $testResults.FailedCount
        assert($numberFails -eq 0) ('Failed "{0}" unit tests.' -f $numberFails)
        Write-Host -ForegroundColor Green '...Pester Infrastructure Tests Complete!'
    }
}#Test

#Synopsis: Used primarily during active development to generate xml file to graphically display code coverage in VSCode using Coverage Gutters
task DevCC {
    Write-Host '      Generating code coverage report at root.'
    $invokePesterParams = @{
        Path                   = 'Tests\Unit'
        CodeCoverage           = "$ModuleName\*\*.ps1"
        CodeCoverageOutputFile = '..\..\..\cov.xml'
    }
    Invoke-Pester @invokePesterParams
    Write-Host -ForegroundColor Green '...Code Coverage report generated!'
}#DevCC

# Synopsis: Build help files for module
task CreateHelpStart {
    Write-Host '      Performing all help related actions.'
    Write-Host 'Importing platyPS v0.12.0'
    Import-Module platyPS -RequiredVersion 0.12.0
}#CreateHelpStart

# Synopsis: Build help files for module and fail if help information is missing
task CreateMarkdownHelp -After CreateHelpStart {
    $ModulePage = "$($script:ArtifactsPath)\docs\$($ModuleName).md"

    $markdownParams = @{
        Module         = $ModuleName
        OutputFolder   = "$($script:ArtifactsPath)\docs\"
        Force          = $true
        WithModulePage = $true
        Locale         = 'en-US'
        FwLink         = "NA"
        HelpVersion    = $script:ModuleVersion
    }
    $null = New-MarkdownHelp @markdownParams

    # Replace each missing element we need for a proper generic module page .md file
    $ModulePageFileContent = Get-Content -raw $ModulePage
    $ModulePageFileContent = $ModulePageFileContent -replace '{{Manually Enter Description Here}}', $script:ModuleDescription
    $Script:FunctionsToExport | Foreach-Object {
        Write-Host "      Updating definition for the following function: $($_)"
        $TextToReplace = "{{Manually Enter $($_) Description Here}}"
        $ReplacementText = (Get-Help -Detailed $_).Synopsis
        $ModulePageFileContent = $ModulePageFileContent -replace $TextToReplace, $ReplacementText
    }

    $ModulePageFileContent | Out-File $ModulePage -Force -Encoding:utf8

    $MissingDocumentation = Select-String -Path "$($script:ArtifactsPath)\docs\*.md" -Pattern "({{.*}})"
    if ($MissingDocumentation.Count -gt 0) {
        Write-Host -ForegroundColor Yellow ''
        Write-Host -ForegroundColor Yellow '   The documentation that got generated resulted in missing sections which should be filled out.'
        Write-Host -ForegroundColor Yellow '   Please review the following sections in your comment based help, fill out missing information and rerun this build:'
        Write-Host -ForegroundColor Yellow '   (Note: This can happen if the .EXTERNALHELP CBH is defined for a function before running this build.)'
        Write-Host ''
        Write-Host -ForegroundColor Yellow "Path of files with issues: $($script:ArtifactsPath)\docs\"
        Write-Host ''
        $MissingDocumentation | Select-Object FileName, Matches | Format-Table -AutoSize
        Write-Host -ForegroundColor Yellow ''

        throw 'Missing documentation. Please review and rebuild.'
    }

    Write-Host '      Creating markdown documentation with PlatyPS'
    Write-Host -ForegroundColor Green '...Complete!'
}#CreateMarkdownHelp

# Synopsis: Build the external xml help file from markdown help files with PlatyPS
task CreateExternalHelp -After CreateMarkdownHelp {
    Write-Host '      Creating external xml help file'
    $null = New-ExternalHelp "$($script:ArtifactsPath)\docs" -OutputPath "$($script:ArtifactsPath)\en-US\" -Force
    Write-Host -ForeGroundColor green '...Complete!'
}#CreateExternalHelp

task CreateHelpComplete -After CreateExternalHelp {
    Write-Host -ForegroundColor Green '...CreateHelp Complete!'
}#CreateHelpStart

# Synopsis: Replace comment based help (CBH) with external help in all public functions for this project
task UpdateCBH -Before Build {
    Copy-Item -Path "$script:ModuleSourcePath\*" -Destination $script:ArtifactsPath -Exclude *.psd1, *.psm1 -Recurse -ErrorAction Stop
    $ExternalHelp = @"
<#
.EXTERNALHELP $($ModuleName)-help.xml
#>
"@

    $CBHPattern = "(?ms)(\<#.*\.SYNOPSIS.*?#>)"
    Get-ChildItem -Path "$($script:ArtifactsPath)\Public\*.ps1" -File | `
        ForEach-Object {
        $FormattedOutFile = $_.FullName
        Write-Output "      Replacing CBH in file: $($FormattedOutFile)"
        $UpdatedFile = (Get-Content  $FormattedOutFile -raw) -replace $CBHPattern, $ExternalHelp
        $UpdatedFile | Out-File -FilePath $FormattedOutFile -force -Encoding:utf8
    }
}#UpdateCBH

# Synopsis: Builds the Module to the Artifacts folder
task Build {
    Write-Host '      Performing Module Build'

    Write-Host '        Copying Module Manifest to Artifacts...'
    Copy-Item -Path $script:ModuleManifestFile -Destination $script:ArtifactsPath -Recurse -ErrorAction Stop
    #Copy-Item -Path $script:ModuleSourcePath\bin -Destination $script:ArtifactsPath -Recurse -ErrorAction Stop

    Write-Host '        Merging Public and Private functions to one module file'
    #$private = "$script:ModuleSourcePath\Private"
    $scriptContent = [System.Text.StringBuilder]::new()
    #$powerShellScripts = Get-ChildItem -Path $script:ModuleSourcePath -Filter '*.ps1' -Recurse
    $powerShellScripts = Get-ChildItem -Path $script:ArtifactsPath -Filter '*.ps1' -Recurse
    foreach ($script in $powerShellScripts) {
        $null = $scriptContent.Append((Get-Content -Path $script.FullName -Raw))
        $null = $scriptContent.AppendLine('')
        $null = $scriptContent.AppendLine('')
    }
    $scriptContent.ToString() | Out-File -FilePath $script:BuildModuleRootFile -Encoding utf8 -Force

    Write-Host '        Cleaning up artifacts location'
    #cleanup artifacts that are no longer required
    if (Test-Path "$($script:ArtifactsPath)\Public") {
        Remove-Item "$($script:ArtifactsPath)\Public" -Recurse -Force -ErrorAction Stop
    }
    if (Test-Path "$($script:ArtifactsPath)\Private") {
        Remove-Item "$($script:ArtifactsPath)\Private" -Recurse -Force -ErrorAction Stop
    }

    Write-Host '        Overwriting docs output'
    Move-Item "$($script:ArtifactsPath)\docs\*.md" -Destination "..\docs\" -Force
    Remove-Item "$($script:ArtifactsPath)\docs" -Recurse -Force -ErrorAction Stop

    Write-Host -ForegroundColor Green '...Build Complete!'
}#Build

#Synopsis: Creates an archive of the built Module
task Archive {
    Write-Host '      Performing Archive'
    $archivePath = Join-Path -Path $BuildRoot -ChildPath 'Archive'
    if (Test-Path -Path $archivePath) {
        $null = Remove-Item -Path $archivePath -Recurse -Force
    }

    $null = New-Item -Path $archivePath -ItemType Directory -Force

    $zipFileName = '{0}_{1}_{2}.{3}.zip' -f $script:ModuleName, $script:ModuleVersion, ([DateTime]::UtcNow.ToString("yyyyMMdd")), ([DateTime]::UtcNow.ToString("hhmmss"))
    $zipFile = Join-Path -Path $archivePath -ChildPath $zipFileName

    if ($PSEdition -eq 'Desktop') {
        Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
    }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($script:ArtifactsPath, $zipFile)
    Write-Host -ForegroundColor Green '...Archive Complete!'
}#Archive