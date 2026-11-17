# Lookout 코드 서명

Lookout 본체·팬 도우미·창 배치 도우미는 **Lookout 전용 고정 자체 서명 인증서**를 사용한다. LineLens와 인증서·개인 키·키체인을 공유하지 않는다. Developer ID 서명이나 Apple 공증은 아니다. Sparkle 업데이트 ZIP의 Ed25519 서명은 별개이며 기존 키를 그대로 사용한다.

## 키와 프로젝트 설정

개인 자료는 서명 Mac의 `~/Library/Application Support/Lookout/Signing/`에 있다.

| 파일 | 내용 |
| --- | --- |
| `Lookout.keychain-db` | Lookout 전용 인증서와 개인 키 |
| `password` | 전용 키체인의 잠금 해제 암호. Mac 로그인 암호가 아님 |
| `certificate.cer` | 공개 인증서 |
| `identity.sha1` | 공개 인증서의 지문 |

프로젝트의 `Resources/SigningIdentity.plist`에는 공개 인증서 지문과 본체 Bundle ID만 기록한다. SHA-1 지문은 macOS `codesign`의 인증서 선택·검증에 쓰며 파일 무결성 캐시는 계속 SHA-256을 사용한다. 키체인·암호·개인 키를 Git, 앱, DMG, ZIP에 넣지 않는다.

인증서 이름은 `Lookout Local Signing`, 키는 RSA 3072비트, 인증서 기간은 10년이다. 키체인 잠금은 잠자기 및 15분 경과 시 적용된다. 빌드 도구가 암호 파일을 직접 읽어 열며 암호를 프로세스 인자나 로그에 넣지 않는다. 키 접근 ACL은 `codesign`에 한정하고, 기본 키체인·검색 목록을 바꾸지 않는다. 인증서 신뢰는 현재 사용자의 CodeSigning 정책만 설정한다. 생성 과정의 PEM·PKCS#12는 정리한다.

## 최초 준비와 빌드

최초 인증서 생성은 이미 완료했다. 원래 서명 Mac에서 설정을 재확인하려면 다음을 실행한다.

```sh
bash scripts/setup-local-signing.sh
bash scripts/build.sh
```

이미 존재하는 키를 재사용한다. 프로젝트에 지문이 고정된 뒤 키가 없거나 지문이 다르면 새 인증서를 만들지 않고 중단한다. 개인 키가 없어도 `swift build`와 `bash scripts/test.sh`로 소스 빌드·테스트를 할 수 있다. 설치 가능한 앱 번들·DMG·Release를 만들려면 기존 서명 키가 필요하다. 다른 Mac에서 빌드하려면 아래 복원 절차를 따른다.

`scripts/build.sh`는 키 유효성을 먼저 확인하고 임시 폴더에서 앱을 조립한다. 실패하면 기존 `build/Lookout.app`을 보존하며, 임시 서명으로 자동 전환하지 않는다. 본체와 두 도우미의 식별자는 각각 다음과 같다.

- `local.lookout.app`
- `local.lookout.fan-helper`
- `local.lookout.window-helper`

세 구성 요소는 같은 Lookout 인증서로 서명하되 서로의 식별자나 권한은 합치지 않는다. helper 캐시는 인증서 지문을 포함하며 기존 ad-hoc 캐시를 새 고정 서명 대신 사용하지 않는다. 캐시를 읽을 때에도 해당 식별자·인증서·모든 아키텍처의 서명을 검사한다. 공개 캐시에는 개인 키가 없다.

## 다른 Mac에서 서명 복원과 빌드

빌드할 사용자 계정에 Xcode와 Python 3를 준비하고, 터미널에서 Lookout 저장소 루트로 이동한다. Xcode 요구 사항은 [빌드와 실행](../README.md#빌드와-실행)을 참고한다. 아래 `/Volumes/암호화백업/Lookout`은 실제 백업 위치로 바꾼다.

### 1. Signing 폴더 복사

원래 Mac에서 백업한 `Signing` 폴더를 새 Mac의 `~/Library/Application Support/Lookout/Signing/`에 복사한다. `~`는 새 Mac에서 빌드하는 계정의 홈 폴더다. 아래 명령은 대상 폴더가 없을 때만 복사한다. 폴더가 이미 있으면 기존 서명 파일부터 확인한다.

```sh
lookout_signing="$HOME/Library/Application Support/Lookout/Signing"
test ! -e "$lookout_signing" &&
  mkdir -p "$(dirname "$lookout_signing")" &&
  ditto "/Volumes/암호화백업/Lookout/Signing" "$lookout_signing" &&
  chmod 700 "$lookout_signing" &&
  chmod 600 "$lookout_signing/Lookout.keychain-db" "$lookout_signing/password"
```

복사한 폴더에 `Lookout.keychain-db`, `password`, `certificate.cer`, `identity.sha1`이 모두 있어야 한다.

### 2. 인증서 등록과 앱 빌드

설정 스크립트가 복사한 인증서의 지문을 저장소의 고정값과 대조하고 전용 키체인을 연다. 이어서 `certificate.cer`를 현재 사용자 계정의 코드 서명 정책에 신뢰 등록하고 빌드한다. macOS가 신뢰 설정 변경 승인을 요청하면 새 Mac에서 승인한다. [Apple `security` 명령 문서](https://github.com/apple-oss-distributions/Security/blob/main/SecurityTool/macOS/security.1)

```sh
lookout_signing="$HOME/Library/Application Support/Lookout/Signing"
bash scripts/setup-local-signing.sh &&
  security add-trusted-cert -r trustRoot -p codeSign \
    -k "$lookout_signing/Lookout.keychain-db" "$lookout_signing/certificate.cer" &&
  bash scripts/build.sh
```

빌드가 성공하면 `build/Lookout.app`이 생성된다. 앱 빌드나 DMG 생성은 여기까지면 충분하다. 복사한 키체인으로 다른 실기기에서 서명하는 전체 과정은 아직 검증하지 않았으므로, 새 Mac에서 빌드가 성공할 때까지 원본 Mac의 키를 보관한다.

### 3. 기존 Sparkle 키 가져오기

Sparkle 업데이트 ZIP까지 배포하려면, 2단계 빌드가 받아온 `generate_keys`로 기존 `Lookout-Sparkle.key`를 새 Mac의 로그인 키체인에 가져온다. 이미 `local.lookout.app` 계정의 키가 있으면 `-p`로 공개 키를 조회한다. `Resources/UpdateConfiguration.json`의 `publicKey`와 일치하면 기존 키를 사용한다. 다른 키가 있으면 백업 출처와 계정을 먼저 확인한다. [Sparkle 공식 문서](https://sparkle-project.org/documentation/#eddsa-ed25519-signatures)

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account local.lookout.app -f "/Volumes/암호화백업/Lookout/Lookout-Sparkle.key"
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account local.lookout.app -p
```

두 번째 명령이 출력한 공개 키가 `Resources/UpdateConfiguration.json`의 `publicKey`와 일치하는지 확인한다. 배포 스크립트도 ZIP에 서명하기 전에 같은 값을 검사한다. 다음 버전 준비와 게시 절차는 [업데이트 배포](UPDATE_RELEASE.md)를 따른다.

## 업데이트 검증

```sh
python3 scripts/code_signing.py verify-bundle build/Lookout.app
python3 scripts/code_signing.py verify-update /path/to/previous/Lookout.app build/Lookout.app
python3 scripts/test-code-signing.py --integration
```

`verify-update`는 **이미 고정 인증서를 사용하는 두 빌드**의 본체·두 도우미가 서로의 designated requirement를 만족하는지 검사한다. 코드가 변경돼도 인증서와 각 식별자를 유지하는지 확인한다. `--integration` 테스트는 기존 키로 임시 시험 프로그램을 서명할 뿐, 설치 앱·서비스·개인정보 권한을 변경하지 않는다.

`build.sh`도 기존 결과물이 고정 서명이면 같은 양방향 검증을 수행한다. 최초 ad-hoc→고정 인증서 변경은 허용한다. `prepare-release.py`는 압축 전 앱과 ZIP을 다시 푼 앱의 고정 서명까지 확인한다. 버전 증가·Sparkle 서명·배포 절차는 [업데이트 배포](UPDATE_RELEASE.md)를 따른다.

처음 고정 서명 앱을 설치할 때 기존 ad-hoc 신원에서 전환되므로 팬/창 도우미 등록 복구와 손쉬운 사용·화면 기록 재승인이 필요할 수 있다. 이후 동일 인증서를 쓰는 업데이트에서 기존 승인을 유지하는 것이 목적이다. 코드 서명 호환 검사가 실제 macOS 승인 유지·서비스 연결 성공을 대신하지는 않는다. 설치 앱 교체와 OS 권한 검증은 별도로 수행하며, 빌드 스크립트가 권한을 초기화하거나 시스템 설정을 조작하지 않는다.

## 현재 검증 범위 (2026-11-12)

- 최초 ad-hoc → 고정 서명 설치 후 도우미 연결을 복구하고 사용자가 손쉬운 사용 승인을 갱신했다.
- 이후 helper 실행 파일이 동일한 두 차례 UI 업데이트에서 창 도우미 연결·실제 AX 조회가 재승인 없이 유지됐다.
- 코드가 다른 Universal 시험 프로그램을 본체·팬·창 식별자 각각으로 서명해 동일한 지정 요구사항을 만족하는 것을 확인했다.
- 실제 팬/창 helper 코드를 변경한 업데이트와 Sparkle 설치 경로에서의 OS 승인 유지는 아직 검증하지 않았다. 인증서·Bundle ID·실행 설정 변경이나 새로운 권한 추가는 일반 코드 수정과 구분한다.

## 백업과 분실

서명 폴더와 잠금 해제 암호를 안전한 별도 위치에 백업한다. 개인 키는 내보내기 불가로 가져오므로 단순 `.p12` 내보내기를 전제로 하지 않는다. 키체인 백업의 다른 Mac 복원은 별도 검증이 필요하다. 설치받는 사람에게 키체인이나 암호를 배포하지 않는다.

개인 키를 잃으면 기존 서명 신원으로 새 빌드를 만들 수 없다. 새 인증서로 전환하는 것은 가능하지만 프로젝트 지문·배포 절차를 의도적으로 수정하고 사용자에게 재승인을 안내해야 한다. 일반 빌드에서 자동으로 새 키를 생성하거나 고정 지문을 덮어쓰지 않는다.
