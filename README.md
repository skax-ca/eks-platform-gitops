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
- [부모 Application — 클러스터마다 하나](#부모-application--클러스터마다-하나)
  - [버전 표 — `addons/platform/values.yaml`](#버전-표--addonsplatformvaluesyaml)
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
applicationsets/platform.yaml # 클러스터마다 부모 Application을 만드는 ApplicationSet. root App이 읽는다
addons/platform/             # 부모 차트. 그 클러스터의 addon Application 전부와 wave·버전 표. root App은 읽지 않는다
addons/<addon>/              # addon Application의 source가 읽는 내용물. root App은 읽지 않는다
addons/<addon>/values.yaml   #   업스트림 차트 helm values. 티어 쌍이 같은 파일을 읽는다(아래 "helm values" 절)
addons/gateway/shared-gateway/  #   GatewayClass·Gateway·LoadBalancerConfiguration 로컬 helm 차트(per-cluster 값 주입)
addons/karpenter/nodepool/   #   NodePool/EC2NodeClass 로컬 helm 차트(per-cluster 값 주입)
addons/kyverno/custom-policies/ #   이 저장소가 직접 소유하는 ValidatingPolicy 매니페스트
scripts/                     # 주석 규칙 검사기(.py다 — 아래 "게이트" 절)
scripts/include-check/       # root App include 판정(Go, 별도 모듈). CI 전용
.githooks/                   # pre-commit 훅
.github/workflows/verify.yml # CI. 훅과 같은 검사 + YAML 파싱·include 판정·차트 렌더·kyverno test
tests/kyverno/               # 커스텀 정책 픽스처. Application source 경로 밖이라 클러스터에 가지 않는다
```

**확장 규칙(O(1))**: 새 클러스터는 `clusters/<env>/<cluster>/` 1개만 추가하면 그 클러스터의 부모가
생기고, 부모가 라벨대로 addon을 렌더한다. 새 앱팀은 `projects/<team>.yaml` 가드레일 1개만 추가한다.

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
`projects/`·`clusters/**/cluster-secret.yaml`·`applicationsets/*.yaml`·`bootstrap/`의 두 Application
파일이다. **그 밖은 무엇이든 무시한다** — `addons/` 전체(부모 차트는 부모가, 로컬 차트·CR 매니페스트는
addon Application이, `values.yaml`은 multi-source가 따로 읽는다), `bootstrap/argocd-values.yaml`, 도구
파일 전부.

이 저장소는 `exclude`와 `+argocd:skip-file-rendering` 마커를 쓰지 않는다. 기각 근거는
`iac-module-library`의 `docs/architectures/gitops-hub-spoke/gitops.md` 「하지 않는 것」이 갖는다.

매니페스트 디렉토리를 새로 만들면 `include`에 한 줄 더한다. `applicationsets/`는 바로 아래 파일만
읽는다. ⚠️ `x/**/*.yaml`은 `x` 바로 아래 파일을 잡지 않는다 — `**` 뒤의 `/` 때문에 사이에 디렉토리가
하나 이상 있어야 매치되고, 빠진 파일은 오류 없이 무시되어 root App이 `Synced`로 남는다. ⚠️ **렌더가 깨지는 파일이 든 경로**를 `include`에
넣으면 그 spec이 적용된 뒤부터 자기 갱신이 멈춘다. root App은 자기 spec을 클러스터에 적용된
옛 spec으로 렌더한 뒤에야 갱신하는데, 그 렌더가 깨지면 갱신에 이르지 못한다. 그 파일을 고치는
커밋이 풀거나, `argocd-seed.sh`의 root Application 단계만 다시 돌려 커밋본 `root-app.yaml`을 손으로 다시 apply한다.

`addons/<addon>/<dir>/`가 helm 차트인지 평문 매니페스트인지는 **per-cluster 값을 주입하는지**로만
정한다. 부모 차트는 addon Application spec에 값을 적을 수 있지만 평문 디렉토리 source는 파일 안의
값을 치환하지 않으므로, 클러스터별 값을 CR에 넣으려면 helm이 필요하다(`shared-gateway`·
`karpenter/nodepool`). 주입할 값이 없으면 평문이다(`kyverno/custom-policies`).

## 부모 Application — 클러스터마다 하나

`applicationsets/platform.yaml`이 cluster Secret마다 부모 `<cluster>-platform`을 만들고, 부모가
`addons/platform/` 차트로 그 클러스터의 addon Application을 렌더한다. 부모를 두는 이유는 순서다.
부모가 addon Application을 자기 리소스로 sync해야 sync-wave가 설치 순서(앞 wave가 Healthy가 된 뒤
다음 wave)와 해제 순서(wave 역순, 삭제 완료 대기)가 된다. 설계 근거는 `iac-module-library`의
`docs/architectures/gitops-hub-spoke/ordering.md`가 갖는다.

| wave | addon | 기대는 것 |
|:---:|---|---|
| 0 | `gateway-api-crds` | 없다 |
| 1 | `aws-lbc` · `karpenter` · `kyverno` · `keda` · `cluster-autoscaler` | CRD. ALBC는 파드가 시작할 때 Gateway API CRD를 한 번만 감지한다 |
| 2 | `gateway` · `karpenter-nodepool` · `kyverno-policies` · `kyverno-custom-policies` | 자기 CRD와 finalizer를 처리하는 컨트롤러 |

매니페스트마다 반복하지 않고 여기 한 번 적는다. 개별 템플릿 주석은 그 파일에만 참인 것만 갖는다.

| 항목 | 규약 |
|---|---|
| wave | addon Application의 `argocd.argoproj.io/sync-wave`. 기대는 addon보다 크게 둔다. 대기는 `bootstrap/argocd-values.yaml`의 Application health Lua가 있어야 선다. 없으면 wave가 생성 순서만 정한다 |
| 식별 라벨 | addon Application에 `platform.addon`·`platform.cluster`·`platform.wave`, 부모에 `platform.cluster`. 이름의 `<cluster>-` 접두사가 콘솔에서 잘려 addon이 가려지므로 식별은 라벨로 한다(`kubectl -n argocd get applications -l platform.cluster=<cluster> -L platform.addon,platform.wave`, `argocd app list -l platform.addon=<addon>`). 라벨과 sync-wave 어노테이션은 `_helpers.tpl`의 `platform.meta` 하나가 찍는다. 트리 노드 태그는 `bootstrap/argocd-values.yaml`의 `resource.customLabels`가 띄운다 |
| `finalizers` | 부모와 addon Application 모두 `resources-finalizer.argocd.argoproj.io`를 둔다. 부모의 것이 해제 때 addon을 wave 역순으로 지우고, addon의 것이 클러스터 실물을 지운다 |
| `releaseName` | Application 이름과 분리한다. 없으면 `<cluster>-<addon>`이 리소스 이름에 전파돼 63자 제한에 걸린다 |
| `ref: values` source | `ref`만 있고 `path`/`chart`가 없어 렌더 대상이 아니다. `$values`가 이 저장소 루트를 가리키게 하는 것이 전부다 |
| 부모 `prune: true` | opt-in 해지(라벨 제거)가 부모의 prune으로 이루어진다. ⚠️ 그래서 `addons/platform/templates/`에서 파일을 지우면 등록된 전 클러스터에서 그 addon이 지워진다 |

⚠️ **돌고 있는 클러스터가 있을 때 ApplicationSet `platform`의 이름·selector나 addon 템플릿의
`metadata.name`을 바꾸지 않는다.** 이름이 바뀌면 삭제로 처리되고, finalizer가 **실물까지 prune한다.**
정리할 수 있는 시점은 전면 철거 이후 seed 이전뿐이다.

⚠️ **부모가 앞 wave를 기다리며 멈췄을 때**: 앞 wave의 addon이 Healthy가 되지 못하면 부모의 sync
operation이 끝나지 않고, 그동안 버전 표를 고친 커밋이 addon Application에 반영되지 않는다. ArgoCD의
sync 타임아웃 기본값이 무제한이라 스스로 풀리지 않는다. `argocd app terminate-op <cluster>-platform`으로
끊으면 다음 auto-sync가 새 커밋으로 돈다. `addons/<addon>/values.yaml`만 고친 커밋은 addon
Application이 직접 읽으므로 부모를 거치지 않는다.

### 버전 표 — `addons/platform/values.yaml`

승인된 버전은 이 표에만 있다. 템플릿은 `tier`로 줄을 고를 뿐 버전을 적지 않는다.

- **staged**(ALBC · Karpenter · Kyverno 엔진·정책 · Gateway API CRD): `versions.<addon>`에 `prd`·`nonprd`
  두 줄을 나란히 둔다. 두 값이 다르면 승격이 진행 중이고, 같으면 끝난 것이다. `nonprd`를 먼저 올려
  비운영 클러스터에서 확인하고 `prd`를 같은 값으로 올린다.
- **opt-in**(KEDA · cluster-autoscaler): 한 줄이다. 구독한 클러스터가 함께 올라간다.
- **uniform**(이 저장소의 로컬 차트·정책): 표에 없다. `main`을 따라간다.

⚠️ `tier`가 `prd`·`nonprd`가 아니면 부모 차트가 `required`로 렌더를 실패시켜 그 클러스터의 부모가
`ComparisonError`로 멈춘다. `environment` 라벨이 없으면 부모 자체가 생기지 않고, ArgoCD는 대상
0개인 팬아웃을 오류로 보고하지 않는다.

## helm values — `addons/<addon>/values.yaml`

저장소가 이미 아는 값(tolerations · serviceAccount · replicas)은 `addons/<addon>/values.yaml`에 두고,
addon Application이 multi-source의 `$values/addons/<addon>/values.yaml`로 읽는다. 클러스터마다
갈리는 값(클러스터 이름 · cluster Secret 라벨)은 부모 차트가 addon Application의 `helm.parameters`에
적는다 — values 파일은 전 클러스터가 같은 파일을 읽기 때문이다.

staged addon은 양 티어가 **같은 파일**을 읽는다. 승격 때 갈리는 값은 버전 표의 한 줄이고, values는
갈릴 수 없다. values 파일 안의 주석은
렌더 결과에도 Application spec에도 들어가지 않으므로 고쳐도 `OutOfSync`가 나지 않는다.

⚠️ values 파일을 `applicationsets/` 안에 두지 않는다. root App의 `include`가 그 디렉토리를
`**/*.yaml`로 읽으므로, 안에 두면 매니페스트로 읽혀 root App의 렌더가 깨진다. addon Application 안 `helm.values: |` 인라인을 쓰지 않는 근거는 `iac-module-library`의
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
네 가지를 더한다. **YAML 전체 파싱**(차트 `templates/`는 Go 템플릿이라 제외), **root App
`include` 판정**(아래), **로컬 차트
`helm lint`·`helm template`**(`required` 값은 부모 차트가 cluster Secret 라벨에서 주입하는 것이라
대표값을 `--set`으로 준다. 렌더일 뿐 seed가 아니다. 부모 차트는 두 티어 × opt-in 구독 유무를 모두
렌더하고, 없는 `tier`가 렌더 실패가 되는지 본다), **`kyverno test`**(`tests/kyverno/`의
픽스처로 커스텀 정책의 통과·거부·제외를 판정한다. CLI 버전은 kyverno 차트의 appVersion과 같아야
한다). 픽스처는 어떤 Application의 source 경로에도 들어가지 않는 `tests/`에 둔다 — `addons/`
아래 두면 Directory 타입 Application이 파드 픽스처를 클러스터에 적용한다.

⛔ ArgoCD의 렌더(Application 조립·파라미터 주입)는 흉내 내지 않는다. 그것은 클러스터에서
ArgoCD가 판정하고, seed 뒤 `argocd app diff`가 그 자리다. CI가 보는 것은 차트와 정책 파일
자체다.

`include` 판정은 예외다. 흉내 내는 것이 아니라 **ArgoCD와 같은 매처를 같은 방식으로 부른다**:
repo-server가 쓰는 `gobwas/glob`(ArgoCD `go.mod`와 같은 버전)을 구분자 없이 컴파일해 저장소 루트
기준 상대 경로에 댄다. 이 자리를 CI로 끌어온 이유는 두 가지다. `include`가 파일을 놓치면 root App은
오류 없이 `Synced`로 남아 클러스터에서도 드러나지 않고, 클러스터가 없는 동안에는 `argocd app diff`를
돌릴 곳이 없다. `scripts/include-check`가 두 가지를 본다. `{a,b,…}` 대안 하나하나가 파일을 1개
이상 잡는지, 그리고 대안이 가리키는 최상위 디렉토리 안에서 매니페스트로 보이는 파일(ArgoCD와 같은
기준: 확장자와 `apiVersion:`·`kind:`·`metadata:`)이 `include` 밖에 남지 않았는지다. ⚠️ 셸 glob과
의미가 다르다. 구분자가 없어 `*`도 `/`를 넘고(`projects/*.yaml`이 `projects/a/b.yaml`을 잡는다),
`x/**/*.yaml`은 `x` 바로 아래 파일을 잡지 않는다. 로컬에서는 저장소 루트에서
`go run -C scripts/include-check .`이다.

의도적 우회는 `git commit --no-verify`이고, 사유를 커밋 메시지에 남긴다. CI는 우회하지 않는다.

`aks-platform-gitops`가 같은 게이트를 같은 내용으로 갖는다. 한쪽을 고치면 다른 쪽도 함께
고친다 — 드리프트를 검사하는 장치는 없다.

## 알아야 할 규약

- ⛔ **`default` AppProject를 쓰지 않는다** — `sourceRepos`/`destinations`/`clusterResourceWhitelist`가
  전부 `'*'`인 완전 개방 상태다. 플랫폼 리소스는 전용 `platform` 프로젝트에 둔다.
- 🔑 **cluster Secret의 이름은 실제 EKS 클러스터명이어야 한다** — 부모 차트를 거쳐 ALBC의 필수
  파라미터 `clusterName`으로 그대로 흘러간다. 별칭을 쓰면 조용히 틀린다.
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

ApplicationSet `platform`이 부모 차트에 넘기는 라벨이다.

| 라벨 | 읽는 쪽 | 값 | 빠지면 |
|---|---|---|---|
| `environment` | 부모 생성(존재) · `gateway` 차트의 ALB 이름·태그(값) | `hub` · `dev` 등 | 부모가 생기지 않는다. 오류가 보고되지 않는다 |
| `tier` | 버전 표의 줄 선택 · NodePool 차트의 AMI 핀 선택 | `prd` \| `nonprd` | 부모 렌더가 `required`로 실패한다 |
| `vpcName` | ALBC의 `vpcTags.Name` | VPC의 Name 태그 | 부모 렌더가 `required`로 실패한다 |
| `karpenterNodeRole` | NodePool 차트의 EC2NodeClass | 노드 IAM role 이름(`iamr-<workload>-<env>-<region>-karpenter-node`). `eks-cluster` 모듈이 접두 모드를 끄고 고정 이름으로 만들어 재구축해도 같다 | 부모 렌더가 `required`로 실패한다 |
| `addon-<name>: enabled` | opt-in addon 구독 | `addon-keda` · `addon-cluster-autoscaler` | 그 addon만 빠진다. 오류가 보고되지 않는다 |

⚠️ **teardown은 `environment` 라벨을 먼저 떼고, 부모가 hub에서 사라진 뒤 Secret을 지운다.** 라벨을
떼면 부모가 지워지면서 addon을 wave 역순(CR → 컨트롤러 → CRD)으로 지운다. Secret을 먼저 지우면
ArgoCD가 목적지를 잃어 spoke 리소스를 지우지 않고 기록만 버린다 — CR의 finalizer와 ALB SG가 남는다.
명령 순서는 `eks-reference-infra`의 `spoke-lifecycle.md`가 갖는다. git 이력의 마지막 cluster-secret을
그대로 되살리면 라벨이 빠진 껍데기이고, 그 상태로는 부모가 생기지 않는다.

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
- **opt-in**(KEDA·cluster-autoscaler): 특정 아키텍처를 선택한 클러스터만 `addon-<name>: enabled`
  라벨로 구독.

| addon | chart | 버전 | namespace | wave | 배포 방식 |
|---|---|---|---|:---:|---|
| `argocd`(자기 관리) | `argoproj.github.io/argo-helm` / `argo-cd` | 10.9.1 | `argocd` | — | seed 흡수, `automated.selfHeal: true` · `prune: false`. 부모 밖이다 |
| Gateway API 표준 CRD | git repo(디렉토리) `kubernetes-sigs/gateway-api` | v1.6.2 | `kube-system`(형식상 값) | 0 | baseline. AWS 전용 Gateway CRD는 별도 addon 없이 `aws-load-balancer-controller` chart의 `crds/` 폴더가 이미 설치한다 |
| `aws-load-balancer-controller` | `aws.github.io/eks-charts` | 3.5.0 | `kube-system` | 1 | baseline |
| `karpenter` | `public.ecr.aws/karpenter`(OCI) | 1.14.1 | `kube-system` | 1 | baseline |
| `kyverno` | `kyverno.github.io/kyverno` | 3.9.1 | `kyverno` | 1 | baseline, `CreateNamespace=true` |
| `keda` | `kedacore.github.io/charts` | 2.20.2 | `keda` | 1 | opt-in(cluster Secret 라벨 `addon-keda: enabled`) |
| `cluster-autoscaler` | `kubernetes.github.io/autoscaler` | 9.59.0 | `kube-system` | 1 | opt-in(cluster Secret 라벨 `addon-cluster-autoscaler: enabled`) — dev 구독 중(taint 분리 검증 완료) |
| `karpenter` NodePool/EC2NodeClass | 로컬 차트(`addons/karpenter/nodepool/`) | — | `kube-system` | 2 | baseline |
| `gateway`(GatewayClass·LoadBalancerConfiguration·Gateway) | 로컬 차트(`addons/gateway/shared-gateway/`) | — | `gateway-system` | 2 | baseline, `CreateNamespace=true`. HTTPRoute·백엔드는 앱팀 저장소 소관(범위 밖) |
| `kyverno-policies` · 커스텀 정책 | `kyverno.github.io/kyverno` · `addons/kyverno/custom-policies/` | 3.9.1 · — | `kyverno` | 2 | baseline |

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
- **ALBC의 Gateway API CRD 감지**: ALBC는 CRD 존재 여부를 파드 시작 시점에만 감지한다. 없으면
  로그에 `Disabling ALBGatewayAPI: missing required CRDs`를 남기고 재감지하지 않는다(GatewayClass가
  `Accepted: Unknown`인 채로 조용히 멈춘다 — 에러가 아니다). 부모가 CRD(wave 0)가 Healthy가 된 뒤에
  ALBC(wave 1)를 만들므로 seed와 spoke 등록에서는 이 상태를 거치지 않는다. 그래도 이 로그가 보이면
  (health Lua 누락 등으로 wave 대기가 서지 않은 경우)
  `kubectl -n kube-system rollout restart deploy/aws-lbc-aws-load-balancer-controller`로 재시작한다.
- **ALBC 웹훅의 `x509` 재시도**: `kyverno`의 sync가 `mservice.elbv2.k8s.aws` 웹훅의 `x509: certificate
  signed by unknown authority`로 재시도 중이면, ALBC 차트가 렌더마다 TLS를 새로 만들어 웹훅 CA와 파드
  인증서가 잠깐 어긋난 것이다. ALBC를 재시작하면 풀린다. ⚠️ ALBC와 kyverno는 같은 wave 1이라 wave가
  이 경합을 막지 않는다.

---

## 라이선스

[MIT](LICENSE).
