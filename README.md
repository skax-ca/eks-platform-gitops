# eks-platform-gitops

**읽는 사람**: 이 저장소의 매니페스트를 고치거나, 클러스터·addon을 새로 등록하는 사람.

**오너**: GitHub org [`skax-ca`](https://github.com/skax-ca) 소속. 설계 문의는 `iac-module-library`가, 클러스터·IAM 문의는 `eks-reference-infra`가 받는다.

**플랫폼 GitOps monorepo(계층 2)** — ArgoCD가 pull로 reconcile하는 플랫폼 소관 매니페스트 저장소.

⛔ **설계 SSOT는 이 저장소가 아니다.** 규약을 바꾸려면 [`skax-ca/iac-module-library`의 `docs/`](https://github.com/skax-ca/iac-module-library/tree/main/docs)를 먼저 고친다. 문서 목록은 [`docs/README.md`](https://github.com/skax-ca/iac-module-library/blob/main/docs/README.md)가 소유한다.

---

## 목차

- [현재 경로: self-managed ArgoCD (helm)](#현재-경로-self-managed-argocd-helm)
- [이 저장소가 다루는 것 / 다루지 않는 것](#이-저장소가-다루는-것--다루지-않는-것)
- [레이아웃](#레이아웃)
- [부트스트랩 — 자기소멸(self-superseding) 원칙](#부트스트랩--자기소멸self-superseding-원칙)
- [`bootstrap/argocd-seed.sh` — 이 저장소가 소유한다](#bootstrapargocd-seedsh--이-저장소가-소유한다)
- [root App이 읽는 범위 — `include` allow-list](#root-app이-읽는-범위--include-allow-list)
- [ApplicationSet 공통 규약](#applicationset-공통-규약)
  - [staged 전파 — `-prd` · `-nonprd` 두 블록](#staged-전파---prd---nonprd-두-블록)
- [helm values — `addons/<addon>/values.yaml`](#helm-values--addonsaddonvaluesyaml)
- [게이트 — 로컬 훅과 CI](#게이트--로컬-훅과-ci)
- [알아야 할 규약](#알아야-할-규약)
  - [cluster Secret 라벨 계약](#cluster-secret-라벨-계약)
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
| `repoURL` | GitHub 직접(public 저장소, 자격증명 없음) | CodeConnections 프록시 URL(계정·리전·커넥션 ID 포함) |
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
bootstrap/argocd-values.yaml # ArgoCD 자신의 helm values. root App include 범위 밖
bootstrap/argocd-app.yaml    # ArgoCD 자기 관리 Application. 위 values를 $values로 읽는다
bootstrap/argocd-seed.sh     # seed 실행 스크립트. 이 저장소가 소유한다(아래 절)
clusters/<env>/<cluster>/    # cluster Secret. 새 클러스터 = 디렉토리 1개(O(1))
projects/                    # AppProject 가드레일 — platform.yaml + <team>.yaml
applicationsets/baseline/    # 전 클러스터 팬아웃 ApplicationSet(environment 라벨). root App이 읽는다
applicationsets/catalog/     # opt-in 카탈로그 ApplicationSet — 구독한 클러스터만(addon-<name> 라벨)
addons/<addon>/              # 위 ApplicationSet의 source가 읽는 내용물. root App은 읽지 않는다
addons/<addon>/values.yaml   #   업스트림 차트 helm values. 티어 쌍이 같은 파일을 읽는다(아래 "helm values" 절)
addons/gateway/shared-gateway/  #   GatewayClass·Gateway·LoadBalancerConfiguration 로컬 helm 차트(per-cluster 값 주입)
addons/karpenter/nodepool/   #   NodePool/EC2NodeClass 로컬 helm 차트(per-cluster 값 주입)
addons/kyverno/custom-policies/ #   이 저장소가 직접 소유하는 ValidatingPolicy 매니페스트
scripts/                     # 주석 규칙 검사기(.py다 — 아래 "게이트" 절)
.githooks/                   # pre-commit 훅
.github/workflows/verify.yml # CI. 훅과 같은 검사 + YAML 파싱·차트 렌더·kyverno test
tests/kyverno/               # 커스텀 정책 픽스처. Application source 경로 밖이라 클러스터에 가지 않는다
```

**확장 규칙(O(1))**: 새 클러스터는 `clusters/<env>/<cluster>/` 1개만 추가하면 cluster generator가
라벨로 자동 팬아웃한다. 새 앱팀은 `projects/<team>.yaml` 가드레일 1개만 추가한다.

---

## 부트스트랩 — 자기소멸(self-superseding) 원칙

최초 1회 workbench에서 seed한 뒤, root App이 그 리소스들을 **자기 소유로 흡수**한다.

```
1. helm install argo-cd          (workbench, 사람)   ← self-managed 고유
2. projects/platform.yaml        (kubectl seed)
3. clusters/.../cluster-secret.yaml (kubectl seed)
4. bootstrap/root-app.yaml       (kubectl seed) → 자기 자신을 흡수
   이후 전부                      GitOps(pull) — argocd chart 자체도 Application으로 흡수
```

관리형 ArgoCD에 있는 두 단계가 여기에는 없다. Access Entry는 ArgoCD가 클러스터 안에 있어
불필요하고(spoke는 필요), repository Secret은 저장소가 public이라 ArgoCD가 익명으로 읽는다.
seed가 GitOps 관리 밖에 남기는 리소스는 없다.

- **손으로 apply하는 매니페스트는 저장소에 커밋된 것과 바이트 단위로 동일해야 한다.** 그래야 root App이 첫 sync에서 흡수해 즉시 no-op이 된다 — 다르면 그 차이가 영구 드리프트로 남는다.
- ⛔ **helm values도 예외 없음**: `helm install -f`에 넘기는 값은 저장소 파일 그대로 써야 하며, `--set`은 쓰지 않는다.
- ⛔ **완료 조건**: 초기 비밀번호 교체 + `argocd-initial-admin-secret` 삭제.

## `bootstrap/argocd-seed.sh` — 이 저장소가 소유한다

고칠 일이 생기면 여기서 고친다. 다른 저장소로 복사하지 않는다.

실행하는 곳이 workbench 하나이고, workbench는 이 저장소만 클론한다. 저장소가 public이라 클론에도
ArgoCD의 읽기에도 자격증명이 없다. 스크립트는 preflight에서 `root-app.yaml`의 `repoURL`을 익명으로
`ls-remote`해 그 전제를 확인한다 — 저장소가 private으로 돌아가면 sync가 조용히 멈추기 때문이다.

⚠️ `aks-platform-gitops`의 같은 이름 파일과 형제가 아니다. 클라우드마다 독립이고, 한쪽을 고쳐도
다른 쪽에 반영하지 않는다.

---

## root App이 읽는 범위 — `include` allow-list

`bootstrap/root-app.yaml`은 `directory.include`에 적힌 경로만 매니페스트로 읽는다. 지금은
`projects/`·`clusters/**/cluster-secret.yaml`·`applicationsets/**`·`bootstrap/`의 두 Application
파일이다. **그 밖은 무엇이든 무시한다** — `addons/` 전체(로컬 차트·CR 매니페스트는 전담
ApplicationSet이, `values.yaml`은 multi-source가 따로 읽는다), `bootstrap/argocd-values.yaml`, 도구
파일 전부.

이 저장소는 `exclude`와 `+argocd:skip-file-rendering` 마커를 쓰지 않는다. 기각 근거는
`iac-module-library`의 `docs/architectures/gitops-hub-spoke/gitops.md` 「하지 않는 것」이 갖는다.

매니페스트 디렉토리를 새로 만들면 `include`에 한 줄 더한다. `applicationsets/` 아래는 하위
디렉토리까지 전부 읽으므로(`**`), 그 안에서 파일이 늘고 주는 것은 `root-app.yaml`과 무관하다. ⚠️ **렌더가 깨지는 파일이 든 경로**를 `include`에
넣으면 그 spec이 적용된 뒤부터 자기 갱신이 멈춘다. root App은 자기 spec을 클러스터에 적용된
옛 spec으로 렌더한 뒤에야 갱신하는데, 그 렌더가 깨지면 갱신에 이르지 못한다. 그 파일을 고치는
커밋이 풀거나, `argocd-seed.sh`의 root Application 단계만 다시 돌려 커밋본 `root-app.yaml`을 손으로 다시 apply한다.

`addons/<addon>/<dir>/`가 helm 차트인지 평문 매니페스트인지는 **per-cluster 값을 주입하는지**로만
정한다. ArgoCD는 ApplicationSet의 fasttemplate을 Application spec에서만 치환하고 git 경로 안의
파일에서는 치환하지 않으므로, cluster generator의 값을 CR에 넣으려면 helm이 필요하다(`shared-gateway`·
`karpenter/nodepool`). 주입할 값이 없으면 평문이다(`kyverno/custom-policies`).

## ApplicationSet 공통 규약

매니페스트마다 반복하지 않고 여기 한 번 적는다. 개별 파일 주석은 그 파일에만 참인 것만 갖는다.

| 항목 | 규약 |
|---|---|
| 팬아웃 | cluster generator가 라벨이 맞는 cluster Secret마다 Application을 1개 만든다. ArgoCD 내장 `in-cluster`에는 Secret도 라벨도 없어 걸리지 않는다 — cluster Secret을 명시적으로 만드는 이유다 |
| `finalizers` | `resources-finalizer.argocd.argoproj.io`를 template에 둔다. 없으면 Application CR을 지워도 그것이 만든 리소스가 클러스터에 orphan으로 남는다 |
| `releaseName` | Application 이름과 분리한다. 없으면 `{{name}}-<addon>`이 리소스 이름에 전파돼 63자 제한에 걸린다 |
| `ref: values` source | `ref`만 있고 `path`/`chart`가 없어 렌더 대상이 아니다. `$values`가 이 저장소 루트를 가리키게 하는 것이 전부다 |

⚠️ **돌고 있는 클러스터가 있을 때 ApplicationSet 이름을 바꾸지 않는다.** 이름이 바뀌면 삭제로
처리되고, 그것이 만든 Application이 `ownerReference`를 따라 지워지면서 finalizer가 **실물까지
prune한다.** 정리할 수 있는 시점은 전면 철거 이후 seed 이전뿐이다.

### staged 전파 — `-prd` · `-nonprd` 두 블록

한 파일 안에 티어별 ApplicationSet 두 개를 둔다. 승격할 때 두 `targetRevision`을 나란히 읽어야
하기 때문이다. 두 값이 다르면 승격이 진행 중이고, 같으면 끝난 것이다. 티어를 나누지 않는
addon(`uniform`)은 블록이 하나다.

⛔ **두 블록을 함께 고친다.** 갈려도 되는 값은 `targetRevision` 하나다. values는 양 블록이 같은
파일을 읽어 갈릴 수 없고, `parameters`·네임스페이스·`syncPolicy`는 갈리면 티어 간 동작이 달라진다.

⚠️ 그 티어의 클러스터가 없으면 대상이 0개가 된다. 사고가 아니라 **빈 슬롯**이고, cluster Secret이
그 `tier`로 등록되는 순간 팬아웃된다. ArgoCD는 대상 0개를 오류로 보고하지 않으므로, 0이 의도인지
사고인지는 등록된 cluster Secret의 `tier` 값을 세어 구분한다.

## helm values — `addons/<addon>/values.yaml`

저장소가 이미 아는 값(tolerations · serviceAccount · replicas)은 `addons/<addon>/values.yaml`에 두고, ApplicationSet이 multi-source의
`$values/addons/<addon>/values.yaml`로 읽는다. 팬아웃 시점에만 정해지는 값(`{{name}}` · cluster
Secret 라벨)은 ApplicationSet의 `helm.parameters`에 남는다 — fasttemplate이 파일 안에서는 동작하지
않기 때문이다.

staged addon(ALBC · Karpenter · Kyverno)은 prd·nonprd 두 ApplicationSet이 **같은 파일**을 읽는다.
승격 때 갈리는 값은 `targetRevision` 하나이고, values는 갈릴 수 없다. values 파일 안의 주석은
렌더 결과에도 Application spec에도 들어가지 않으므로 고쳐도 `OutOfSync`가 나지 않는다.

⚠️ values 파일을 `applicationsets/` 안에 두지 않는다. root App의 `include`가 그 디렉토리를
`**/*.yaml`로 읽으므로, 안에 두면 매니페스트로 읽혀 root App의 렌더가 깨진다. ApplicationSet 안 `helm.values: |` 인라인을 쓰지 않는 근거는 `iac-module-library`의
`docs/architectures/gitops-hub-spoke/gitops.md` 「하지 않는 것」이 갖는다.

---

## 게이트 — 로컬 훅과 CI

이 저장소는 push가 곧 apply다. ArgoCD가 `main`을 pull로 reconcile하므로, 깨진 매니페스트를
막는 자리는 **머지 전**뿐이다. 두 층이 있다. 커밋 전 훅(clone마다 한 번 켠다)과, 같은 검사에
오프라인 렌더·정책 판정을 더해 PR·main push에서 도는 `.github/workflows/verify.yml`이다.

```bash
git config core.hooksPath .githooks
brew install shellcheck gitleaks   # 셸·시크릿 게이트가 요구한다. 없으면 훅이 즉시 실패한다
```

`.githooks/pre-commit`이 staged 파일 중 `applicationsets/`·`addons/`·`projects/`·`clusters/`·`bootstrap/`·`tests/`의
`.yaml`/`.sh`, 저장소 `.md`, `scripts/*.py`, `.githooks/*`를 골라
`scripts/validate-comment-conventions.py`에 넘긴다. 검사기는 주석에 **외부 참조**(문서 절
번호·결정 식별자)와 **이력 서술**(날짜·세션 번호, 그리고 측정을 사건으로 적은 서술)이 있는지만
본다 — 외부 참조는 가리키는 쪽이 움직이면 조용히 틀려지고, 이력 서술은 언제 누가 왜 바꿨는지를
`git blame`과 커밋 메시지가 이미 답한다. 규칙 자체의 SSOT는 `iac-module-library`의
`docs/conventions.md`와 `docs/writing-style.md`이고, 검사기는 규칙 텍스트를 다시 쓰지 않는다.
정확한 패턴 목록은 검사기 자신이 갖는다.

전체를 한 번에 돌리려면 저장소 루트에서:

```bash
python3 scripts/validate-comment-conventions.py
```

staged된 `.sh`에는 `bash -n`(문법)과 `shellcheck -x`(인용·확장·종료코드)가 함께 돈다.
`bootstrap/argocd-seed.sh`는 workbench에서 사람이 손으로 돌리는 스크립트라, 깨진 채 머지되면
부트스트랩 한가운데서 드러난다.

`verify.yml`은 훅과 같은 검사(주석 규칙·`bash -n`·`shellcheck -x`, 버전을 로컬과 같게 핀)에
세 가지를 더한다. **YAML 전체 파싱**(차트 `templates/`는 Go 템플릿이라 제외), **로컬 차트
`helm lint`·`helm template`**(`required` 값은 ApplicationSet이 cluster Secret 라벨에서 주입하는
것이라 대표값을 `--set`으로 준다. 렌더일 뿐 seed가 아니다), **`kyverno test`**(`tests/kyverno/`의
픽스처로 커스텀 정책의 통과·거부·제외를 판정한다. CLI 버전은 kyverno 차트의 appVersion과 같아야
한다). 픽스처는 어떤 Application의 source 경로에도 들어가지 않는 `tests/`에 둔다 — `addons/`
아래 두면 Directory 타입 Application이 파드 픽스처를 클러스터에 적용한다.

⛔ ArgoCD의 렌더(Application 조립·파라미터 주입·`include` 판정)는 흉내 내지 않는다. 그것은
클러스터에서 ArgoCD가 판정하고, seed 뒤 `argocd app diff`가 그 자리다. CI가 보는 것은 차트와
정책 파일 자체다.

의도적 우회는 `git commit --no-verify`이고, 사유를 커밋 메시지에 남긴다. CI는 우회하지 않는다.

`aks-platform-gitops`가 같은 게이트를 같은 내용으로 갖는다. 한쪽을 고치면 다른 쪽도 함께
고친다 — 드리프트를 검사하는 장치는 없다.

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

### cluster Secret 라벨 계약

ApplicationSet이 읽는 라벨이다. 빠지면 그 addon만 조용히 안 뜬다.

| 라벨 | 읽는 쪽 | 값 |
|---|---|---|
| `environment` | baseline 팬아웃 전체 | `hub` · `dev` 등. 존재 자체가 매칭 조건이다 |
| `tier` | staged addon의 `-prd`/`-nonprd` 선택 · NodePool 차트의 AMI 핀 선택 | `prd` \| `nonprd` |
| `vpcName` | ALBC의 `vpcTags.Name` | VPC의 Name 태그 |
| `karpenterNodeRole` | NodePool 차트의 EC2NodeClass | 노드 IAM role 이름. 26자 hash 접미가 붙어 **재구축마다 바뀐다** |
| `addon-<name>: enabled` | catalog addon 구독 | `addon-keda` · `addon-cluster-autoscaler` |
| `decommission` | `gateway` · `karpenter-nodepool` (`DoesNotExist`) | 등록 해제 1단계에서만 붙인다. 존재하면 두 ApplicationSet이 그 클러스터를 놓는다. 값은 읽지 않는다 |

⚠️ **teardown은 `decommission`을 붙여 CR을 먼저 prune하고, 그다음 매칭 라벨을 뗀 뒤 Secret을
지운다.** 매칭 라벨을 한 번에 떼면 ALBC·Karpenter가 자기 CR보다 먼저 사라져 finalizer가 멈추고 SG가
고아로 남는다. 설계 근거는 `iac-module-library`의 `docs/architectures/gitops-hub-spoke/aws/`가 갖는다.
git 이력의 마지막 cluster-secret을 그대로 되살리면 라벨이 빠진 껍데기이고, 그 상태로는 Application이
하나도 생기지 않는다.

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

⚠️ **`cluster-autoscaler`는 이 표의 기준을 충족하지 못한 채로 예외에 들어갔다.** 공식 문서 근거도
APF 같은 기술적 강제도 없다.

- 순서: Terraform 쪽 Pod Identity association을 `kube-system/cluster-autoscaler`로 **먼저** 고정
  (관례로 고른 값이고 공식 근거는 없다) → 이 매니페스트가 거기 맞춤.
- 즉 위 근거 3(집행 장치)과 인과가 반대다 — association이 원인이 아니라 결과다.
- 그래서 근거 3과 같은 층으로 세지 않고 **약한 예외**로 남겨 둔다. 새 예외를 추가할 때 이
  항목을 전례로 들지 않는다.

전용 ns addon을 추가할 때는 `syncPolicy.syncOptions`에 `CreateNamespace=true`를 넣는다. 자동 생성된
Namespace는 AppProject `clusterResourceWhitelist`의 검사 대상이므로 `{group: "", kind: Namespace}`를
열어야 한다. `managedNamespaceMetadata`는 쓰지 않는다 — 켜면 그 ns가 ArgoCD 추적 대상이 되어
`prune: true`와 겹칠 때 addon 제거가 네임스페이스째 지운다.

---

## 현재 배포된 addon

**baseline vs catalog 판단 기준**: **워크로드 아키텍처와 무관하게 플랫폼이 보편적으로 요구하는가**.
Terraform 쪽 `enable_*` 기본값은 기준이 아니다 — `aws-load-balancer-controller`는 Terraform
기본값이 `false`인데도 baseline이다.

- **baseline**(ALBC·Karpenter·Kyverno·Gateway API): 전 클러스터에 배포.
- **catalog**(KEDA·cluster-autoscaler): 특정 아키텍처를 선택한 클러스터만 `addon-<name>: enabled`
  라벨로 구독.

| addon | chart | 버전 | namespace | 배포 방식 |
|---|---|---|---|---|
| `argocd`(자기 관리) | `argoproj.github.io/argo-helm` / `argo-cd` | 10.9.1 | `argocd` | seed 흡수, `automated.selfHeal: true` · `prune: false` |
| `aws-load-balancer-controller` | `aws.github.io/eks-charts` | 3.5.0 | `kube-system` | baseline(전 클러스터, `environment` 라벨 존재 시 매칭) |
| `karpenter` | `public.ecr.aws/karpenter`(OCI) | 1.14.1 | `kube-system` | baseline |
| `karpenter` NodePool/EC2NodeClass | 로컬 차트(`addons/karpenter/nodepool/`) | — | `kube-system` | baseline |
| `kyverno` + `kyverno-policies` | `kyverno.github.io/kyverno` | 3.9.1 | `kyverno` | baseline, `CreateNamespace=true` |
| Gateway API 표준 CRD | git repo(디렉토리) `kubernetes-sigs/gateway-api` | v1.6.2 | `kube-system`(형식상 값) | baseline. AWS 전용 Gateway CRD는 별도 addon 없이 `aws-load-balancer-controller` chart의 `crds/` 폴더가 이미 설치한다 |
| `gateway`(GatewayClass·LoadBalancerConfiguration·Gateway) | 로컬 차트(`addons/gateway/shared-gateway/`) | — | `gateway-system` | baseline, `CreateNamespace=true`. HTTPRoute·백엔드는 앱팀 저장소 소관(범위 밖) |
| `keda` | `kedacore.github.io/charts` | 2.20.2 | `keda` | opt-in 카탈로그(cluster Secret 라벨 `addon-keda: enabled`) |
| `cluster-autoscaler` | `kubernetes.github.io/autoscaler` | 9.59.0 | `kube-system` | opt-in 카탈로그(cluster Secret 라벨 `addon-cluster-autoscaler: enabled`) — dev 구독 중(taint 분리 검증 완료) |

### 운영 노트

- **Kyverno Audit 모드**: `validationActions: [Audit]`, `failurePolicy: Ignore`로 운영 — 웹훅에
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
  `compare-options: ServerSideDiff=true`도 쓴다 — CRD·ValidatingPolicy의 일부 필드가 apiserver
  기본값으로 채워져 영구 `OutOfSync`가 되는 것을 막는다. `IncludeMutationWebhook=true`는 켜지 않는다
  — 웹훅 변형까지 diff에 들어와 새 drift를 만든다.
- **Gateway API를 이미 떠 있는 클러스터에 추가할 때**: ALBC는 Gateway API CRD 존재 여부를 파드
  시작 시점에만 감지하고 캐싱한다 — `gateway-api-crds.yaml`을 ALBC가 이미 오래 떠 있는 클러스터에
  나중에 추가하면, ALBC 로그에 `Disabling ALBGatewayAPI: missing required CRDs`가 남아있는 채로
  CRD가 생겨도 재감지하지 않는다(GatewayClass가 `Accepted: Unknown`인 채로 조용히 멈춘다 — 에러가
  아니다). `kubectl -n kube-system rollout restart deploy/aws-lbc-aws-load-balancer-controller`로
  재시작하면 즉시 감지·활성화된다. 신규 클러스터를 처음부터 seed할 때도 ALBC 파드와 CRD 생성이
  같은 sync 안에서 병렬이라, 파드가 몇 초 먼저 뜨면 같은 증상이 난다(그때는 `gateway-api-crds`와
  `gateway`가 `Degraded`·`Progressing`에 머문다). 로그에 `Disabling ALBGatewayAPI`가 있으면 재시작한다.
- **seed 직후 잠시 남는 비정상 상태**: 아래 둘은 재시작이 아니라 기다림이나 refresh로 푼다.
  - `kyverno-policies`·`kyverno-custom-policies`가 `Unknown`이고 조건이 `service ...-kyverno-svc not
    found`인 것은 Kyverno Service가 생기기 전에 캐시된 비교 오류다. Kyverno가 `Synced`가 된 뒤에도
    남으면 그 Application에 `argocd.argoproj.io/refresh=hard` 어노테이션을 건다.
  - `kyverno`의 sync가 `mservice.elbv2.k8s.aws` 웹훅의 `x509: certificate signed by unknown
    authority`로 재시도 중이면, ALBC 차트가 렌더마다 TLS를 새로 만들어 웹훅 CA와 파드 인증서가
    잠깐 어긋난 것이다. ALBC를 재시작하면 풀린다.

---

## 라이선스

[MIT](LICENSE).
