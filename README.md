# iac-platform-gitops

**읽는 사람**: 이 저장소의 매니페스트를 고치거나, 클러스터·addon을 새로 등록하는 사람.

**플랫폼 GitOps monorepo(계층 2)** — ArgoCD가 pull로 reconcile하는 플랫폼 소관 매니페스트 저장소.

⛔ **설계 SSOT는 이 저장소가 아니다.** 규약을 바꾸려면 [`skax-ca/iac-module-library`의 `docs/`](https://github.com/skax-ca/iac-module-library/tree/main/docs)를 먼저 고친다. 문서 목록은 [`docs/README.md`](https://github.com/skax-ca/iac-module-library/blob/main/docs/README.md)가 소유한다.

---

## 현재 경로: self-managed ArgoCD (helm)

관리형 EKS Capability로 전환할 수도 있는 설계이지만, **이 배포는 self-managed를 먼저 구현한다.**
매니페스트 대부분은 경로가 바뀌어도 그대로다. 갈리는 것은 아래 셋뿐이다.

| 갈림점 | 지금(self-managed) | 관리형으로 바꾸면 |
|---|---|---|
| cluster Secret `server` | `https://kubernetes.default.svc` | EKS 클러스터 ARN |
| `repoURL` | GitHub 직접 + GitHub App | CodeConnections 프록시 URL(계정·리전·커넥션 ID 포함) |
| AppProject `destinations.server` | `https://kubernetes.default.svc` | EKS 클러스터 ARN |

Application / ApplicationSet / AppProject 자체는 양쪽이 동일하다.

## 이 저장소가 다루는 것 / 다루지 않는 것

3계층 소유 모델에서 **계층 2만** 담당한다.

| 계층 | 무엇 | 어디 |
|---|---|---|
| 1. Terraform | 클러스터·baseline addon·IAM·Access Entry | `skax-ca/iac-reference-infra` |
| **2. 플랫폼 GitOps** | **helm addon · 클러스터 등록 · AppProject 가드레일** | **이 저장소** |
| 3. 앱 GitOps | 비즈니스 워크로드 | 앱팀별 repo(범위 밖) |

⛔ **`apps/` 디렉토리는 의도적으로 없다.** 플랫폼 addon 업그레이드는 fleet 전체에, 앱 배포는 한 팀에
영향을 준다 — 같은 저장소에 두면 리뷰어·릴리스 주기·blast radius가 섞인다.

## 레이아웃

```
bootstrap/root-app.yaml      # App-of-Apps root — seed 대상. 이후 자기 자신을 흡수
bootstrap/argocd-values.yaml # ArgoCD 자신의 helm values. root App 스캔에서 제외됨
bootstrap/argocd-app.yaml    # ArgoCD 자기 관리 Application. 위 values를 $values로 읽는다
bootstrap/argocd-seed.sh     # VENDORED — seed 실행 스크립트. SSOT는 모듈 repo(아래 절)
clusters/<env>/<cluster>/    # cluster Secret + per-cluster values. 새 클러스터 = 디렉토리 1개(O(1))
projects/                    # AppProject 가드레일 — platform.yaml + <team>.yaml
addons/baseline/             # 전 클러스터 팬아웃 ApplicationSet(environment 라벨)
addons/catalog/              # opt-in 카탈로그 — 구독한 클러스터만(addon-<name> 라벨)
addons/karpenter/nodepool/   # NodePool/EC2NodeClass 로컬 helm 차트. root App 스캔에서 제외됨
addons/kyverno/custom-policies/ # 이 저장소가 직접 소유하는 ClusterPolicy. 로컬 helm 차트, root App 스캔에서 제외됨
```

**확장 규칙(O(1))**: 새 클러스터는 `clusters/<env>/<cluster>/` 1개만 추가하면 cluster generator가
라벨로 자동 팬아웃한다. 새 앱팀은 `projects/<team>.yaml` 가드레일 1개만 추가한다.

---

## 부트스트랩 — 자기소멸(self-superseding) 원칙

최초 1회 workbench에서 seed한 뒤, root App이 그 리소스들을 **자기 소유로 흡수**한다.

```
0. helm install argo-cd          (workbench, 사람)   ← self-managed 고유
1. Access Entry                  ⛔ 불필요 — ArgoCD가 클러스터 안에 있다(spoke는 필요)
2. GitHub App repository Secret  (kubectl seed)
3. projects/platform.yaml        (kubectl seed)
4. clusters/.../cluster-secret.yaml (kubectl seed)
5. bootstrap/root-app.yaml       (kubectl seed) → 자기 자신을 흡수
6. 이후 전부                      GitOps(pull) — argocd chart 자체도 Application으로 흡수
```

**손으로 apply하는 매니페스트는 이 저장소에 커밋된 것과 바이트 단위로 동일해야 한다.** 그래야 root
App이 첫 sync에서 흡수하고 즉시 no-op이 된다. 다르면 그 차이가 영구 드리프트로 남는다.
⛔ 이 원칙은 helm values에도 걸린다(0단계) — `helm install -f`에 넘기는 값은 저장소 파일 그대로여야
하며, `--set`을 쓰지 않는다.

⛔ **완료 조건 1건 미이행**: 초기 비밀번호 교체 + `argocd-initial-admin-secret` 삭제. 선택이 아니라
완료 조건이다.

## `bootstrap/argocd-seed.sh` — vendoring 규약

**SSOT는 이 저장소가 아니라 [`skax-ca/iac-module-library`의 `scripts/argocd-seed.sh`](https://github.com/skax-ca/iac-module-library/blob/main/scripts/argocd-seed.sh)다.**

⛔ **이 사본을 편집하지 않는다.** 고칠 일이 생기면 모듈 repo를 고치고 여기로 다시 복사한다.

사본이 필요한 이유 — workbench는 SSM 전용이라 `scp`가 없고, 이 저장소를 여는 GitHub App의 설치
범위는 이 저장소 하나뿐이다(모듈 저장소를 그 범위에 넣으면 ArgoCD가 모듈 소스까지 읽게 된다). 사본이
여기 있으면 클론 한 번으로 매니페스트와 스크립트가 함께 온다.

**드리프트 검사**(모듈 repo 체크아웃에서 한 줄):
```bash
diff <(grep -v '^#V#' bootstrap/argocd-seed.sh) <module-repo>/scripts/argocd-seed.sh
```
사본 머리의 vendoring 배너는 모든 줄이 `#V#`로 시작한다 — 그것을 뺀 나머지는 SSOT와 바이트 단위로
같아야 한다.

---

## root App 스캔에서 파일을 빼는 방법 — 마커, `exclude` 아님

`bootstrap/root-app.yaml`은 저장소 루트를 재귀로 스캔해 모든 `.yaml`/`.yml`/`.json`을 매니페스트로
적용한다. `addons/karpenter/nodepool/`의 helm 템플릿(`{{name}}` 등 미치환 문법)처럼 **매니페스트가
아닌 파일**은 스캔에서 빠져야 한다.

⛔ **`root-app.yaml`의 `exclude` 목록을 늘리지 않는다.** 대신 파일 안에
`+argocd:skip-file-rendering` 마커를 넣는다.

- 평문 YAML(`Chart.yaml`·`values.yaml`): `# +argocd:skip-file-rendering`
- helm 템플릿: `{{- /* +argocd:skip-file-rendering … */ -}}`(파일 내용에는 남고 렌더 출력에는
  안 남는다)

🔴 **`exclude`를 늘리면 데드락을 만들 수 있다.** root App은 자기 spec을 git에서 읽어 갱신하는데,
그러려면 먼저 저장소를 렌더해야 한다 — 그 렌더는 **아직 적용되지 않은 옛 `exclude`**로 수행되므로,
새 `exclude`가 걸러야 할 파일을 옛 `exclude`가 못 걸러내면 렌더가 실패하고, 렌더가 실패하니 새
`exclude`가 영원히 적용되지 않는다. 마커는 파일 자신 안에 있으므로 이 순서 문제 자체가 없다.

🔴 **마커의 함정 — 마커를 설명하는 주석도 마커다.** 판정은 파일 전체 문자열 포함 검사다. 주석이든
문서든 그 문자열이 한 번이라도 나타나면 그 파일은 통째로 스캔에서 빠진다. `root-app.yaml` 자신의
주석에 마커 문자열을 그대로 적으면 **root-app이 자기 자신을 스캔에서 제외**한다 — 에러 없이 조용히,
영구 `OutOfSync`로만 드러난다. ⇒ 마커 문자열은 `.md` 문서(스캔 대상 확장자가 아니다)나 실제로 제외할
파일에만 적는다. 다른 `.yaml`에는 *"README의 root App 스캔 절 참조"*로만 가리킨다.

**자기 점검**(의도 밖 파일이 마커를 물고 있지 않은지):
```bash
grep -rl 'argocd:skip-file-rendering' --include='*.yaml' --include='*.yml' --include='*.json' . \
  | grep -v -e 'addons/karpenter/nodepool/' -e 'addons/kyverno/custom-policies/'
```
출력이 있으면 그 파일은 조용히 스캔에서 빠지고 있다. 새 로컬 helm 차트 디렉토리를 추가할 때마다
이 `-e` 목록에도 그 경로를 더한다 — 안 그러면 이 명령 자체가 정상적인 마커를 "문제"로 오탐한다.

⚠️ **마커는 root-app만 빼는 게 아니라 "Directory 타입으로 이 파일을 읽는 모든 Application"에서
뺀다.** 그 파일을 전담하는 Application이 있다면, `Chart.yaml`이 없어 그 Application도 Directory
타입으로 잡힐 경우 **자기 자신도 자기 담당 파일을 걸러버린다** — 적용 리소스 0개인 채로
`Synced`/`Healthy`로 보이는 조용한 실패라 알아채기 어렵다(`addons/kyverno/custom-policies/`에서
실제 발생, 2026-08-18). 전담 Application이 있는 디렉토리는 **클러스터별 값이 갈리지 않아도**
`Chart.yaml`을 둬서 그 Application이 Helm 타입으로 인식되게 한다 — 마커는 텍스트 스캔이라
Helm 렌더링 엔진은 그냥 주석으로 무시한다.

**`argocd-seed.sh`는 `.sh`라 애초에 directory 소스의 스캔 대상(`.yaml`/`.yml`/`.json`)이 아니다** —
그래서 `exclude`에도, 마커에도 넣지 않는다.

---

## 알아야 할 규약

- ⛔ **`default` AppProject를 쓰지 않는다** — `sourceRepos`/`destinations`/`clusterResourceWhitelist`가
  전부 `'*'`인 완전 개방 상태다. 플랫폼 리소스는 전용 `platform` 프로젝트에 둔다.
- 🔑 **cluster Secret의 이름은 실제 EKS 클러스터명이어야 한다** — ApplicationSet의 `{{name}}`이
  ALBC의 필수 파라미터 `clusterName`으로 그대로 흘러간다. 별칭을 쓰면 조용히 틀린다.
- ⚠️ **cluster Secret의 `project` 필드 주의** — 값을 지정하면 그 프로젝트에서만 쓸 수 있는
  project-scoped cluster가 된다. `platform`과 어긋나면 클러스터가 `unknown`으로 뜨는데 증상이
  원인을 가리키지 않는다.
- ⚠️ **`sourceRepos`는 제3 가드레일이다** — Application의 `repoURL`이 여기 없으면
  `InvalidSpecError`로 sync 자체가 안 선다. addon을 추가할 때마다 그 chart repo를 추가한다.
- ⚠️ **`clusterResourceWhitelist`는 `[]`로 시작한다** — addon마다 그 addon이 실제로 만드는 kind만
  명시 개방한다.
- **cert-manager · external-dns · 관측성 컨트롤러는 여기 없다** — Terraform community addon 소관이고,
  이 저장소에는 그 설정(CR·애노테이션)만 놓인다.

### addon 네임스페이스 규칙

계층 2(GitOps helm addon)는 addon마다 전용 네임스페이스를 신설한다. **예외는 셋 —
`aws-load-balancer-controller`·`karpenter`·`cluster-autoscaler` → `kube-system`.**

⛔ 예외를 늘리려면 아래에 준하는 근거가 필요하다. *"차트 기본값이 `kube-system`이라서"*는 근거가
아니다.

| # | 예외 근거 | 성격 |
|---|---|---|
| 1 | Karpenter 공식이 이유까지 밝힌다 — `kube-system`의 호출만 `system-leader-election`·`kube-system-service-accounts` FlowSchema를 타고 우선순위를 받는다. 다른 ns면 custom FlowSchema를 직접 소유해야 한다 | 🔑 기술적(APF) — 어기면 apiserver 스로틀링 때 Karpenter가 굶는다 |
| 2 | ALBC도 공식이 `kube-system` — AWS EKS User Guide·upstream kubernetes-sigs 둘 다 | 관례 |
| 3 | Pod Identity association이 이미 `kube-system` | 집행 장치 — 어기면 자격증명이 안 붙는다 |

⚠️ **`cluster-autoscaler`는 이 표의 바를 통과하지 못한 채로 예외에 들어갔다.** 공식 문서 근거도,
APF 같은 기술적 강제도 없다 — Terraform 쪽 Pod Identity association을 `kube-system/
cluster-autoscaler`로 **먼저** 고정한 뒤(사용자가 관례로 선택, `iac-module-library`
`docs/02-choose-your-path.md` 참조) 이 매니페스트가 거기 맞춘 것이라, 위 근거 3(집행 장치)과
인과가 반대다 — association이 원인이 아니라 결과다. 그래서 근거 3과 같은 층으로 세지 않고
정직하게 약한 예외로 남겨 둔다. 새 예외를 추가할 때 이 항목을 전례로 들지 않는다.

전용 ns addon을 추가할 때는 `syncPolicy.syncOptions`에 `CreateNamespace=true`를 넣는다. 자동 생성된
Namespace는 AppProject `clusterResourceWhitelist`의 검사 대상이므로 `{group: "", kind: Namespace}`를
열어야 한다. `managedNamespaceMetadata`는 쓰지 않는다 — 켜면 그 ns가 ArgoCD 추적 대상이 되어
`prune: true`와 겹칠 때 addon 제거가 네임스페이스째 지운다.

---

## 현재 배포된 addon

**baseline vs catalog 판단 기준**: Terraform 쪽 `enable_*` 기본값을 따르지 않는다 —
`aws-load-balancer-controller`가 반증 사례다(Terraform 기본값은 `false`인데도 baseline).
가르는 축은 **워크로드 아키텍처와 무관하게 플랫폼이 보편적으로 요구하는가**다.
baseline(ALBC·Karpenter·Kyverno)은 전 클러스터에 무조건 깔리고, catalog(KEDA·
cluster-autoscaler)는 **특정 아키텍처를 선택한 클러스터만** `addon-<name>: enabled`
라벨로 구독한다.

| addon | chart | 버전 | namespace | 배포 방식 |
|---|---|---|---|---|
| `argocd`(자기 관리) | `argoproj.github.io/argo-helm` / `argo-cd` | 10.3.0 | `argocd` | seed 흡수, `automated.selfHeal: true` · `prune: false` |
| `aws-load-balancer-controller` | `aws.github.io/eks-charts` | 3.5.0 | `kube-system` | baseline(전 클러스터, `environment: dev`) |
| `karpenter` | `public.ecr.aws/karpenter`(OCI) | 1.14.0 | `kube-system` | baseline |
| `karpenter` NodePool/EC2NodeClass | 로컬 차트(`addons/karpenter/nodepool/`) | — | `kube-system` | baseline |
| `kyverno` + `kyverno-policies` | `kyverno.github.io/kyverno` | 3.8.2 | `kyverno` | baseline, `CreateNamespace=true` |
| `keda` | `kedacore.github.io/charts` | 2.20.2 | `keda` | opt-in 카탈로그(cluster Secret 라벨 `addon-keda: enabled`) |
| `cluster-autoscaler` | `kubernetes.github.io/autoscaler` | 9.59.0 | `kube-system` | opt-in 카탈로그(cluster Secret 라벨 `addon-cluster-autoscaler: enabled`) — dev 구독 중(2026-08-14, taint 분리 실측 검증 완료) |

Kyverno는 Audit 모드(`validationFailureAction: Audit`, `failurePolicy: Ignore`)로 운영한다 — 웹훅에
닿지 못해도 백그라운드 스캔이 PolicyReport를 계속 만든다. `argocd` 네임스페이스는 Kyverno 웹훅의
기본 제외 대상이 **아니다**(`kube-system`·`kyverno`만 제외) — Enforce 모드로 전환할 때는
`failurePolicy: Fail`과 함께 올려야 순환 의존(Kyverno 장애 → ArgoCD 막힘 → Kyverno를 고칠 수단
상실)을 피할 수 있다.

KEDA는 in-cluster 트리거만 쓴다(AWS 스케일러 미사용) — Pod Identity·IAM 연결이 없어 이 addon은
계층 2 안에서 완결된다. SQS·CloudWatch 트리거가 필요해지면 `modules/eks-cluster/iam.tf`에
`keda/keda-operator` Pod Identity association을 연다(ALBC·external-dns와 같은 패턴).

`argocd` Application은 `ServerSideApply=true`로 자신을 흡수한다. `Force=true`·`Replace=true`는
쓰지 않는다 — 적용 대상이 ArgoCD 자신이라, 그 두 옵션은 `Secret/argocd-secret`의 런타임 값(admin
비밀번호 해시·`server.secretkey`·TLS)을 지울 수 있다. `ServerSideApply`는 자신이 선언한 필드만
소유하므로 차트가 선언하지 않는 그 값들을 건드리지 않는다.

`kyverno`·`kyverno-policies`는 `ServerSideApply=true`에 더해 `compare-options: ServerSideDiff=true`도
쓴다 — CRD·ClusterPolicy의 일부 필드가 apiserver 기본값으로 채워져 영구 `OutOfSync`가 되는 것을
막는다. `IncludeMutationWebhook=true`는 켜지 않는다 — 웹훅 변형까지 diff에 들어와 새 drift를
만든다.
