#requires -RunAsAdministrator
param(
    [switch]$NoPause,
    [switch]$NoCertImport,
    [switch]$NoOpenStore,
    [switch]$NoOpenXbox,
    [string]$LogPath
)

<#
  Xbox Game Pass 앱 설치 오류 (0x80096004) PC방 일괄 해결 스크립트
  Version: 1.5.0

  - Windows Update 관련 서비스 강제 활성화
  - Windows Update Blocker/WubLock 방식의 서비스 잠금 복구
  - 서비스 레지스트리 ACL이 ReadKey로 잠긴 PC방 환경 복구
  - svchost 그룹에서 wuauserv가 제거된 환경 복구
  - SoftwareDistribution 경로가 파일로 막힌 PC방 환경 복구
  - Windows Update를 통해 최신 루트 인증서 갱신
  - Store 설치 큐를 막는 Windows Update 정책 캐시 제거
  - 오래된 Microsoft Store 클라이언트 업데이트
  - Microsoft Store 캐시 정리
  - Xbox 앱 실행 오류 0x80073cf3 원인인 Gaming Services/NET Native 의존성 복구
#>

$ScriptVersion = '1.5.0'
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

function Clear-WindowsUpdatePolicyCache {
    $blockNames = @(
        'DisableWindowsUpdateAccess',
        'DoNotConnectToWindowsUpdateInternetLocations',
        'WUServer',
        'WUStatusServer',
        'UpdateServiceUrlAlternate',
        'SetProxyBehaviorForUpdateDetection',
        'NoAutoUpdate',
        'UseWUServer'
    )

    $cacheRoot = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\GPCache'
    if (Test-Path -LiteralPath $cacheRoot) {
        $keys = @((Get-Item -LiteralPath $cacheRoot -ErrorAction SilentlyContinue))
        $keys += @(Get-ChildItem -LiteralPath $cacheRoot -Recurse -ErrorAction SilentlyContinue)
        foreach ($key in $keys) {
            foreach ($name in $blockNames) {
                Remove-RegistryPropertyIfExists -Path $key.PSPath -Name $name -Label "$($key.PSChildName)\$name"
            }
        }
    }

    $policyState = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UpdatePolicy\PolicyState'
    if (Test-Path -LiteralPath $policyState) {
        foreach ($name in 'SetPolicyDrivenUpdateSourceForFeatureUpdates','SetPolicyDrivenUpdateSourceForQualityUpdates','SetPolicyDrivenUpdateSourceForDriverUpdates','SetPolicyDrivenUpdateSourceForOtherUpdates','UseUpdateClassPolicySource') {
            Remove-RegistryPropertyIfExists -Path $policyState -Name $name -Label "PolicyState\$name"
        }
    }

    Write-OK 'Windows Update 정책 캐시 검사 완료'
}

function Test-WindowsUpdateSearch {
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0 and Type='Software'")
        $hresult = '0x{0:X8}' -f ($result.HResult -band 0xffffffff)
        Write-OK "Windows Update 검색 API 정상: ResultCode=$($result.ResultCode), HResult=$hresult, Count=$($result.Updates.Count)"
        return $true
    } catch {
        $hresult = '0x{0:X8}' -f ($_.Exception.HResult -band 0xffffffff)
        Write-Err "Windows Update 검색 API 실패: $hresult / $($_.Exception.Message)"
        return $false
    }
}

function Clear-StoreCache {
    Write-Step '[8/10] Microsoft Store 캐시 정리 중...'

    foreach ($processName in 'WinStore.App','winstore.app','MicrosoftStore') {
        Get-Process -Name $processName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    $storePackageRoot = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsStore_8wekyb3d8bbwe'
    $cacheTargets = @(
        (Join-Path $storePackageRoot 'LocalCache'),
        (Join-Path $storePackageRoot 'TempState'),
        (Join-Path $storePackageRoot 'AC\INetCache'),
        (Join-Path $storePackageRoot 'AC\INetCookies'),
        (Join-Path $storePackageRoot 'AC\INetHistory')
    )

    foreach ($target in $cacheTargets) {
        try {
            $resolved = Resolve-Path -LiteralPath $target -ErrorAction SilentlyContinue
            if ($null -eq $resolved) {
                continue
            }

            $resolvedPath = $resolved.ProviderPath
            if ($resolvedPath -notlike "$storePackageRoot*") {
                Write-Warn "Store 캐시 경로 범위 밖이라 건너뜀: $resolvedPath"
                continue
            }

            Get-ChildItem -LiteralPath $resolvedPath -Force -ErrorAction SilentlyContinue |
                Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
            Write-OK "Store 캐시 정리: $resolvedPath"
        } catch {
            Write-Warn "Store 캐시 정리 실패($target): $($_.Exception.Message)"
        }
    }

    Write-OK 'Microsoft Store 캐시 정리 완료'
}

function Ensure-MicrosoftStoreUpdated {
    Write-Step '[6/10] Microsoft Store 클라이언트 업데이트 확인 중...'

    $minimumStoreVersion = [version]'22000.0.0.0'
    $storePackage = Get-AppxPackage -AllUsers -Name Microsoft.WindowsStore -ErrorAction SilentlyContinue |
        Sort-Object {[version]$_.Version} -Descending |
        Select-Object -First 1

    if ($null -ne $storePackage) {
        Write-OK "현재 Microsoft Store 버전: $($storePackage.Version)"
    } else {
        Write-Warn 'Microsoft Store 패키지를 찾지 못했습니다. WSReset -i로 복구를 시도합니다.'
    }

    $needsUpdate = $true
    if ($null -ne $storePackage) {
        try {
            $needsUpdate = ([version]$storePackage.Version) -lt $minimumStoreVersion
        } catch {
            $needsUpdate = $true
        }
    }

    if (-not $needsUpdate) {
        Write-OK 'Microsoft Store 클라이언트 버전 확인 완료'
        return $true
    }

    try {
        Write-Warn 'Microsoft Store가 오래되어 WSReset.exe -i 업데이트를 실행합니다.'
        foreach ($processName in 'WinStore.App','winstore.app','MicrosoftStore') {
            Get-Process -Name $processName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }

        $wsreset = Join-Path $env:windir 'System32\WSReset.exe'
        $process = Start-Process -FilePath $wsreset -ArgumentList '-i' -PassThru -WindowStyle Hidden -ErrorAction Stop
        $completed = $process.WaitForExit(120000)
        if (-not $completed) {
            Write-Warn 'WSReset.exe -i가 120초 안에 끝나지 않았습니다. 업데이트는 백그라운드에서 계속될 수 있습니다.'
        } else {
            Write-OK "WSReset.exe -i 실행 완료"
        }

        Start-Sleep -Seconds 3
        $updatedPackage = Get-AppxPackage -AllUsers -Name Microsoft.WindowsStore -ErrorAction SilentlyContinue |
            Sort-Object {[version]$_.Version} -Descending |
            Select-Object -First 1

        if ($null -ne $updatedPackage) {
            Write-OK "업데이트 후 Microsoft Store 버전: $($updatedPackage.Version)"
            return ([version]$updatedPackage.Version) -ge $minimumStoreVersion
        }

        Write-Warn '업데이트 후 Microsoft Store 패키지를 확인하지 못했습니다.'
        return $false
    } catch {
        Write-Warn "Microsoft Store 클라이언트 업데이트 실패: $($_.Exception.Message)"
        return $false
    }
}

function Get-HighestAppxPackage {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [string]$Architecture
    )

    $packages = @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue)
    if (-not [string]::IsNullOrWhiteSpace($Architecture)) {
        $packages = @($packages | Where-Object { $_.Architecture.ToString() -eq $Architecture })
    }

    $packages |
        Sort-Object { try { [version]$_.Version } catch { [version]'0.0.0.0' } } -Descending |
        Select-Object -First 1
}

function Test-AppxPackageAtLeast {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][version]$MinimumVersion,
        [string]$Architecture = 'X64'
    )

    $package = Get-HighestAppxPackage -Name $Name -Architecture $Architecture
    if ($null -eq $package) {
        return $false
    }

    try {
        return ([version]$package.Version) -ge $MinimumVersion
    } catch {
        return $false
    }
}

function Await-WinRtAsyncOperationResult {
    param(
        [Parameter(Mandatory=$true)]$Operation,
        [Parameter(Mandatory=$true)][Type]$ResultType
    )

    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction SilentlyContinue
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.IsGenericMethodDefinition -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1

    if ($null -eq $method) {
        throw 'WinRT AsTask helper를 찾지 못했습니다.'
    }

    $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait()
    return $task.Result
}

function Install-GamingServicesFromStore {
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction SilentlyContinue
        [void][Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager, Windows.ApplicationModel.Store.Preview, ContentType=WindowsRuntime]
        [void][Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallItem, Windows.ApplicationModel.Store.Preview, ContentType=WindowsRuntime]

        $manager = [Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallManager]::new()
        $manager.AcquisitionIdentity = 'Microsoft.WindowsStore_8wekyb3d8bbwe'

        $allowed = Await-WinRtAsyncOperationResult -Operation ($manager.GetIsAppAllowedToInstallAsync('9MWPM2CQNLHN')) -ResultType ([bool])
        if (-not $allowed) {
            Write-Warn 'Store 정책상 Gaming Services 설치가 허용되지 않습니다.'
            return $false
        }

        Write-OK 'Gaming Services Store 설치 허용 확인'
        $null = Await-WinRtAsyncOperationResult -Operation ($manager.StartAppInstallAsync('9MWPM2CQNLHN','0010',$false,$false)) -ResultType ([Windows.ApplicationModel.Store.Preview.InstallControl.AppInstallItem])
        Write-OK 'Gaming Services Store 설치 요청 전송'
        return $true
    } catch {
        Write-Warn "Gaming Services Store 설치 요청 실패: $($_.Exception.Message)"
        if ($_.Exception.InnerException) {
            Write-Warn "  $($_.Exception.InnerException.Message)"
        }
        return $false
    }
}

function Ensure-GamingServicesAndDependencies {
    Write-Step '[10/10] Xbox Gaming Services 및 의존성 복구 중...'

    $minimumFramework = [version]'2.2.29512.0'
    $minimumRuntime = [version]'2.2.28604.0'

    $frameworkOk = Test-AppxPackageAtLeast -Name 'Microsoft.NET.Native.Framework.2.2' -MinimumVersion $minimumFramework
    $runtimeOk = Test-AppxPackageAtLeast -Name 'Microsoft.NET.Native.Runtime.2.2' -MinimumVersion $minimumRuntime
    $gamingServices = Get-HighestAppxPackage -Name 'Microsoft.GamingServices' -Architecture 'X64'

    if ($frameworkOk -and $runtimeOk -and $null -ne $gamingServices) {
        Write-OK "Gaming Services 설치 확인: $($gamingServices.PackageFullName)"
    } else {
        if (-not $frameworkOk) {
            $current = Get-HighestAppxPackage -Name 'Microsoft.NET.Native.Framework.2.2' -Architecture 'X64'
            $currentVersion = if ($current) { $current.Version } else { 'not installed' }
            Write-Warn "Microsoft.NET.Native.Framework.2.2 x64 버전 부족: 현재 $currentVersion, 필요 $minimumFramework 이상"
        }
        if (-not $runtimeOk) {
            $current = Get-HighestAppxPackage -Name 'Microsoft.NET.Native.Runtime.2.2' -Architecture 'X64'
            $currentVersion = if ($current) { $current.Version } else { 'not installed' }
            Write-Warn "Microsoft.NET.Native.Runtime.2.2 x64 버전 부족: 현재 $currentVersion, 필요 $minimumRuntime 이상"
        }
        if ($null -eq $gamingServices) {
            Write-Warn 'Microsoft.GamingServices 패키지가 설치되어 있지 않습니다.'
        }

        Install-GamingServicesFromStore | Out-Null

        $deadline = (Get-Date).AddSeconds(180)
        do {
            Start-Sleep -Seconds 3
            $frameworkOk = Test-AppxPackageAtLeast -Name 'Microsoft.NET.Native.Framework.2.2' -MinimumVersion $minimumFramework
            $runtimeOk = Test-AppxPackageAtLeast -Name 'Microsoft.NET.Native.Runtime.2.2' -MinimumVersion $minimumRuntime
            $gamingServices = Get-HighestAppxPackage -Name 'Microsoft.GamingServices' -Architecture 'X64'
            if ($frameworkOk -and $runtimeOk -and $null -ne $gamingServices) {
                break
            }
        } while ((Get-Date) -lt $deadline)
    }

    $frameworkOk = Test-AppxPackageAtLeast -Name 'Microsoft.NET.Native.Framework.2.2' -MinimumVersion $minimumFramework
    $runtimeOk = Test-AppxPackageAtLeast -Name 'Microsoft.NET.Native.Runtime.2.2' -MinimumVersion $minimumRuntime
    $gamingServices = Get-HighestAppxPackage -Name 'Microsoft.GamingServices' -Architecture 'X64'

    if ($frameworkOk) {
        $package = Get-HighestAppxPackage -Name 'Microsoft.NET.Native.Framework.2.2' -Architecture 'X64'
        Write-OK "Microsoft.NET.Native.Framework.2.2 x64 확인: $($package.Version)"
    } else {
        Write-Err "Microsoft.NET.Native.Framework.2.2 x64 $minimumFramework 이상 설치 실패"
    }

    if ($runtimeOk) {
        $package = Get-HighestAppxPackage -Name 'Microsoft.NET.Native.Runtime.2.2' -Architecture 'X64'
        Write-OK "Microsoft.NET.Native.Runtime.2.2 x64 확인: $($package.Version)"
    } else {
        Write-Err "Microsoft.NET.Native.Runtime.2.2 x64 $minimumRuntime 이상 설치 실패"
    }

    if ($null -ne $gamingServices) {
        Write-OK "Microsoft.GamingServices 확인: $($gamingServices.PackageFullName)"
    } else {
        Write-Err 'Microsoft.GamingServices 설치 실패'
    }

    foreach ($serviceName in 'GamingServices','GamingServicesNet') {
        try {
            $svc = Get-Service -Name $serviceName -ErrorAction Stop
            if ($svc.Status -ne 'Running') {
                Start-Service -Name $serviceName -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                $svc = Get-Service -Name $serviceName -ErrorAction Stop
            }

            if ($svc.Status -eq 'Running') {
                Write-OK "$serviceName 서비스 Running"
            } else {
                Write-Warn "$serviceName 서비스 상태: $($svc.Status)"
            }
        } catch {
            Write-Warn "$serviceName 서비스 확인 실패: $($_.Exception.Message)"
        }
    }

    return ($frameworkOk -and $runtimeOk -and $null -ne $gamingServices)
}

function Restart-UpdateAndStoreServices {
    $stopServices = 'InstallService','UsoSvc','wuauserv','BITS'
    foreach ($name in $stopServices) {
        Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Seconds 2

    foreach ($name in 'CryptSvc','wuauserv','BITS','UsoSvc','InstallService','AppXSvc','ClipSVC','TokenBroker','LicenseManager') {
        try {
            Start-Service -Name $name -ErrorAction Stop
            Write-OK "$name 서비스 시작/확인"
        } catch {
            Write-Warn "$name 서비스 시작 실패: $($_.Exception.Message)"
        }
    }
}

function Open-XboxApp {
    if ($NoOpenXbox) {
        return
    }

    $gamingApp = Get-HighestAppxPackage -Name 'Microsoft.GamingApp' -Architecture 'X64'
    if ($null -eq $gamingApp) {
        return
    }

    try {
        Start-Process 'shell:AppsFolder\Microsoft.GamingApp_8wekyb3d8bbwe!Microsoft.Xbox.App' -ErrorAction Stop
        Write-OK 'Xbox 앱 실행 요청 완료'
    } catch {
        Write-Warn "Xbox 앱 실행 실패: $($_.Exception.Message)"
    }
}

function Open-XboxStorePage {
    if ($NoOpenStore) {
        return
    }

    try {
        $uri = 'ms-windows-store://pdp/?ProductId=9MV0B5HZVK9Z'
        Start-Process $uri -ErrorAction Stop
        Write-OK 'Microsoft Store Xbox 앱 페이지 열기 요청 완료'
    } catch {
        Write-Warn "Microsoft Store Xbox 앱 페이지 열기 실패: $($_.Exception.Message)"
    }
}

$script:RootImportOk = $false
$script:ServicesOk = $true
$script:WuSearchOk = $false
$script:StoreUpdateOk = $false
$script:GamingServicesOk = $false

Write-Log ''
Write-Log '====================================================' ([ConsoleColor]::Cyan)
Write-Log " Xbox Game Pass 설치오류(0x80096004) PC방 일괄 해결 v$ScriptVersion" ([ConsoleColor]::Cyan)
Write-Log '====================================================' ([ConsoleColor]::Cyan)
Write-Log " 로그 파일: $LogPath" ([ConsoleColor]::Gray)
Write-Log ''

# ----------------------------------------------------------
# 1. Windows Update 차단 정책 제거
# ----------------------------------------------------------
Write-Step '[1/10] Windows Update 차단 정책 제거 중...'
Remove-WindowsUpdateBlockPolicies
Clear-WindowsUpdatePolicyCache
Write-Log ''

# ----------------------------------------------------------
# 2. WubLock/서비스 ACL/svchost 그룹 복구
# ----------------------------------------------------------
Write-Step '[2/10] 서비스 잠금(WubLock/ACL/svchost) 복구 중...'
$repairTargets = 'wuauserv','BITS','CryptSvc','UsoSvc','DoSvc','InstallService','WaaSMedicSvc'
Repair-ServiceBlockers -ServiceNames $repairTargets
Write-Log ''

# ----------------------------------------------------------
# 3. Windows Update 작업 폴더 복구
# ----------------------------------------------------------
Write-Step '[3/10] Windows Update 작업 폴더 복구 중...'
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
Write-Step '[4/10] Windows Update 관련 서비스 활성화 중...'
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
Restart-UpdateAndStoreServices
Write-Log ''

Write-Step '[5/10] Windows Update 검색 API 검증 중...'
$script:WuSearchOk = Test-WindowsUpdateSearch
Write-Log ''

# ----------------------------------------------------------
# 6. Microsoft Store 클라이언트 업데이트 확인
# ----------------------------------------------------------
$script:StoreUpdateOk = Ensure-MicrosoftStoreUpdated
Write-Log ''

# ----------------------------------------------------------
# 7. Windows Update에서 최신 루트 인증서 묶음 다운로드
# ----------------------------------------------------------
Write-Step '[7/10] 최신 루트 인증서 묶음 생성 중 (수십 초 소요될 수 있음)...'
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
# 8. Microsoft Store 캐시 정리
# ----------------------------------------------------------
Clear-StoreCache
Write-Log ''

# ----------------------------------------------------------
# 9. 신뢰할 수 있는 루트 인증 기관 저장소에 일괄 임포트
# ----------------------------------------------------------
Write-Step '[9/10] 신뢰할 수 있는 루트 인증 기관에 임포트 중...'
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
# 10. Xbox Gaming Services 의존성 복구
# ----------------------------------------------------------
$script:GamingServicesOk = Ensure-GamingServicesAndDependencies
Write-Log ''

# ----------------------------------------------------------
# 결과 요약
# ----------------------------------------------------------
Write-Log '====================================================' ([ConsoleColor]::Cyan)
if ($script:RootImportOk -and $script:ServicesOk -and $script:WuSearchOk -and $script:StoreUpdateOk -and $script:GamingServicesOk) {
    Write-Log ' 완료: Xbox 앱 설치/실행에 필요한 Store, Windows Update, Gaming Services 복구가 끝났습니다.' ([ConsoleColor]::Green)
    Write-Log '       Xbox 앱 제품 ID: 9MV0B5HZVK9Z / Gaming Services 제품 ID: 9MWPM2CQNLHN' ([ConsoleColor]::Green)
    if (Get-HighestAppxPackage -Name 'Microsoft.GamingApp' -Architecture 'X64') {
        Open-XboxApp
    } else {
        Open-XboxStorePage
    }
} elseif ($script:RootImportOk -and $script:WuSearchOk) {
    Write-Log ' 부분 완료: 루트 인증서 갱신과 Windows Update 검색 검증은 성공했습니다.' ([ConsoleColor]::Yellow)
    Write-Log '       Microsoft Store 클라이언트 업데이트 확인은 완료되지 않았을 수 있습니다.' ([ConsoleColor]::Yellow)
    Write-Log '       Gaming Services 또는 NET Native 의존성 복구가 완료되지 않았을 수 있습니다.' ([ConsoleColor]::Yellow)
    Write-Log '       Xbox 앱 설치를 다시 시도하고, 실패하면 로그 파일을 확인하세요.' ([ConsoleColor]::Yellow)
} else {
    Write-Log ' 실패: 루트 인증서 갱신이 완료되지 않았습니다. 위 오류와 로그 파일을 확인하세요.' ([ConsoleColor]::Red)
}
Write-Log " 로그 파일: $LogPath" ([ConsoleColor]::Gray)
Write-Log '====================================================' ([ConsoleColor]::Cyan)
Write-Log ''

if ($script:RootImportOk -and $script:WuSearchOk -and $script:GamingServicesOk) {
    Wait-BeforeExit
    exit 0
}

Wait-BeforeExit
exit 2







