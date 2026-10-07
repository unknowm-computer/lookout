# GitHub 업데이트 배포

현재 저장소는 [unknowm-computer/lookout](https://github.com/unknowm-computer/lookout)이며 공개 상태다. GitHub Releases에 파일을 보관하므로 고정 IP나 별도 서버는 필요하지 않다. 앱은 로그인 정보 없이 아래 피드를 읽는다.

버전 수정과 Git push 이후 해당 버전의 배포 파일을 GitHub Release로 게시해야 업데이트를 제공할 수 있다. 소스만 업로드하면 앱에 새 업데이트가 나타나지 않는다.

```text
https://github.com/unknowm-computer/lookout/releases/latest/download/appcast.xml
```

주소·공개 키·키체인 계정은 `Resources/UpdateConfiguration.json`에 있다. 앱에는 주소와 공개 키만 넣으며 개인 키는 이 배포 Mac의 키체인에 저장한다. 다른 Mac에서 배포할 때는 기존 서명 키를 안전하게 이전해야 한다. 기존 앱을 업데이트하려고 키를 새로 생성하거나 공개 키만 바꾸지 않는다.

## 1. 배포 파일 준비

현재 배포 버전은 `0.6.2` (build `8`)이며 업데이트 연결은 `0.6.0` (build `6`)부터 포함한다. 다음 배포는 `Resources/Info.plist`의 `CFBundleShortVersionString`과 `CFBundleVersion`을 모두 증가시킨다. 예를 들어 다음 배포는 `0.6.3` / `9`로 변경한다. 이미 게시된 태그와 파일을 교체하지 않는다.

```sh
python3 scripts/prepare-release.py
```

스크립트는 저장소 주소·서명 키 일치를 검사하고 앱·DMG를 빌드한 뒤 업데이트 ZIP 서명과 appcast를 생성한다. `build/releases/v0.6.2-build8/` 예시:

| 파일 | 용도 |
| --- | --- |
| `Lookout-0.6.2.zip` | Sparkle가 다운로드·검증·설치할 앱 |
| `Lookout-0.6.2.dmg` | 최초 설치·수동 설치용 |
| `appcast.xml` | 버전·최소 OS·ZIP 주소·서명·크기 |
| `SHA256SUMS.txt` | 생성한 세 파일의 SHA-256 확인 |

같은 결과 폴더가 있으면 중단한다. 아직 게시하지 않은 파일을 다시 만들 때만 기존 로컬 폴더를 다른 위치로 옮긴 뒤 재실행한다. 이미 게시한 파일은 새 버전으로 배포한다. `ditto`로 만든 ZIP을 다시 압축하거나 appcast의 파일 정보를 임의로 수정하면 서명·크기 계약이 맞지 않으므로 생성한 파일 그대로 올린다.

파일을 만드는 것만으로 Git commit/push, Release 게시, 실행 중인 앱 교체를 수행하지 않는다.

## 2. GitHub에 게시

1. 이번 소스를 검토·commit·push하여 배포할 코드가 GitHub에 있는지 확인한다.
2. 저장소의 **Releases → Draft a new release**를 연다.
3. 올린 커밋을 대상으로 `v0.6.2` 태그와 `Lookout 0.6.2` 제목을 지정한다. 다음 버전이면 이름도 함께 바꾼다.
4. 해당 결과 폴더의 ZIP·DMG·`appcast.xml`·`SHA256SUMS.txt`를 모두 첨부한다.
5. **Pre-release**로 지정하지 않고 **최신 Release**로 게시한다. Draft 상태에서는 앱이 다운로드할 수 없다.
6. 피드 주소를 열어 XML 응답과 ZIP 다운로드 주소가 접근 가능한지 확인한다.

피드 주소는 매번 같은 `latest/download/appcast.xml`을 사용한다. XML 안의 ZIP 주소는 해당 버전 태그에 고정되므로 최신 Release가 바뀌어도 이미 표시된 업데이트의 파일이 달라지지 않는다. appcast 없는 다른 Release를 최신으로 만들면 업데이트 확인이 실패한다.

## 3. 처음 설치와 후속 업데이트

피드·공개 키가 없던 기존 앱은 새 버전을 찾을 수 없다. 이번 DMG로 한 번 수동 설치한 뒤 앱의 **설정 → 업데이트… → 업데이트 확인**을 사용한다. `0.6.0` / build `6` 및 `0.6.1` / build `7` 앱은 이번 `0.6.2` / build `8`을 새 업데이트로 판단한다. 같은 build `8` 앱은 최신 버전으로 판단하며 이후 배포는 build `9` 이상을 사용한다.

`새 버전 자동으로 확인`은 기본 꺼짐이다. 켜더라도 설치·재실행은 사용자가 선택한다. 앱 설정은 같은 Bundle ID를 유지하며 최근 기록은 재실행으로 초기화된다.

현재 앱은 개인용 ad-hoc 서명이며 ZIP에 별도 Ed25519 서명을 적용한다. 최초 수동 설치는 README의 개인용 설치 절차를 사용한다. 0.6.1 Release 게시 후 Apple Silicon·macOS 27에서 검증용 0.6.0 복사본의 공개 피드 조회·다운로드·설치·0.6.1 재실행을 확인했다. Intel 및 macOS 15·26의 실제 업데이트·보안 처리 동작은 별도 실기기 확인이 필요하다.

## 참고

- [Sparkle 업데이트 게시 문서](https://sparkle-project.org/documentation/publishing/)
- [GitHub 최신 Release 파일 링크](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)
