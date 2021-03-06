using module ".\FFToolsRepository.psm1"
using module ".\ConfigRepository.psm1"
using module ".\EmailRepository.psm1"
using module ".\EnvVariableHelper.psm1"
using module ".\ScriptVersionMigrator.psm1"

# Variables
$LocationToSearch = "/media";
$ConfigDirectory = "/config"
$ProblematicAudioFormats = Get-StringArrayEnvVariable -Name "PROBLEMATIC_AUDIO_FORMATS" -DefaultValue @("truehd", "eac3")
$WaitBetweenScansInSeconds = Get-IntEnvVariable -Name "WAIT_BETWEEN_SCANS_IN_SECONDS" -DefaultValue 43200
$AmendedAudioFormat = Get-StringEnvVariable -Name "AMENDED_AUDIO_FORMAT" -DefaultValue "ac3"
$CurrentScriptVersion = "1.1.0"

function Convert-File {
    Param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo] $File
    )

    Write-Host "Checking file: $File"
    $AnalyzedAudioStreams = Get-AnalyzedAudioStreams -File $File -ProblematicAudioFormats $ProblematicAudioFormats
    if ($null -eq $AnalyzedAudioStreams) {
        Set-FileAsScannedOrFixed $File "N/A"
        Write-Host "Not a media file. Skipping file: '$File'"
        Write-Host "-------------------------"
        continue;
    }
    
    if ($AnalyzedAudioStreams.Length -eq 0) {
        $Duration = Get-MediaDuration $File
        Set-FileAsScannedOrFixed $File $Duration
        Write-Host "No audio found. Skipping file: '$File'"
        Write-Host "-------------------------"
        continue;
    }

    Write-Host "Found audio formats: '$(($AnalyzedAudioStreams | Select-Object -ExpandProperty codecName) -join ", ")'"
    if (($AnalyzedAudioStreams | Where-Object { $_.IsProblematic }).Length -eq 0) {
        $Duration = Get-MediaDuration $File
        Set-FileAsScannedOrFixed $File $Duration
        Write-Host "No issues found. Skipping file: '$File'"
        Write-Host "-------------------------"
        continue;
    }

    Write-Host "Trying to automatically fix: '$File'"
    $OriginalFileLength = $File.Length;
    $OriginalFileLastWriteTimeUtc = $File.LastWriteTimeUtc;
    $NewFileName = Join-Path $File.DirectoryName "$($File.BaseName)-1$($File.Extension)"
    $ConversionResult = Convert-ProblematicAudioStreams -OriginalFile $File -NewFileName $NewFileName -AnalyzedAudioStreams $AnalyzedAudioStreams -AmendedAudioFormat $AmendedAudioFormat
    if ($ConversionResult.ExitCode) {
        Write-Host "Failed to automatically resolve the issue with file: '$File'" 
        Write-Host $ConversionResult.Output
        Remove-Item -Path $NewFileName -Force -ErrorAction Ignore
        Send-TranscodingFailureEmail -File $File -AnalyzedAudioStreams $AnalyzedAudioStreams -AmendedAudioFormat $AmendedAudioFormat -Logs $ConversionResult.Output
        Write-Host "-------------------------"
        continue;
    }
 
    $File.Refresh();
    if ($OriginalFileLength -eq $File.Length -and $OriginalFileLastWriteTimeUtc -eq $File.LastWriteTimeUtc) {
        Remove-Item -Path $File -Force
        Rename-Item -Path $NewFileName -NewName $File.Name
        $File.Refresh();
        $Duration = Get-MediaDuration $File
        Set-FileAsScannedOrFixed $File $Duration
        Write-Host "File has been fixed."
        Write-Host "-------------------------"
    }
    else { 
        Remove-Item -Path $NewFileName -Force
        Write-Host "File has been changed during transcoding. Try again next time."
        Write-Host "-------------------------"
    }
}

function Get-FilesToCheck {
    $AllFiles = @(Get-ChildItem $LocationToSearch -Include "*.*" -Recurse -File);
    $AllUncheckedFiles = Get-UncheckedFilesAndRemoveDeletedFilesFromConfig $AllFiles
    return $AllUncheckedFiles;
}

function New-DirectoryIfDoesNotExist {
    Param(
        [Parameter(Mandatory = $true)]
        [string] $DirectoryPath
    )

    If (!(Test-Path $DirectoryPath)) {
        New-Item -ItemType Directory -Force -Path $DirectoryPath | Out-Null
    }
}

function Main {
    New-DirectoryIfDoesNotExist -DirectoryPath $LocationToSearch
    New-DirectoryIfDoesNotExist -DirectoryPath $ConfigDirectory
    Initialize-EmailRepository
    Initialize-ConfigRepository -ConfigDirectory $ConfigDirectory -CurrentVersion $CurrentScriptVersion

    Move-ScriptToNewVersion -CurrentVersion $CurrentScriptVersion

    while ($true) {
        $FilesToCheck = Get-FilesToCheck
        ForEach ($File in $FilesToCheck) {
            try {
                Convert-File -File $File
            }
            catch { 
                Write-Host $_.Exception
            }
        }
        Save-ConfigToFileAndResetRepository
        Write-Host "Scanning is complete. Sleeping for $WaitBetweenScansInSeconds seconds."
        Start-Sleep -s $WaitBetweenScansInSeconds
    }
}

Main
