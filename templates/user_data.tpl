<powershell>

function run-once-on-login ($taskname, $action) {
    $trigger = New-ScheduledTaskTrigger -AtLogon -RandomDelay $(New-TimeSpan -seconds 30)
    $trigger.Delay = "PT30S"
    $selfDestruct = New-ScheduledTaskAction -Execute powershell.exe -Argument "-WindowStyle Hidden -Command `"Disable-ScheduledTask -TaskName $taskname`""
    Register-ScheduledTask -TaskName $taskname -Trigger $trigger -Action $action,$selfDestruct -RunLevel Highest
}

function install-chocolatey {
    Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
    choco feature enable -n allowGlobalConfirmation
}

function install-parsec-cloud-preparation-tool {
    # https://github.com/jamesstringerparsec/Parsec-Cloud-Preparation-Tool
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $downloadPath = "C:\Parsec-Cloud-Preparation-Tool.zip"
    $extractPath = "C:\Parsec-Cloud-Preparation-Tool"
    $repoPath = Join-Path $extractPath "Parsec-Cloud-Preparation-Tool-master"
    $copyPath = Join-Path $desktopPath "ParsecTemp"
    $scriptEntrypoint = Join-Path $repoPath "PostInstall\PostInstall.ps1"

    if (!(Test-Path -Path $extractPath)) {
        [Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        (New-Object System.Net.WebClient).DownloadFile("https://github.com/jamesstringerparsec/Parsec-Cloud-Preparation-Tool/archive/master.zip", $downloadPath)
        New-Item -Path $extractPath -ItemType Directory
        Expand-Archive $downloadPath -DestinationPath $extractPath
        Remove-Item $downloadPath

        New-Item -Path $copyPath -ItemType Directory
        Copy-Item $repoPath/* $copyPath -Recurse -Container

        # Setup scheduled task to run Parsec-Cloud-Preparation-Tool once at logon
        $action = New-ScheduledTaskAction -Execute powershell.exe -WorkingDirectory $repoPath -Argument "-Command `"$scriptEntrypoint -DontPromptPasswordUpdateGPU`""
        run-once-on-login "Parsec-Cloud-Preparation-Tool" $action
    }
}

function install-admin-password {
    $password = (Get-SSMParameter -WithDecryption $true -Name '${password_ssm_parameter}').Value
    net user Administrator "$password"
}

function install-autologin {
    Install-Module -Name DSCR_AutoLogon -Force
    Import-Module -Name DSCR_AutoLogon
    $password = (Get-SSMParameter -WithDecryption $true -Name '${password_ssm_parameter}').Value
    $regPath = "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    [microsoft.win32.registry]::SetValue($regPath, "AutoAdminLogon", "1")
    [microsoft.win32.registry]::SetValue($regPath, "DefaultUserName", "Administrator")
    Remove-ItemProperty -Path $regPath -Name "DefaultPassword" -ErrorAction SilentlyContinue
    (New-Object PInvoke.LSAUtil.LSAutil -ArgumentList "DefaultPassword").SetSecret($password)
}

function install-graphic-driver {
    # https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/install-nvidia-driver.html#nvidia-gaming-driver

    if (!(Test-Path -Path "C:\Program Files\NVIDIA Corporation\NVSMI")) {
        $ExtractionPath = "C:\nvidia-driver\driver"
        $Bucket = ""
        $KeyPrefix = ""
        $InstallerFilter = "*win10*"

        %{ if regex("^g[0-9]+", var.instance_type) == "g3" }

        # GRID driver for g3
        $Bucket = "ec2-windows-nvidia-drivers"
        $KeyPrefix = "latest"

        # download driver
        $Objects = Get-S3Object -BucketName $Bucket -KeyPrefix $KeyPrefix -Region ${region}
        foreach ($Object in $Objects) {
            $LocalFileName = $Object.Key
            if ($LocalFileName -ne '' -and $Object.Size -ne 0) {
                $LocalFilePath = Join-Path $ExtractionPath $LocalFileName
                Copy-S3Object -BucketName $Bucket -Key $Object.Key -LocalFile $LocalFilePath -Region ${region}
            }
        }

        # disable licencing page in control panel
        New-ItemProperty -Path "HKLM:\SOFTWARE\NVIDIA Corporation\Global\GridLicensing" -Name "NvCplDisableManageLicensePage" -PropertyType "DWord" -Value "1"

        %{ else }
        %{ if regex("^g[0-9]+", var.instance_type) == "g4" || regex("^g[0-9]+", var.instance_type) == "g5" }

        # vGaming driver for g4/g5
        $Bucket = "nvidia-gaming"
        $KeyPrefix = "windows/latest"

        # download and extract driver
        $Objects = Get-S3Object -BucketName $Bucket -KeyPrefix $KeyPrefix -Region ${region}
        foreach ($Object in $Objects) {
            if ($Object.Size -ne 0) {
                $LocalFileName = "C:\nvidia-driver\driver.zip"
                Copy-S3Object -BucketName $Bucket -Key $Object.Key -LocalFile $LocalFileName -Region ${region}
                Expand-Archive $LocalFileName -DestinationPath $ExtractionPath
                break
            }
        }

        # install licence
        Copy-S3Object -BucketName $Bucket -Key "GridSwCert-Archive/GridSwCert-Windows_2024_10.cert" -LocalFile "C:\Users\Public\Documents\GridSwCert.txt" -Region ${region}
        [microsoft.win32.registry]::SetValue("HKEY_LOCAL_MACHINE\SOFTWARE\NVIDIA Corporation\Global", "vGamingMarketplace", 0x02)

        %{ endif }
        %{ endif }

        if (Test-Path -Path $ExtractionPath) {
            # install driver
            $InstallerFile = Get-ChildItem -path $ExtractionPath -Include $InstallerFilter -Recurse | ForEach-Object { $_.FullName }
            Start-Process -FilePath $InstallerFile -ArgumentList "/s /n" -Wait

            # install task to disable second monitor on login
            $trigger = New-ScheduledTaskTrigger -AtLogon
            $action = New-ScheduledTaskAction -Execute displayswitch.exe -Argument "/internal"
            Register-ScheduledTask -TaskName "disable-second-monitor" -Trigger $trigger -Action $action -RunLevel Highest

            # cleanup
            Remove-Item -Path "C:\nvidia-driver" -Recurse
        }
        else {
            $action = New-ScheduledTaskAction -Execute powershell.exe -Argument "-WindowStyle Hidden -Command `"(New-Object -ComObject Wscript.Shell).Popup('Automatic GPU driver installation is unsupported for this instance type: ${var.instance_type}. Please install them manually.')`""
            run-once-on-login "gpu-driver-warning" $action
        }
    }
}

function mount-games-volume {
    # Wait for the games volume to be attached
    $driveLetter = "${games_volume_drive}"
    $maxRetries = 30
    $retryCount = 0

    # Find the secondary disk (not the root volume)
    $disk = $null
    while ($retryCount -lt $maxRetries) {
        $disk = Get-Disk | Where-Object { $_.Number -ne 0 -and $_.Number -ne $null } | Select-Object -First 1
        if ($disk) { break }
        Start-Sleep -Seconds 10
        $retryCount++
    }

    if (-not $disk) {
        Write-Output "Games volume not found after waiting"
        return
    }

    # Initialize and format if the disk is raw (first use)
    if ($disk.PartitionStyle -eq "RAW") {
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT
        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $driveLetter
        Format-Volume -DriveLetter $driveLetter -FileSystem NTFS -NewFileSystemLabel "Games" -Confirm:$false
    }
    else {
        # Disk already formatted — just assign drive letter
        $partition = Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -ne "Reserved" -and $_.Type -ne "System" } | Select-Object -First 1
        if ($partition -and -not $partition.DriveLetter) {
            Set-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -NewDriveLetter $driveLetter
        }
    }
}

function install-idle-shutdown {
    $scriptDir = "C:\cloudrig"
    $scriptPath = Join-Path $scriptDir "idle-shutdown.ps1"
    $counterPath = Join-Path $scriptDir "idle-counter.txt"

    New-Item -Path $scriptDir -ItemType Directory -Force

    # Write the idle monitor script
    @'
$counterPath = "C:\cloudrig\idle-counter.txt"
$timeoutMinutes = ${idle_shutdown_timeout_minutes}
$checkIntervalMinutes = 5
$gpuIdleThreshold = 10

# Query GPU utilization via nvidia-smi
try {
    $gpuUtil = & "C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe" --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>$null
    $gpuPercent = [int]($gpuUtil.Trim())
} catch {
    # nvidia-smi not available yet (driver not installed), skip this check
    exit 0
}

# Read current idle counter
if (Test-Path $counterPath) {
    $counter = [int](Get-Content $counterPath)
} else {
    $counter = 0
}

if ($gpuPercent -lt $gpuIdleThreshold) {
    $counter++
} else {
    $counter = 0
}

Set-Content -Path $counterPath -Value $counter

$idleMinutes = $counter * $checkIntervalMinutes
if ($idleMinutes -ge $timeoutMinutes) {
    Stop-Computer -Force
}
'@ | Set-Content -Path $scriptPath -Encoding UTF8

    # Register scheduled task to run every 5 minutes
    $action = New-ScheduledTaskAction -Execute powershell.exe -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName "cloudrig-idle-shutdown" -Action $action -Trigger $trigger -RunLevel Highest -Description "Shuts down instance after ${idle_shutdown_timeout_minutes} minutes of GPU idle"
}

install-chocolatey
Install-PackageProvider -Name NuGet -Force
choco install awstools.powershell

mount-games-volume

%{ if var.install_parsec }
install-parsec-cloud-preparation-tool
%{ endif }

install-admin-password

%{ if var.install_auto_login }
install-autologin
%{ endif }

%{ if var.install_graphic_card_driver }
install-graphic-driver
%{ endif }

%{ if var.install_steam }
choco install steam
%{ endif }

%{ if var.install_gog_galaxy }
choco install goggalaxy
%{ endif }

%{ if var.install_uplay }
choco install uplay
%{ endif }

%{ if var.install_ea_app }
choco install ea-app
%{ endif }

%{ if var.install_epic_games_launcher }
choco install epicgameslauncher
%{ endif }

%{ if idle_shutdown_timeout_minutes > 0 }
install-idle-shutdown
%{ endif }

</powershell>
