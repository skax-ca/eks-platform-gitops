# eks-platform-gitops

**읽는 사람**: 이 저장소의 매니페스트를 고치거나, 클러스터·addon을 새로 등록하는 사람.

**오너**: GitHub org [`skax-ca`](https://github.com/skax-ca) 소속. 설계 문의는 `iac-module-library`, 클러스터·IAM 문의는 `eks-reference-infra` 쪽과 겹칠 수 있다 — 아래 "다루는 것 / 다루지 않는 것" 참고.

**플랫폼 GitOps monorepo(계층 2)** — ArgoCD가 pull로 reconcile하는 플랫폼 소관 매니페스트 저장소.

⛔ **설계 SSOT는 이 저장소가 아니다.** 규약을 바꾸려면 [`skax-ca/iac-module-library`의 `docs/`](https://github.com/skax-ca/iac-module-library/tree/main/docs)를 먼저 고친다. 문서 목록은 [`docs/README.md`](https://github.com/skax-ca/iac-module-library/blob/main/docs/README.md)가 소유한다.

---

## 목차

- [현재 경로: self-managed ArgoCD (helm)](#현재-경로-self-managed-argocd-helm)
- [이 저장소가 다루는 것 / 다루지 않는 것](#이-저장소가-다루는-것--다루지-않는-것)
- [레이아웃](#레이아웃)
- [부트스트랩 — 자기소멸(self-superseding) 원칙](#부트스트랩--자기소멸self-superseding-원칙)
- [`bootstrap/argocd-seed.sh` — vendoring 규약](#bootstrapargocd-seedsh--vendoring-규약)
- [root App 스캔에서 파일을 빼는 방법 — 마커, `exclude` 아님](#root-app-스캔에서-파일을-빼는-방법--마커-exclude-아님)
- [알아야 할 규약](#알아야-할-규약)
  - [addon 네임스페이스 규칙](#addon-네임스페이스-규칙)
- [현재 배포된 addon](#현재-배포된-addon)
  - [운영 노트](#운영-노트)

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
| 1. Terraform | 클러스터·baseline addon·IAM·Access Entry | `skax-ca/eks-reference-infra` |
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

- **손으로 apply하는 매니페스트는 저장소에 커밋된 것과 바이트 단위로 동일해야 한다.** 그래야 root App이 첫 sync에서 흡수해 즉시 no-op이 된다 — 다르면 그 차이가 영구 드리프트로 남는다.
- ⛔ **helm values도 예외 없음(0단계)**: `helm install -f`에 넘기는 값은 저장소 파일 그대로 써야 하며, `--set`은 쓰지 않는다.
- ⛔ **완료 조건**: 초기 비밀번호 교체 + `argocd-initial-admin-secret` 삭제. 선택이 아니라 완료 조건이다.

## `bootstrap/argocd-seed.sh` — vendoring 규약

**SSOT는 이 저장소가 아니라 [`skax-ca/eks-reference-infra`의 `scripts/argocd-seed.sh`](https://github.com/skax-ca/eks-reference-infra/blob/main/scripts/argocd-seed.sh)다.**

⛔ **이 사본을 편집하지 않는다.** 고칠 일이 생기면 SSOT 저장소를 고치고 여기로 다시 복사한다.

**사본이 필요한 이유**
- workbench는 SSM 전용이라 `scp`가 없다.
- 이 저장소를 여는 GitHub App의 설치 범위는 이 저장소 하나뿐이다 — SSOT 저장소까지 범위에 넣으면 ArgoCD가 배포 코드까지 읽게 된다.
- 사본이 여기 있으면 클론 한 번으로 매니페스트와 스크립트가 함께 온다.

**드리프트 검사**(SSOT 저장소 체크아웃에서 한 줄):
```bash
diff <(grep -v '^#V#' bootstrap/argocd-seed.sh) <eks-reference-infra>/scripts/argocd-seed.sh
```
사본 머리의 vendoring 배너는 모든 줄이 `#V#`로 시작한다 — 그 줄을 뺀 나머지는 SSOT와 바이트 단위로
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

🔴 **`exclude`를 늘리면 데드락을 만들 수 있다.**
1. root App은 자기 spec을 git에서 읽어 갱신하려면 먼저 저장소를 렌더해야 한다.
2. 그 렌더는 **아직 적용되지 않은 옛 `exclude`**로 수행된다.
3. 새 `exclude`가 걸러야 할 파일을 옛 `exclude`가 못 걸러내면 렌더가 실패한다.
4. 렌더가 실패하니 새 `exclude`는 영원히 적용되지 않는다.

마커는 파일 자신 안에 있어 이 순서 문제 자체가 없다.

🔴 **마커의 함정 — 마커를 설명하는 주석도 마커다.** 판정은 파일 전체의 단순 문자열 포함 검사라, 주석이든
문서든 그 문자열이 한 번이라도 나타나면 파일 전체가 스캔에서 빠진다.

- `root-app.yaml` 자신의 주석에 마커 문자열을 그대로 적으면 **root-app이 자기 자신을 스캔에서 제외**한다 —
  에러 없이 조용히, 영구 `OutOfSync`로만 드러난다.
- ⇒ 마커 문자열은 `.md` 문서(스캔 대상 확장자가 아니다)나 실제로 제외할 파일에만 적는다. 다른 `.yaml`에는
  *"README의 root App 스캔 절 참조"*로만 가리킨다.

**자기 점검**(의도 밖 파일이 마커를 물고 있지 않은지):
```bash
grep -rl 'argocd:skip-file-rendering' --include='*.yaml' --include='*.yml' --include='*.json' . \
  | grep -v -e 'addons/karpenter/nodepool/' -e 'addons/kyverno/custom-policies/'
```
출력이 있으면 해당 파일이 조용히 스캔에서 빠지고 있다는 뜻이다. 새 로컬 helm 차트 디렉토리를 추가하면
이 `-e` 목록에도 경로를 더한다 — 안 그러면 이 명령 자체가 정상 마커를 "문제"로 오탐한다.

⚠️ **마커는 root-app만 빼는 게 아니라 "Directory 타입으로 이 파일을 읽는 모든 Application"에서 뺀다.**

- 어떤 디렉토리를 전담하는 Application이 있어도, `Chart.yaml`이 없어 Directory 타입으로 잡히면
  **그 Application도 자기 담당 파일을 스스로 걸러버린다.**
- 증상: 적용 리소스 0개인 채로 `Synced`/`Healthy`로 보이는 조용한 실패라 알아채기 어렵다
  (`addons/kyverno/custom-policies/`에서 실제 발생).
- 대응: 전담 Application이 있는 디렉토리는 클러스터별 값이 갈리지 않아도 `Chart.yaml`을 둬서 Helm
  타입으로 인식되게 한다 — 마커는 텍스트 스캔이라 Helm 렌더링 엔진은 그냥 주석으로 무시한다.

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

⚠️ **`cluster-autoscaler`는 이 표의 바를 통과하지 못한 채로 예외에 들어갔다.** 공식 문서 근거도
APF 같은 기술적 강제도 없다.

- 순서: Terraform 쪽 Pod Identity association을 `kube-system/cluster-autoscaler`로 **먼저** 고정
  (관례로 선택, `iac-module-library` `docs/architectures/eks-gitops-hub-spoke/choose-your-path.md` 참조) → 이 매니페스트가 거기 맞춤.
- 즉 위 근거 3(집행 장치)과 인과가 반대다 — association이 원인이 아니라 결과다.
- 그래서 근거 3과 같은 층으로 세지 않고 정직하게 **약한 예외**로 남겨 둔다. 새 예외를 추가할 때 이
  항목을 전례로 들지 않는다.

전용 ns addon을 추가할 때는 `syncPolicy.syncOptions`에 `CreateNamespace=true`를 넣는다. 자동 생성된
Namespace는 AppProject `clusterResourceWhitelist`의 검사 대상이므로 `{group: "", kind: Namespace}`를
열어야 한다. `managedNamespaceMetadata`는 쓰지 않는다 — 켜면 그 ns가 ArgoCD 추적 대상이 되어
`prune: true`와 겹칠 때 addon 제거가 네임스페이스째 지운다.

---

## 현재 배포된 addon

**baseline vs catalog 판단 기준**: Terraform 쪽 `enable_*` 기본값을 따르지 않는다 —
`aws-load-balancer-controller`가 반증 사례다(Terraform 기본값은 `false`인데도 baseline). 가르는
축은 **워크로드 아키텍처와 무관하게 플랫폼이 보편적으로 요구하는가**다.

- **baseline**(ALBC·Karpenter·Kyverno·Gateway API 표준 CRD): 전 클러스터에 무조건 배포.
- **catalog**(KEDA·cluster-autoscaler): 특정 아키텍처를 선택한 클러스터만 `addon-<name>: enabled`
  라벨로 구독.

| addon | chart | 버전 | namespace | 배포 방식 |
|---|---|---|---|---|
| `argocd`(자기 관리) | `argoproj.github.io/argo-helm` / `argo-cd` | 10.3.0 | `argocd` | seed 흡수, `automated.selfHeal: true` · `prune: false` |
| `aws-load-balancer-controller` | `aws.github.io/eks-charts` | 3.5.0 | `kube-system` | baseline(전 클러스터, `environment` 라벨 존재 시 매칭) |
| `karpenter` | `public.ecr.aws/karpenter`(OCI) | 1.14.0 | `kube-system` | baseline |
| `karpenter` NodePool/EC2NodeClass | 로컬 차트(`addons/karpenter/nodepool/`) | — | `kube-system` | baseline |
| `kyverno` + `kyverno-policies` | `kyverno.github.io/kyverno` | 3.8.2 | `kyverno` | baseline, `CreateNamespace=true` |
| Gateway API 표준 CRD | git repo(디렉토리) `kubernetes-sigs/gateway-api` | v1.6.2 | `kube-system`(형식상 값) | baseline. AWS 전용 Gateway CRD는 별도 addon 없이 `aws-load-balancer-controller` chart의 `crds/` 폴더가 이미 설치한다 |
| `keda` | `kedacore.github.io/charts` | 2.20.2 | `keda` | opt-in 카탈로그(cluster Secret 라벨 `addon-keda: enabled`) |
| `cluster-autoscaler` | `kubernetes.github.io/autoscaler` | 9.59.0 | `kube-system` | opt-in 카탈로그(cluster Secret 라벨 `addon-cluster-autoscaler: enabled`) — dev 구독 중(taint 분리 실측 검증 완료) |

### 운영 노트

- **Kyverno Audit 모드**: `validationFailureAction: Audit`, `failurePolicy: Ignore`로 운영 — 웹훅에
  닿지 못해도 백그라운드 스캔이 PolicyReport를 계속 만든다. `argocd` 네임스페이스는 Kyverno 웹훅의
  기본 제외 대상이 **아니다**(`kube-system`·`kyverno`만 제외) — Enforce 전환 시 `failurePolicy: Fail`과
  함께 올려야 순환 의존(Kyverno 장애 → ArgoCD 막힘 → Kyverno를 고칠 수단 상실)을 피한다.
- **KEDA**: in-cluster 트리거만 쓴다(AWS 스케일러 미사용) — Pod Identity·IAM 연결이 없어 이 addon은
  계층 2 안에서 완결된다. SQS·CloudWatch 트리거가 필요해지면 `modules/eks-cluster/iam.tf`에
  `keda/keda-operator` Pod Identity association을 연다(ALBC·external-dns와 같은 패턴).
- **`argocd` 자기 관리**: `ServerSideApply=true`로 자신을 흡수한다. `Force=true`·`Replace=true`는
  쓰지 않는다 — 대상이 ArgoCD 자신이라 두 옵션이 `Secret/argocd-secret`의 런타임 값(admin 비밀번호
  해시·`server.secretkey`·TLS)을 지울 수 있다. `ServerSideApply`는 자신이 선언한 필드만 소유하므로
  차트가 선언하지 않은 값은 건드리지 않는다.
- **`kyverno`/`kyverno-policies` diff 옵션**: `ServerSideApply=true`에 더해
  `compare-options: ServerSideDiff=true`도 쓴다 — CRD·ClusterPolicy의 일부 필드가 apiserver
  기본값으로 채워져 영구 `OutOfSync`가 되는 것을 막는다. `IncludeMutationWebhook=true`는 켜지 않는다
  — 웹훅 변형까지 diff에 들어와 새 drift를 만든다.
