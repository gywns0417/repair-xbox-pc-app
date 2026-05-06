#requires -RunAsAdministrator
param(
    [switch]$NoPause,
    [switch]$NoCertImport,
    [string]$LogPath
)

<#
  Xbox Game Pass 앱 설치 오류 (0x80096004) PC방 일괄 해결 스크립트
  Version: 1.2.0

  - Windows Update 관련 서비스 강제 활성화
  - Windows Update Blocker/WubLock 방식의 서비스 잠금 복구
  - 서비스 레지스트리 ACL이 ReadKey로 잠긴 PC방 환경 복구
  - svchost 그룹에서 wuauserv가 제거된 환경 복구
  - SoftwareDistribution 경로가 파일로 막힌 PC방 환경 복구
  - Windows Update를 통해 최신 루트 인증서 갱신
#>

$ScriptVersion = '1.2.0'
$ErrorActionPreference = 'Continue'
$Host.UI.RawUI.WindowTitle = "Xbox Game Pass 설치 오류 해결 (PC방용) v$ScriptVersion"

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $logName = 'XboxGamePass_PCBang_Fix_v{0}_{1}.log' -f $ScriptVersion, (Get-Date -Format 'yyyyMMddHHmmss')
    $LogPath = Join-Path $PSScriptRoot $logName
}

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host $Message -ForegroundColor $Color
    try {
        Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch {
        Write-Host "  [WARN] 로그 기록 실패: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Write-Step($msg) { Write-Log $msg ([ConsoleColor]::Cyan) }
function Write-OK($msg)   { Write-Log "  [OK]   $msg" ([ConsoleColor]::Green) }
function Write-Warn($msg) { Write-Log "  [WARN] $msg" ([ConsoleColor]::Yellow) }
function Write-Err($msg)  { Write-Log "  [FAIL] $msg" ([ConsoleColor]::Red) }

function Wait-BeforeExit {
    if (-not $NoPause) {
        Read-Host '엔터를 눌러 종료'
    }
}

function Initialize-PrivilegeHelper {
    if ('XboxPcRepair.NativePrivilege' -as [type]) {
        return
    }

    Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace XboxPcRepair {
    public static class NativePrivilege {
        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        public struct TokPriv1Luid {
            public int Count;
            public long Luid;
            public int Attr;
        }

        [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr processHandle, int desiredAccess, ref IntPtr tokenHandle);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool LookupPrivilegeValue(string host, string name, ref long luid);

        [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
        private static extern bool AdjustTokenPrivileges(IntPtr tokenHandle, bool disableAllPrivileges, ref TokPriv1Luid newState, int length, IntPtr previousState, IntPtr returnLength);

        [DllImport("kernel32.dll", ExactSpelling = true)]
        private static extern IntPtr GetCurrentProcess();

        public static void Enable(string privilegeName) {
            const int SE_PRIVILEGE_ENABLED = 0x00000002;
            const int TOKEN_QUERY = 0x00000008;
            const int TOKEN_ADJUST_PRIVILEGES = 0x00000020;

            IntPtr tokenHandle = IntPtr.Zero;
            if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref tokenHandle)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            TokPriv1Luid tokenPrivilege = new TokPriv1Luid();
            tokenPrivilege.Count = 1;
            tokenPrivilege.Luid = 0;
            tokenPrivilege.Attr = SE_PRIVILEGE_ENABLED;

            if (!LookupPrivilegeValue(null, privilegeName, ref tokenPrivilege.Luid)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            if (!AdjustTokenPrivileges(tokenHandle, false, ref tokenPrivilege, 0, IntPtr.Zero, IntPtr.Zero)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            int errorCode = Marshal.GetLastWin32Error();
            if (errorCode != 0) {
                throw new Win32Exception(errorCode);
            }
        }
    }
}
'@
}

function Enable-RepairPrivileges {
    try {
        Initialize-PrivilegeHelper
        foreach ($privilege in 'SeTakeOwnershipPrivilege','SeRestorePrivilege','SeBackupPrivilege') {
            try {
                [XboxPcRepair.NativePrivilege]::Enable($privilege)
            } catch {
                Write-Warn "$privilege 활성화 실패: $($_.Exception.Message)"
            }
        }
        return $true
    } catch {
        Write-Warn "권한 보조 모듈 초기화 실패: $($_.Exception.Message)"
        return $false
    }
}

function Grant-ServiceRegistryFullControl {
    param(
        [Parameter(Mandatory=$true)][string]$ServiceName
    )

    $subKey = "SYSTEM\CurrentControlSet\Services\$ServiceName"
    $psPath = "HKLM:\$subKey"
    if (-not (Test-Path -LiteralPath $psPath)) {
        Write-Warn "$ServiceName 서비스 레지스트리 키가 없습니다."
        return $false
    }

    Enable-RepairPrivileges | Out-Null

    $admins = New-Object System.Security.Principal.NTAccount('BUILTIN', 'Administrators')
    $system = New-Object System.Security.Principal.NTAccount('NT AUTHORITY', 'SYSTEM')
    $rights = [System.Security.AccessControl.RegistryRights]

    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $subKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            $rights::TakeOwnership
        )
        if ($null -eq $key) {
            throw "키 열기 실패: $subKey"
        }
        $acl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
        $acl.SetOwner($admins)
        $key.SetAccessControl($acl)
        $key.Close()

        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $subKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            $rights::ChangePermissions -bor $rights::TakeOwnership -bor $rights::ReadKey
        )
        if ($null -eq $key) {
            throw "권한 변경용 키 열기 실패: $subKey"
        }

        $acl = $key.GetAccessControl()
        foreach ($account in @($admins, $system)) {
            $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
                $account,
                $rights::FullControl,
                [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $acl.SetAccessRule($rule)
        }
        $key.SetAccessControl($acl)

        try {
            $ownerAcl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
            $ownerAcl.SetOwner($system)
            $key.SetAccessControl($ownerAcl)
        } catch {
            Write-Warn "$ServiceName 서비스 레지스트리 소유자 SYSTEM 복원 실패: $($_.Exception.Message)"
        }

        $key.Close()

        Write-OK "$ServiceName 서비스 레지스트리 ACL 복구"
        return $true
    } catch {
        Write-Warn "$ServiceName 서비스 레지스트리 ACL 복구 실패: $($_.Exception.Message)"
        return $false
    }
}

function Remove-RegistryPropertyIfExists {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name,
        [string]$Label = $Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    try {
        $value = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $value) {
            Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
            Write-OK "$Label 제거됨"
        }
    } catch {
        Write-Warn "$Label 제거 실패: $($_.Exception.Message)"
    }
}

function Set-RegistryDword {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][int]$Value
    )

    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            return $false
        }
        New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType DWord -Value $Value -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-Warn "$Path\$Name 설정 실패: $($_.Exception.Message)"
        return $false
    }
}

function Ensure-SvchostGroupMember {
    param(
        [Parameter(Mandatory=$true)][string]$GroupName,
        [Parameter(Mandatory=$true)][string]$ServiceName
    )

    $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Svchost'
    try {
        $item = Get-ItemProperty -LiteralPath $path -Name $GroupName -ErrorAction SilentlyContinue
        $current = @()
        if ($null -ne $item) {
            $current = @($item.$GroupName) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }

        if ($current -contains $ServiceName) {
            Write-OK "svchost 그룹 확인: $GroupName 포함 $ServiceName"
            return $true
        }

        $newValue = @($current + $ServiceName) | Select-Object -Unique
        if ($current.Count -eq 0) {
            New-ItemProperty -LiteralPath $path -Name $GroupName -PropertyType MultiString -Value $newValue -Force -ErrorAction Stop | Out-Null
        } else {
            Set-ItemProperty -LiteralPath $path -Name $GroupName -Value $newValue -ErrorAction Stop
        }
        Write-OK "svchost 그룹 복구: $GroupName += $ServiceName"
        return $true
    } catch {
        Write-Warn "svchost 그룹 복구 실패($GroupName/$ServiceName): $($_.Exception.Message)"
        return $false
    }
}

function Ensure-DirectoryPath {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Label
    )

    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backupPath = '{0}.blocked-file.{1}.bak' -f $Path, (Get-Date -Format 'yyyyMMddHHmmss')
            Move-Item -LiteralPath $Path -Destination $backupPath -Force -ErrorAction Stop
            Write-Warn "$Label 경로가 파일로 막혀 있어 백업 후 복구함: $backupPath"
        }

        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-OK "$Label 폴더 생성: $Path"
        } else {
            Write-OK "$Label 폴더 확인: $Path"
        }

        & attrib.exe -h -s -r $Path 2>$null
        return $true
    } catch {
        Write-Err "$Label 복구 실패: $($_.Exception.Message)"
        return $false
    }
}

function Repair-ServiceBlockers {
    param(
        [Parameter(Mandatory=$true)][string[]]$ServiceNames
    )

    foreach ($name in $ServiceNames) {
        $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$name"
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Warn "$name 서비스가 없습니다."
            continue
        }

        Grant-ServiceRegistryFullControl -ServiceName $name | Out-Null
        Remove-RegistryPropertyIfExists -Path $path -Name 'WubLock' -Label "$name WubLock"
    }

    Ensure-SvchostGroupMember -GroupName 'wusvcs' -ServiceName 'wuauserv' | Out-Null
    Ensure-SvchostGroupMember -GroupName 'wusvcs' -ServiceName 'WaaSMedicSvc' | Out-Null
    Ensure-SvchostGroupMember -GroupName 'NetworkService' -ServiceName 'DoSvc' | Out-Null
}

function Configure-ServiceStartMode {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Display,
        [Parameter(Mandatory=$true)][ValidateSet('auto','demand')][string]$StartMode,
        [bool]$DelayedAutoStart = $false
    )

    $path = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warn "$Display ($Name) - 서비스 없음"
        return $false
    }

    Grant-ServiceRegistryFullControl -ServiceName $Name | Out-Null
    Remove-RegistryPropertyIfExists -Path $path -Name 'WubLock' -Label "$Name WubLock"

    $scOutput = & sc.exe config $Name start= $StartMode 2>&1
    $scExit = $LASTEXITCODE
    if ($scExit -ne 0) {
        Write-Warn "$Display ($Name) - sc config 실패(exit $scExit), 레지스트리 직접 설정 사용"
        $scOutput | Select-Object -Last 2 | ForEach-Object { Write-Warn "  $_" }
    }

    $startValue = if ($StartMode -eq 'auto') { 2 } else { 3 }
    $registryOk = Set-RegistryDword -Path $path -Name 'Start' -Value $startValue
    if ($StartMode -eq 'auto' -and $DelayedAutoStart) {
        Set-RegistryDword -Path $path -Name 'DelayedAutostart' -Value 1 | Out-Null
    } elseif (Test-Path -LiteralPath $path) {
        Remove-RegistryPropertyIfExists -Path $path -Name 'DelayedAutostart' -Label "$Name DelayedAutostart"
    }

    if ($scExit -eq 0 -or $registryOk) {
        Write-OK "$Display ($Name) - 시작 유형 복구: $StartMode"
        return $true
    }

    return $false
}

function Start-ServiceChecked {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Display,
        [bool]$RequiredRunning = $true
    )

    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
        if ($svc.Status -eq 'Running') {
            Write-OK "$Display ($Name) - Running"
            return $true
        }

        $startOutput = & sc.exe start $Name 2>&1
        $startExit = $LASTEXITCODE
        if ($startExit -ne 0 -and $startExit -ne 1056) {
            $startOutput | Select-Object -Last 2 | ForEach-Object { Write-Warn "$Display ($Name) - $_" }
        }

        $deadline = (Get-Date).AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 500
            $svc = Get-Service -Name $Name -ErrorAction Stop
            if ($svc.Status -eq 'Running') {
                Write-OK "$Display ($Name) - Running"
                return $true
            }
        } while ((Get-Date) -lt $deadline -and $svc.Status -eq 'StartPending')

        $cim = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
        if (-not $RequiredRunning -and $null -ne $cim -and $cim.StartMode -ne 'Disabled') {
            Write-Warn "$Display ($Name) - 현재 $($cim.State), 시작 유형은 $($cim.StartMode)로 복구됨"
            Write-Warn "$Display ($Name) - 보호/트리거 서비스는 필요 시 Windows가 다시 시작할 수 있음"
            return $true
        }

        Write-Err "$Display ($Name) - 상태: $($svc.Status)"
        return $false
    } catch {
        Write-Err "$Display ($Name) - $($_.Exception.Message)"
        return $false
    }
}

function Remove-WindowsUpdateBlockPolicies {
    $policies = @(
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';    Name='DisableWindowsUpdateAccess' },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';    Name='DoNotConnectToWindowsUpdateInternetLocations' },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';    Name='WUServer' },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';    Name='WUStatusServer' },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';    Name='UpdateServiceUrlAlternate' },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';    Name='SetProxyBehaviorForUpdateDetection' },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name='NoAutoUpdate' },
        @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name='UseWUServer' }
    )

    foreach ($policy in $policies) {
        Remove-RegistryPropertyIfExists -Path $policy.Path -Name $policy.Name -Label "$($policy.Path)\$($policy.Name)"
    }

    Write-OK '정책 검사 완료'
}

$script:RootImportOk = $false
$script:ServicesOk = $true

Write-Log ''
Write-Log '====================================================' ([ConsoleColor]::Cyan)
Write-Log " Xbox Game Pass 설치오류(0x80096004) PC방 일괄 해결 v$ScriptVersion" ([ConsoleColor]::Cyan)
Write-Log '====================================================' ([ConsoleColor]::Cyan)
Write-Log " 로그 파일: $LogPath" ([ConsoleColor]::Gray)
Write-Log ''

# ----------------------------------------------------------
# 1. Windows Update 차단 정책 제거
# ----------------------------------------------------------
Write-Step '[1/6] Windows Update 차단 정책 제거 중...'
Remove-WindowsUpdateBlockPolicies
Write-Log ''

# ----------------------------------------------------------
# 2. WubLock/서비스 ACL/svchost 그룹 복구
# ----------------------------------------------------------
Write-Step '[2/6] 서비스 잠금(WubLock/ACL/svchost) 복구 중...'
$repairTargets = 'wuauserv','BITS','CryptSvc','UsoSvc','DoSvc','InstallService','WaaSMedicSvc'
Repair-ServiceBlockers -ServiceNames $repairTargets
Write-Log ''

# ----------------------------------------------------------
# 3. Windows Update 작업 폴더 복구
# ----------------------------------------------------------
Write-Step '[3/6] Windows Update 작업 폴더 복구 중...'
$wuRoot = Join-Path $env:windir 'SoftwareDistribution'
$wuFoldersOk = $true
$wuFoldersOk = (Ensure-DirectoryPath -Path $wuRoot -Label 'SoftwareDistribution') -and $wuFoldersOk
$wuFoldersOk = (Ensure-DirectoryPath -Path (Join-Path $wuRoot 'DataStore') -Label 'DataStore') -and $wuFoldersOk
$wuFoldersOk = (Ensure-DirectoryPath -Path (Join-Path $wuRoot 'Download') -Label 'Download') -and $wuFoldersOk
$wuFoldersOk = (Ensure-DirectoryPath -Path (Join-Path $env:windir 'System32\catroot2') -Label 'catroot2') -and $wuFoldersOk
if (-not $wuFoldersOk) {
    Write-Err 'Windows Update 작업 폴더 복구에 실패했습니다. 중단합니다.'
    Wait-BeforeExit
    exit 2
}
Write-Log ''

# ----------------------------------------------------------
# 4. Windows Update 관련 서비스 활성화 및 시작
# ----------------------------------------------------------
Write-Step '[4/6] Windows Update 관련 서비스 활성화 중...'
$services = @(
    @{ Name='wuauserv';       Display='Windows Update';                         Start='demand'; Delayed=$false; Required=$true  },
    @{ Name='BITS';           Display='Background Intelligent Transfer Service'; Start='demand'; Delayed=$false; Required=$false },
    @{ Name='CryptSvc';       Display='Cryptographic Services';                 Start='auto';   Delayed=$false; Required=$true  },
    @{ Name='UsoSvc';         Display='Update Orchestrator Service';            Start='auto';   Delayed=$false; Required=$false },
    @{ Name='DoSvc';          Display='Delivery Optimization';                  Start='auto';   Delayed=$true;  Required=$false },
    @{ Name='InstallService'; Display='Microsoft Store Install Service';        Start='auto';   Delayed=$false; Required=$true  },
    @{ Name='WaaSMedicSvc';   Display='Windows Update Medic Service';           Start='demand'; Delayed=$false; Required=$false }
)

foreach ($service in $services) {
    $configured = Configure-ServiceStartMode -Name $service.Name -Display $service.Display -StartMode $service.Start -DelayedAutoStart $service.Delayed
    $started = Start-ServiceChecked -Name $service.Name -Display $service.Display -RequiredRunning $service.Required
    if (-not $configured -or -not $started) {
        if ($service.Required) {
            $script:ServicesOk = $false
        }
    }
}
Write-Log ''

if (-not $script:ServicesOk) {
    Write-Warn '필수 서비스 일부가 Running 상태가 아닙니다. 그래도 인증서 갱신을 시도합니다.'
    Write-Log ''
}

# ----------------------------------------------------------
# 5. Windows Update에서 최신 루트 인증서 묶음 다운로드
# ----------------------------------------------------------
Write-Step '[5/6] 최신 루트 인증서 묶음 생성 중 (수십 초 소요될 수 있음)...'
$sstPath = Join-Path $env:TEMP ('roots_pcbang_{0}.sst' -f (Get-Date -Format 'yyyyMMddHHmmss'))
try {
    & certutil.exe -generateSSTFromWU $sstPath | Out-Null
    if (Test-Path -LiteralPath $sstPath) {
        $size = (Get-Item -LiteralPath $sstPath).Length
        if ($size -lt 1024) {
            Write-Err "생성된 SST 파일 크기가 비정상($size bytes). Windows Update 접근 차단 가능성."
        } else {
            Write-OK ("생성 완료: {0} ({1:N0} bytes)" -f $sstPath, $size)
        }
    } else {
        Write-Err 'roots.sst 생성 실패. 네트워크 또는 Windows Update 접근을 확인하세요.'
    }
} catch {
    Write-Err "certutil 실패: $($_.Exception.Message)"
}
Write-Log ''

# ----------------------------------------------------------
# 6. 신뢰할 수 있는 루트 인증 기관 저장소에 일괄 임포트
# ----------------------------------------------------------
Write-Step '[6/6] 신뢰할 수 있는 루트 인증 기관에 임포트 중...'
if ($NoCertImport) {
    Write-Warn 'NoCertImport 옵션으로 인증서 임포트를 건너뜁니다.'
} elseif (Test-Path -LiteralPath $sstPath) {
    $addLog = & certutil.exe -addstore -f Root $sstPath 2>&1
    $script:RootImportOk = $LASTEXITCODE -eq 0
    Remove-Item -LiteralPath $sstPath -Force -ErrorAction SilentlyContinue
    if ($script:RootImportOk) {
        Write-OK '루트 인증서 임포트 성공'
    } else {
        Write-Err "루트 인증서 임포트 실패 (exit code: $LASTEXITCODE)"
        $addLog | Select-Object -Last 5 | ForEach-Object { Write-Log "    $_" ([ConsoleColor]::Yellow) }
    }
} else {
    Write-Err '임포트할 SST 파일이 없습니다.'
}
Write-Log ''

# ----------------------------------------------------------
# 결과 요약
# ----------------------------------------------------------
Write-Log '====================================================' ([ConsoleColor]::Cyan)
if ($script:RootImportOk -and $script:ServicesOk) {
    Write-Log ' 완료: 이제 Microsoft Store에서 Xbox 앱 업데이트/설치를 다시 시도하세요.' ([ConsoleColor]::Green)
    Write-Log '       Store 로그인 후 Xbox 앱을 업데이트하고 완전히 종료한 뒤 재실행하세요.' ([ConsoleColor]::Green)
} elseif ($script:RootImportOk) {
    Write-Log ' 부분 완료: 루트 인증서 갱신은 성공했습니다.' ([ConsoleColor]::Yellow)
    Write-Log '       일부 보호/트리거 서비스는 Running이 아니어도 Store 설치는 진행될 수 있습니다.' ([ConsoleColor]::Yellow)
    Write-Log '       Xbox 앱 설치를 다시 시도하고, 실패하면 로그 파일을 확인하세요.' ([ConsoleColor]::Yellow)
} else {
    Write-Log ' 실패: 루트 인증서 갱신이 완료되지 않았습니다. 위 오류와 로그 파일을 확인하세요.' ([ConsoleColor]::Red)
}
Write-Log " 로그 파일: $LogPath" ([ConsoleColor]::Gray)
Write-Log '====================================================' ([ConsoleColor]::Cyan)
Write-Log ''

if ($script:RootImportOk) {
    Wait-BeforeExit
    exit 0
}

Wait-BeforeExit
exit 2


