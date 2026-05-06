#requires -RunAsAdministrator
param(
    [switch]$NoPause
)

<#
  Xbox Game Pass 앱 설치 오류 (0x80096004) PC방 일괄 해결 스크립트
  - Windows Update 관련 서비스 강제 활성화
  - SoftwareDistribution 경로가 파일로 막힌 PC방 환경 복구
  - Windows Update를 통해 최신 루트 인증서 갱신
#>

$ErrorActionPreference = 'Continue'
$Host.UI.RawUI.WindowTitle = 'Xbox Game Pass 설치 오류 해결 (PC방용)'

function Write-Step($msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function Wait-BeforeExit {
    if (-not $NoPause) {
        Read-Host '엔터를 눌러 종료'
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

Write-Host ''
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host ' Xbox Game Pass 설치오류(0x80096004) PC방 일괄 해결' -ForegroundColor Cyan
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host ''

# ----------------------------------------------------------
# 1. Windows Update 차단 정책 제거
# ----------------------------------------------------------
Write-Step '[1/5] Windows Update 차단 정책 제거 중...'
$policies = @(
    @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';    Name='DisableWindowsUpdateAccess' },
    @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name='NoAutoUpdate' },
    @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name='UseWUServer' }
)
foreach ($p in $policies) {
    if (Test-Path $p.Path) {
        try {
            Remove-ItemProperty -Path $p.Path -Name $p.Name -ErrorAction Stop
            Write-OK "$($p.Path)\$($p.Name) 제거됨"
        } catch {
            # 키가 없으면 무시
        }
    }
}
Write-OK '정책 검사 완료'
Write-Host ''

# ----------------------------------------------------------
# 2. Windows Update 작업 폴더 복구
# ----------------------------------------------------------
Write-Step '[2/5] Windows Update 작업 폴더 복구 중...'
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
Write-Host ''

# ----------------------------------------------------------
# 3. Windows Update 관련 서비스 강제 시작
# ----------------------------------------------------------
Write-Step '[3/5] Windows Update 관련 서비스 강제 활성화 중...'
$services = @(
    @{ Name='wuauserv';       Display='Windows Update' },
    @{ Name='BITS';           Display='Background Intelligent Transfer Service' },
    @{ Name='CryptSvc';       Display='Cryptographic Services' },
    @{ Name='UsoSvc';         Display='Update Orchestrator Service' },
    @{ Name='DoSvc';          Display='Delivery Optimization' },
    @{ Name='InstallService'; Display='Microsoft Store Install Service' }
)
foreach ($s in $services) {
    try {
        # sc.exe 사용: StartType=Disabled 상태도 강제로 풀어줌
        & sc.exe config $s.Name start= auto | Out-Null
        $svc = Get-Service -Name $s.Name -ErrorAction Stop
        if ($svc.Status -ne 'Running') {
            Start-Service -Name $s.Name -ErrorAction Stop
        }
        $svc = Get-Service -Name $s.Name
        if ($svc.Status -eq 'Running') {
            Write-OK "$($s.Display) ($($s.Name)) - Running"
        } else {
            Write-Warn "$($s.Display) ($($s.Name)) - 상태: $($svc.Status)"
        }
    } catch {
        Write-Err "$($s.Display) ($($s.Name)) - $($_.Exception.Message)"
    }
}
Write-Host ''

# ----------------------------------------------------------
# 4. Windows Update에서 최신 루트 인증서 묶음 다운로드
# ----------------------------------------------------------
Write-Step '[4/5] 최신 루트 인증서 묶음 생성 중 (수십 초 소요될 수 있음)...'
$sstPath = Join-Path $env:TEMP ('roots_pcbang_{0}.sst' -f (Get-Date -Format 'yyyyMMddHHmmss'))
try {
    & certutil.exe -generateSSTFromWU $sstPath | Out-Null
    if (Test-Path $sstPath) {
        $size = (Get-Item $sstPath).Length
        if ($size -lt 1024) {
            Write-Err "생성된 SST 파일 크기가 비정상($size bytes). Windows Update 접근 차단 가능성. 중단합니다."
            Wait-BeforeExit
            exit 2
        }
        Write-OK ("생성 완료: {0} ({1:N0} bytes)" -f $sstPath, $size)
    } else {
        Write-Err 'roots.sst 생성 실패. 네트워크 또는 Windows Update 접근을 확인하세요.'
        Wait-BeforeExit
        exit 2
    }
} catch {
    Write-Err "certutil 실패: $($_.Exception.Message)"
    Wait-BeforeExit
    exit 2
}
Write-Host ''

# ----------------------------------------------------------
# 5. 신뢰할 수 있는 루트 인증 기관 저장소에 일괄 임포트
# ----------------------------------------------------------
Write-Step '[5/5] 신뢰할 수 있는 루트 인증 기관에 임포트 중...'
$addLog = & certutil.exe -addstore -f Root $sstPath 2>&1
$ok = $LASTEXITCODE -eq 0
Remove-Item $sstPath -Force -ErrorAction SilentlyContinue
if ($ok) {
    Write-OK '루트 인증서 임포트 성공'
} else {
    Write-Err "루트 인증서 임포트 실패 (exit code: $LASTEXITCODE)"
    $addLog | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" }
}
Write-Host ''

# ----------------------------------------------------------
# 결과 요약
# ----------------------------------------------------------
Write-Host '====================================================' -ForegroundColor Cyan
if ($ok) {
    Write-Host ' 완료: 이제 Microsoft Store에서 Xbox Game Pass 앱' -ForegroundColor Green
    Write-Host '       설치를 다시 시도하세요.' -ForegroundColor Green
} else {
    Write-Host ' 일부 단계에서 실패했습니다. 메시지를 확인하세요.' -ForegroundColor Yellow
}
Write-Host '====================================================' -ForegroundColor Cyan
Write-Host ''
Wait-BeforeExit
