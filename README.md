# Xbox 앱 / Microsoft Store 0x80096004 복구 도구

[![Windows](https://img.shields.io/badge/Windows-10%20%2F%2011-0078D4)](#요구-사항)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)](#빠른-실행)
[![Unofficial](https://img.shields.io/badge/Microsoft-비공식-lightgrey)](#상표-고지)
[![License](https://img.shields.io/badge/License-Apache--2.0-green)](#라이선스)

**English:** [READMEen.md](READMEen.md)

Xbox 앱, PC Game Pass, Microsoft Store 설치 실패가 Windows Update 손상이나 오래된 신뢰 루트 인증서 때문에 발생하는 경우 이를 복구하는 비공식 Windows 관리자 도구입니다.
이 도구는 Xbox 앱 또는 Microsoft Store 설치 중 `0x80096004` 같은 오류가 발생하는 Windows PC를 위해 만들었습니다. 특히 Windows Update가 오랫동안 비활성화되어 있었거나, Windows Update 작업 폴더가 손상된 환경에서 도움이 됩니다.
이 도구는 Xbox, Game Pass, Microsoft Store, 계정, 결제, 지역, DRM, 라이선스 검사를 우회하지 않습니다.

---

## 어떤 문제를 고치나요?

| 증상 | 이 도구가 확인하거나 복구하는 항목 |
| --- | --- |
| Microsoft Store에서 Xbox 앱 설치 실패 | Microsoft Store와 Windows Update 관련 서비스 시작 |
| PC Game Pass 관련 앱 설치 실패 | 서명 검증에 필요한 신뢰 루트 인증서 갱신 |
| Store 설치 중 `0x80096004` 발생 | Windows Update를 통한 루트 인증서 동기화 |
| `wuauserv`가 시작되지 않음 | Windows Update 서비스 시작 유형과 필수 폴더 복구 |
| Windows Update가 `The system cannot find the path specified`로 실패 | `C:\Windows\SoftwareDistribution` 경로가 없거나 파일로 막힌 상태 복구 |
| PC방, 공용 PC, 오래된 Windows 이미지에서 Store 설치 실패 | Store 패키지 검증에 필요한 최소 업데이트/인증서 상태 복구 |

`0x80096004`는 보통 `TRUST_E_CERT_SIGNATURE` 계열 오류와 관련이 있습니다. Windows가 Store 패키지의 디지털 서명을 검증하지 못할 때 발생할 수 있으며, 오래된 신뢰 루트 인증서 저장소나 고장난 Windows Update 상태가 원인이 될 수 있습니다.

---

## 빠른 실행

관리자 권한 PowerShell에서 실행합니다.

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\XboxGamePass_PCBang_Fix.ps1
```

패키징된 실행 파일을 사용하는 경우 관리자 권한으로 실행합니다.

```powershell
.\XboxGamePass_PCBang_Fix.exe
```

도구 실행이 끝나면 Xbox 앱, PC Game Pass, Microsoft Store 설치를 다시 시도하세요.

---

## 반드시 해야 하는 마무리 절차

먼저 이 복구 도구를 실행한 뒤, Microsoft Store에서 아래 과정을 끝까지 진행해야 합니다.

1. 이 도구를 관리자 권한으로 실행합니다.
2. Microsoft Store를 엽니다.
3. Xbox 앱에서 사용할 Microsoft 계정으로 Microsoft Store에 로그인합니다.
4. Microsoft Store에서 Xbox 앱을 업데이트합니다.
5. Xbox 앱을 완전히 종료한 뒤 다시 실행합니다.

인증서와 Windows Update 상태를 복구한 뒤 Microsoft Store를 통해 Xbox 앱을 업데이트해야 최종적으로 오류가 해결되는 경우가 많습니다.

---

## 시작하기

1. 최신 릴리스를 다운로드하거나 저장소를 클론합니다.
2. PowerShell을 우클릭해 **관리자 권한으로 실행**합니다.
3. 스크립트 또는 실행 파일을 실행합니다.
4. Windows Update, BITS, Cryptographic Services, Microsoft Store Install Service가 `Running`으로 표시되는지 확인합니다.
5. 위의 마무리 절차를 Microsoft Store에서 진행합니다.


---

## 수행하는 작업

복구 흐름은 작고 투명하게 유지했습니다.

| 단계 | 작업 |
| --- | --- |
| 1 | 일반적인 Windows Update 차단 정책 값 제거: `DisableWindowsUpdateAccess`, `NoAutoUpdate`, `UseWUServer` |
| 2 | Windows Update 작업 폴더 복구: `SoftwareDistribution`, `DataStore`, `Download`, `catroot2` |
| 3 | `C:\Windows\SoftwareDistribution`이 폴더가 아니라 파일이면 `.blocked-file.YYYYMMDDHHMMSS.bak`로 백업하고 폴더 재생성 |
| 4 | `wuauserv`, `BITS`, `CryptSvc`, `UsoSvc`, `DoSvc`, `InstallService` 활성화 및 시작 |
| 5 | `certutil -generateSSTFromWU`로 루트 인증서 저장소 파일 생성 |
| 6 | `certutil -addstore -f Root`로 신뢰할 수 있는 루트 인증 기관 저장소에 인증서 추가 |

---

## 요구 사항

- Windows 10 또는 Windows 11
- Windows PowerShell 5.1 이상
- 관리자 권한
- Windows Update 인증서 엔드포인트에 접근 가능한 네트워크
- 대상 PC를 수정할 수 있는 권한

---

## 안전 주의사항

본인이 소유하거나 관리하는 PC, 또는 소유자/관리자가 명시적으로 복구를 허가한 PC에서만 사용하세요.

이 도구는 다음 항목을 변경할 수 있습니다.

- Windows Update 정책 값
- Windows 서비스 시작 설정
- Windows Update 작업 폴더
- 로컬 컴퓨터의 신뢰 루트 인증서 저장소

PC방, 학교, 회사, 기타 관리 대상 PC에서는 반드시 시스템 소유자 또는 관리자 허가를 받은 뒤 실행해야 합니다.

---

## 하지 않는 것

이 프로젝트는 다음을 하지 않습니다.

- Xbox, Game Pass, Microsoft Store, 결제, 계정, 지역, DRM, 라이선스 검사 우회
- Microsoft Store, Xbox 앱, 게임 바이너리 패치 또는 수정
- 게임 파일 수정
- 계정 정보 수집
- 자체 원격 서버 통신
- 시작 프로그램 등록
- 백그라운드 상주
- 백신 또는 엔드포인트 보안 제품 비활성화

---

## 빌드

실행 파일은 PowerShell 복구 스크립트를 실행하는 작은 C# 런처입니다. 실행 파일 옆에 `.ps1` 파일이 있으면 해당 파일을 사용하고, 실행 파일만 복사된 경우 내부에 포함된 스크립트를 임시 폴더로 추출해 실행합니다.

Windows PowerShell에서 빌드합니다.

```powershell
$src = ".\XboxGamePass_PCBang_Fix_Launcher.cs"
$script = ".\XboxGamePass_PCBang_Fix.ps1"
$out = ".\XboxStoreCertRepair.exe"

Add-Type -AssemblyName Microsoft.CSharp
$provider = New-Object Microsoft.CSharp.CSharpCodeProvider
$params = New-Object System.CodeDom.Compiler.CompilerParameters
$params.GenerateExecutable = $true
$params.GenerateInMemory = $false
$params.OutputAssembly = $out
$params.CompilerOptions = "/target:exe"
[void]$params.ReferencedAssemblies.Add("System.dll")
[void]$params.EmbeddedResources.Add($script)
$result = $provider.CompileAssemblyFromFile($params, $src)

if ($result.Errors.Count -gt 0) {
    $result.Errors | ForEach-Object { $_.ToString() }
    exit 1
}
```

---

## 저장소 이름과 토픽 추천

검색에 유리한 저장소 이름:

- `xbox-app-store-0x80096004-fix`
- `xbox-store-cert-repair`
- `microsoft-store-xbox-app-repair`

추천 GitHub topics:

- `xbox-app`
- `game-pass`
- `microsoft-store`
- `windows-update`
- `0x80096004`
- `root-certificates`
- `powershell`
- `windows-10`
- `windows-11`

---

## 상표 고지

Microsoft, Windows, Microsoft Store, Xbox, Game Pass는 Microsoft 그룹사의 상표입니다.

이 프로젝트는 Microsoft와 관련이 없으며, Microsoft의 승인, 보증, 후원, 제휴를 받은 공식 도구가 아닙니다. 제품명은 호환성과 이 도구가 복구하려는 설치 오류를 설명하기 위해서만 사용됩니다.

---

## 라이선스

Apache License 2.0. 자세한 내용은 [LICENSE](LICENSE)를 확인하세요.
