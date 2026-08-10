# iac-platform-gitops

**플랫폼 GitOps monorepo (계층 2)** — ArgoCD 가 pull 로 reconcile 하는 플랫폼 소관 매니페스트 저장소.

⚠️ **설계 SSOT 는 이 저장소가 아니다.** 규약을 바꾸려면 아래 문서를 먼저 고친다.

| 문서 | 내용 |
|---|---|
| [`docs/design/30-gitops-repo.md`](https://github.com/skax-ca/iac-module-library/blob/main/docs/design/30-gitops-repo.md) | **이 저장소의 구조·규약** — 레이아웃·등록·팬아웃·테넌시·부트스트랩 |
| [`docs/design/23-argocd-self-managed.md`](https://github.com/skax-ca/iac-module-library/blob/main/docs/design/23-argocd-self-managed.md) | **현재 경로** — self-managed ArgoCD 설치·인증·도달성 |
| [`docs/design/21-gitops-bootstrap-seam.md`](https://github.com/skax-ca/iac-module-library/blob/main/docs/design/21-gitops-bootstrap-seam.md) | 경로 선택(D-GITOPS-SEAM)과 **갈림점 6개** |
| [`docs/design/40-workbench.md`](https://github.com/skax-ca/iac-module-library/blob/main/docs/design/40-workbench.md) | seed 수행 지점(workbench), ArgoCD 도달 절차 |

> ⚠️ **`30` 은 부분 개정 문서다.** **인용할 때 절 번호까지 확인**한다.
> 2026-08-10 2차 개정으로 addon 증분이 딛는 절이 열렸다 — **§2.9**(팬아웃 경로 판정 + egress·핀 실측) ·
> **§3.1**(AppProject 경로별 값 + 선결 과제 재판정) · **§5**(인용 제한 해제).
> ⛔ 어느 절이 확정인지는 여기 적지 않는다 — **[모듈 repo 의 `docs/README.md` 상태표](https://github.com/skax-ca/iac-module-library/blob/main/docs/README.md)**
> 와 문서 상단 상태 상자가 소유한다(사본을 두면 stale 해진다).

---

## 현재 경로: **self-managed ArgoCD** (helm)

[D-GITOPS-SEAM](https://github.com/skax-ca/iac-module-library/blob/main/docs/design/21-gitops-bootstrap-seam.md)
은 프로파일 A 의 **기본을 관리형 EKS Capability** 로 두고, 탈출 조건에 걸리면 self-managed 로 내려간다.
**이 배포는 self-managed 를 먼저 구현한다.**

⭐ **그래서 이 저장소의 매니페스트 대부분은 경로가 바뀌어도 그대로다.** 갈리는 것은 아래 셋뿐이다.

| 갈림점 | 지금(self-managed) | 관리형으로 바꾸면 |
|---|---|---|
| cluster Secret `server` | `https://kubernetes.default.svc` | **EKS 클러스터 ARN** |
| `repoURL` | `https://github.com/...` + **GitHub App** | **CodeConnections 프록시 URL**(계정·리전·커넥션 ID 포함) |
| AppProject `destinations.server` | `https://kubernetes.default.svc` | **EKS 클러스터 ARN** |

Application / ApplicationSet / AppProject 자체는 **양쪽이 동일**하다 —
*"Applications and ApplicationSets work identically to upstream Argo CD with no changes to your manifests."*

---

## 이 저장소가 다루는 것 / 다루지 않는 것

3계층 소유 모델(`30 §0`)에서 **계층 2만** 담당한다.

| 계층 | 무엇 | 어디 |
|---|---|---|
| 1. Terraform (Day 0/1) | 클러스터·baseline addon·IAM·Access Entry | `skax-ca/iac-reference-infra` |
| **2. 플랫폼 GitOps** | **helm addon · 클러스터 등록 · AppProject 가드레일** | **이 저장소** |
| 3. 앱 GitOps | 비즈니스 워크로드 | 앱팀별 repo (범위 밖) |

⛔ **`apps/` 디렉토리는 의도적으로 없다.** 플랫폼 addon 업그레이드는 fleet 전체에, 앱 배포는 한 팀에
영향을 준다 — 같은 저장소에 두면 리뷰어·릴리스 주기·blast radius 가 섞인다.

## 레이아웃

```
bootstrap/root-app.yaml      # App-of-Apps root — seed 대상. 이후 자기 자신을 흡수
bootstrap/argocd-values.yaml # ArgoCD 자신의 helm values (23 §2.1). root App 훑기에서 제외됨
bootstrap/argocd-seed.sh     # ⬅ VENDORED — seed 실행 스크립트. SSOT 는 모듈 repo (아래 절)
clusters/<env>/<cluster>/    # cluster Secret + per-cluster values. 새 클러스터 = 디렉토리 1개 (O(1))
projects/                    # AppProject 가드레일 — platform.yaml + <team>.yaml
addons/baseline/             # ①baseline helm addon ApplicationSet — cluster generator 로 팬아웃
addons/karpenter/nodepool/   # NodePool/EC2NodeClass 로컬 helm 차트. root App 훑기에서 제외됨
```

> ### ⚠️ **`addons/karpenter/nodepool/` 이 helm 차트인 이유 — 추상화가 아니라 제약이다**
>
> ApplicationSet 의 fasttemplate(`{{name}}`)은 **Application spec 에만** 적용되고 git 경로 안의
> 파일에는 적용되지 않는다. per-cluster 값(clusterName·nodeRole)을 CR 에 넣을 다른 수단이 없어
> 차트가 됐다 — 템플릿 2개짜리 최소 차트다.
> ⇒ root App 이 이 파일들을 매니페스트로 오인하면 `{{ }}` 가 그대로 apply 돼 sync 가 깨진다.
> **아래 D-ROOTAPP-SKIP 이 그 처리를 소유한다.**
> ✅ 반대로 **`addons/baseline/*.yaml` 은 제외하지 않는다** — 그건 진짜 매니페스트(ApplicationSet)이고
> root App 이 흡수해야 App-of-Apps 가 성립한다. 🔑 **둘의 차이가 판단의 기준이다.**

> ## 🔴 **D-ROOTAPP-SKIP — root App 훑기에서 파일을 빼는 방법** (2026-08-10, 실패에서 배움)
>
> **`exclude` 를 늘리지 않는다. 파일 안에 `+argocd:skip-file-rendering` 마커를 넣는다.**
>
> ### 왜 — `exclude` 확장은 **자기소멸 데드락**을 만든다 (실제로 만들었다)
>
> 증분 ①(PR #1)을 머지하자 root App 이 `ComparisonError` 로 멈췄다:
> ```
> Failed to unmarshal "ec2nodeclass.yaml": json: offset 2:
>   invalid character '{' looking for beginning of object key string
> ```
> 같은 커밋에 ⓐ 차트 파일과 ⓑ 그것을 걸러낼 `exclude` 를 함께 넣은 것이 원인이다.
>
> 1. root App 은 **자기 spec 을 git 에서 읽어 갱신**한다 — 그러려면 **먼저 저장소를 렌더**해야 한다
> 2. 렌더는 **아직 적용되지 않은 옛 `exclude`** 로 수행된다
> 3. 옛 `exclude` 는 새 차트 템플릿을 못 걸러낸다 → 렌더 실패
> 4. 렌더가 실패하니 **새 `exclude` 가 영원히 적용되지 않는다** — 무한 루프
>
> ⚠️ **패턴이 틀린 게 아니었다.** `gobwas/glob`(ArgoCD 가 쓰는 엔진, separators 없이 컴파일)로
> 검증하면 `{…,addons/karpenter/nodepool/**}` 는 `addons/karpenter/nodepool/templates/ec2nodeclass.yaml`
> 에 **정확히 매치한다.** 실물 root App 의 `.spec.source.directory.exclude` 가 **옛 값 그대로**였던 것이
> 증거다. 🔑 **글롭 문제로 오진하고 패턴을 계속 바꿨다면 영원히 못 고쳤을 것이다.**
>
> ### ⭐ 마커가 우월한 이유 — 순서 제약이 **사라진다**
>
> | | `exclude` | **마커** |
> |---|---|---|
> | 어디에 사는가 | root App **spec** | **파일 자신** |
> | 새 파일 추가 시 | spec 변경 필요 → **데드락 가능** | 변경 없음 |
> | 파일 이동·개명 | 패턴을 같이 고쳐야 함 | **따라간다** |
> | 판정 방식 | 경로 글롭 | 내용 검사(`bytes.Contains`) |
>
> ⇒ **파일이 태어날 때부터 스스로 제외된다.** ArgoCD 소스(`reposerver/repository/repository.go`)에서
> 마커 검사는 `exclude`·`include` **다음**에 오므로 둘은 충돌하지 않는다.
>
> ### 쓰는 법
> - 평문 YAML(`Chart.yaml`·`values.yaml`): `# +argocd:skip-file-rendering`
> - helm 템플릿: `{{- /* +argocd:skip-file-rendering … */ -}}` —
>   **파일 내용에는 남고 렌더 출력에는 안 남는다**(검증됨)
>
> ℹ️ 기존 `exclude` 2개(`clusters/**/values.yaml`·`bootstrap/argocd-values.yaml`)는 **그대로 둔다** —
> 동작 중인 것을 건드리지 않는다. **늘리지만 않는다.**

> ℹ️ **`argocd-seed.sh` 는 root App 의 훑기 대상이 아니다** — `exclude` 를 추가하지 않았다.
> directory 소스는 **`.yaml`·`.yml`·`.json` 만** 읽기 때문이다([ArgoCD 공식 문서](https://argo-cd.readthedocs.io/en/stable/user-guide/directory/):
> *"A directory-type application loads plain manifest files from `.yml`, `.yaml`, and `.json` files."*).
> ⛔ 그래서 `exclude` 에 넣지 않는다 — 스캔되지도 않는 것을 제외하면 **죽은 설정**이 되고,
> 다음 사람이 *".sh 도 스캔되는구나"* 라고 잘못 읽는다. `argocd-values.yaml` 이 제외된 이유는
> 그것이 **`.yaml` 이라서 실제로 스캔되기 때문**이다 — 둘의 차이가 여기 있다.

**확장 규칙 (O(1))**
- **새 클러스터** = `clusters/<env>/<cluster>/` 1개. `addons/` 의 ApplicationSet 은 **불변** —
  cluster generator 가 라벨로 자동 팬아웃한다.
- **새 앱팀** = `projects/<team>.yaml` 가드레일 1개. 앱 워크로드는 앱팀 repo(범위 밖).

---

## 알아야 할 규약

- ⛔ **`default` AppProject 를 쓰지 않는다** — `sourceRepos`/`destinations`/`clusterResourceWhitelist`
  가 전부 `'*'` 인 완전 개방 상태다. 플랫폼 리소스는 전용 `platform` 프로젝트에 둔다.
- 🔑 **cluster Secret 의 이름은 실제 EKS 클러스터명이어야 한다** — ApplicationSet 의 `{{name}}` 이
  ALBC 의 필수 파라미터 `clusterName` 으로 그대로 흘러간다. **별칭을 쓰면 조용히 틀린다.**
- ⚠️ **cluster Secret 의 `project` 필드 주의** — 값을 지정하면 그 프로젝트에서만 쓸 수 있는
  project-scoped cluster 가 된다. `platform` 과 어긋나면 클러스터가 `unknown` 으로 뜨는데
  **증상이 원인을 가리키지 않는다.**
- ⚠️ **`sourceRepos` 는 제3 가드레일이다** — Application 의 `repoURL` 이 여기 없으면
  `InvalidSpecError` 로 sync 자체가 안 선다. **addon 을 추가할 때마다 그 chart repo 를 추가**한다.
- ⚠️ **`clusterResourceWhitelist` 는 `[]` 로 시작한다** — addon 증분마다 그 addon 이 실제로 만드는
  kind 만 명시 개방한다(그때마다 리뷰 지점).
- **cert-manager · external-dns · 관측성 컨트롤러는 여기 없다** — Terraform community addon 소관이고,
  이 저장소에는 그 **설정(CR·애노테이션)만** 놓인다.

> ## ⭐ **D-ADDON-NS — addon 네임스페이스 규칙** (2026-08-10 확정)
>
> **계층 2(GitOps helm addon)는 addon 마다 전용 네임스페이스를 신설한다.**
> **예외는 둘뿐 — `aws-load-balancer-controller` · `karpenter` → `kube-system`.**
>
> ⛔ 예외를 늘리려면 **아래에 준하는 근거**를 대야 한다. *"차트 기본값이 `kube-system` 이라서"* 는
> 근거가 아니다. 규칙 본문·근거 전문은
> [`30 §2.9`](https://github.com/skax-ca/iac-module-library/blob/main/docs/design/30-gitops-repo.md).
>
> | # | 예외 근거 | 성격 |
> |---|---|---|
> | 1 | **Karpenter 공식이 이유까지 밝힌다** — `kube-system` 의 호출만 `system-leader-election`·`kube-system-service-accounts` **FlowSchema** 를 타고 `leader-election`·`workload-high` 우선순위로 간다. 다른 ns 면 **custom FlowSchema 를 우리가 소유**해야 한다 | ⭐ **기술적**(APF). 어기면 apiserver 스로틀링 때 **Karpenter 가 굶는다** |
> | 2 | **ALBC 도 공식이 `kube-system`** — AWS EKS User Guide · upstream kubernetes-sigs 둘 다 | 관례 |
> | 3 | **Pod Identity association 이 이미 `kube-system`** | **집행 장치** — 어기면 자격증명이 안 붙는다 |
>
> ⚠️ **3 을 1·2 보다 앞에 적지 않는다.** 그러면 *"IaC 우연에 GitOps 를 맞췄다"* 로 읽힌다 —
> 공식 권고가 먼저 있고, 3 은 그것을 어길 수 없게 만드는 장치다.
> 🔑 실제로 **가역적**이다: upstream 이 `namespace` 변수를 노출한다(기본 `kube-system`).
> ⇒ *"못 바꾼다"* 가 아니라 **"안 바꾼다"** 다.
>
> ⛔ **근거로 쓰지 말 것** — *"`system-cluster-critical` 은 `kube-system` 전용"* 은 **틀렸다.**
> `default` ns server-side dry-run 통과(실측 2026-08-10) · k8s master·1.31 admission plugin 에
> 그 제약 없음. **구버전 제약의 기억이다. 되살리지 말 것.**
>
> ### 🔧 전용 ns addon 을 넣을 때
> `syncPolicy.syncOptions` 에 **`CreateNamespace=true`** 를 넣는다.
> ⚠️ **첫 전용-ns addon 에서 판정할 것 2건**(argo-cd 문서에 서술이 없다):
> ① 생성되는 Namespace 가 AppProject `clusterResourceWhitelist` 적용을 받는가
> (받으면 `{group: "", kind: Namespace}` 를 열어야 한다)
> ② `managedNamespaceMetadata` 는 그 ns 를 **ArgoCD 추적 대상**으로 만든다(공식: *"manage namespace
> lifecycle operations like deletion"*) ⇒ 🔴 **`prune: true` 와 겹치면 addon 제거가 ns 째 지운다.**
>
> ℹ️ **계층 1(Terraform managed/community addon)은 이 규칙의 대상이 아니다** — ns 를 AWS·차트가
> 정하고 우리가 고르지 않는다. 결과적으로 어긋나지도 않는다(실측):
> `kube-system` = coredns·ebs-csi·metrics-server / `cert-manager` / `external-dns`.

---

## 부트스트랩 — 자기소멸(self-superseding) 원칙

최초 1회 [workbench](https://github.com/skax-ca/iac-module-library/blob/main/docs/design/40-workbench.md)
에서 seed 한 뒤, root App 이 그 리소스들을 **자기 소유로 흡수**한다.

```
0. helm install argo-cd          (workbench, 사람)   ← self-managed 고유
1. Access Entry                  ⛔ 불필요 — ArgoCD 가 클러스터 안에 있다 (spoke 는 필요)
2. GitHub App repository Secret  (kubectl seed)
3. projects/platform.yaml        (kubectl seed)
4. clusters/.../cluster-secret.yaml (kubectl seed)
5. bootstrap/root-app.yaml       (kubectl seed) → 자기 자신을 흡수
6. 이후 전부                      GitOps(pull) — argocd chart 자체도 Application 으로 흡수
```

> ⭐ **손으로 apply 하는 매니페스트는 이 저장소에 커밋된 것과 바이트 단위로 동일해야 한다.**
> 그래야 root App 이 첫 sync 에서 흡수하고 즉시 no-op 이 된다. seed 산출물은 이 저장소 콘텐츠의
> **사본**이지 별개 아티팩트가 아니다 — 다르면 그 차이가 **영구 드리프트**로 남는다.
>
> ⛔ **이 원칙은 helm values 에도 걸린다**(0단계). `helm install -f` 에 넘기는 values 는
> 저장소에 커밋된 그 파일이어야 하며, **`--set` 을 쓰지 않는다.**

---

## `bootstrap/argocd-seed.sh` — vendoring 규약

**SSOT 는 이 저장소가 아니라 [`skax-ca/iac-module-library`](https://github.com/skax-ca/iac-module-library/blob/main/scripts/argocd-seed.sh) 의 `scripts/argocd-seed.sh` 다.**
근거는 [`40 §2.5` 결정 ②](https://github.com/skax-ca/iac-module-library/blob/main/docs/design/40-workbench.md).

⛔ **이 사본을 편집하지 않는다.** 고칠 일이 생기면 모듈 repo 를 고치고 여기로 **다시 복사**한다.

왜 사본이 필요한가 — workbench 는 SSM 전용이라 `scp` 가 없고, 이 저장소를 여는 **GitHub App 의
설치 범위는 이 저장소 하나뿐**이다(모듈 저장소를 그 범위에 넣는 것은 §2.5 가 금지했다 —
ArgoCD 가 모듈 소스까지 읽게 된다). 사본이 여기 있으면 **클론 한 번으로 매니페스트와 스크립트가
함께** 온다 ⇒ 두 번째 배달 메커니즘을 만들지 않는다.

> ### 🔍 드리프트 검사 — 모듈 repo 체크아웃에서 한 줄
>
> ```bash
> diff <(grep -v '^#V#' <gitops>/bootstrap/argocd-seed.sh) scripts/argocd-seed.sh
> ```
> 사본 머리의 vendoring 배너는 모든 줄이 `#V#` 로 시작한다. **그것을 뺀 나머지는 SSOT 와
> 바이트 단위로 같아야 한다.** 배너에 접두를 둔 이유가 이것이다 — 검사를 한 줄로 끝내려고.
>
> 📌 배너의 "출처"는 **커밋 SHA** 다. §2.5 는 *"출처 태그"* 라 적었지만 `scripts/` 에는 태그 축이
> 없다(태그는 모듈별 semver 이고 이 스크립트는 `?ref=` 로 소싱되지 않는다).
>
> ⚠️ **이것은 경쟁 SSOT 가 아니라 vendoring 이다.** 구분 기준은 *"어디를 고치는가"* 하나다 —
> 고치는 곳이 하나면 사본이 여럿이어도 SSOT 는 하나다. 사본을 고치는 순간 drift 가 된다.

---

## 현재 상태 (2026-08-10)

✅ **seed 실행 완료 — ArgoCD 부트스트랩 성공**(2026-08-07). root App 이 seed 3종을 흡수했다.

```
projects/platform.yaml                                   # seed 3단계 ✅ 적용·흡수됨
clusters/dev/eks-ref-dev-an2-main-01/cluster-secret.yaml # seed 4단계 ✅ 적용·흡수됨
bootstrap/root-app.yaml                                  # seed 5단계 ✅ 자기 자신을 흡수
bootstrap/argocd-seed.sh                                 # 2026-08-10 vendoring (위 절)
```

> ### ✅ **`.sh` 를 넣어도 root App 이 깨지지 않는 것이 실증됐다** (2026-08-10)
>
> vendoring 커밋 `ba9d079` 이후 root App 은 **`Synced` `Healthy`, `revision=ba9d079…`** 다.
> directory 소스가 `.yaml`·`.yml`·`.json` 만 읽는다는 공식 문서 서술이 **실물로 확인됐다** —
> `exclude` 를 추가하지 않은 판단이 맞았다.

**판정**(workbench 에서 `kubectl` 실물 조회):

| 항목 | 결과 |
|---|---|
| `root-app.status.sync.revision` | ✅ **실제 SHA** `d118838…` = 저장소 HEAD 와 일치(`main` 이 아니다) |
| sync / health | ✅ `Synced` `Healthy` · `.status.conditions` 비어 있음 |
| pods | ✅ 5개 Running (controller·applicationset·redis·repo-server·server) |

> ⭐ **revision 이 실제 SHA 이고 HEAD 와 같다는 것이 자기소멸 원칙의 작동 증거다.**
> "읽었다"가 아니라 **손으로 apply 한 것과 root App 이 흡수한 것의 차이가 0** 이라는 뜻이다 —
> 차이가 있었다면 `OutOfSync` 로 드러났을 것이다. 🔑 `Synced` 가 이 원칙의 자동 검사다.

⛔ **남은 완료 조건 1건** — 초기 비밀번호 교체 + `argocd-initial-admin-secret` 삭제(`23 §2.3`).
아직 하지 않았다. **선택이 아니라 완료 조건**이다.

### 🚧 addon 증분 ① — ALBC + Karpenter (2026-08-10, 미머지 브랜치)

`addons/baseline/` 신설. **머지 = 배포**다(root App 이 `automated.selfHeal`).

| 대상 | 핀 | 근거 |
|---|---|---|
| `aws-load-balancer-controller` | **3.5.0** | `index.yaml` 전수 80개 semver 정렬 최신. chart `kubeVersion` 제약 없음 |
| `karpenter` (OCI) | **1.14.0** | ECR Public 태그 2,317개 + 호환성 매트릭스 원문 `1.35 → >= 1.9` |

⚠️ **`30 §2.2` 의 PoC 핀(`3.4.2`·`1.13.0`)은 쓰지 않았다.** 값이 아니라 *"실측해서 핀한다"* 는
원칙이 승계 대상이다.

**egress canary 로 먼저 확인했다**(`syncPolicy` 없음 = 비교만, 판정 후 삭제 — 배포 0):

| 호스트 | revision | rendered |
|---|---|---|
| `aws.github.io/eks-charts` | 3.5.0 | 17 |
| `public.ecr.aws/karpenter` (OCI) | 1.14.0 | 18 |
| `argoproj.github.io/argo-helm` | 10.3.0 | 55 (자기 관리용 — **이번 증분 아님**) |

> ### 🔴 **이 증분에서 잡힌 함정 3개 — 설계를 그대로 베꼈으면 전부 밟았다**
>
> ① **Karpenter 를 `karpenter` ns 에 배포하면 안 된다.** Pod Identity association 이
> **`kube-system`/`karpenter`** 로 잡혀 있다(upstream `terraform-aws-modules/eks//modules/karpenter`
> v21.24.1 기본값). Karpenter 공식 관례를 따르면 **컨트롤러가 AWS 자격증명을 못 받는다.**
>
> ② **NodePool 은 `arm64` 다.** 이 클러스터는 `AL2023_ARM_64_STANDARD`·t4g.medium(Graviton)인데
> `30 §2.2` 스펙은 **PoC 의 x86 기준으로 `amd64`** 라고 적혀 있다.
>
> ③ **rendered 0 + `ComparisonError` 가 egress 실패를 뜻하지 않는다.** Karpenter 첫 canary 가
> 정확히 그 형태였고 원인은 `settings.clusterName` 누락이었다. **1차 신호는 `revision` 해석 여부**다
> (`30 §2.9` 판독법). 오독했다면 *"못 나가니 미러링하자"* 로 갔을 것이다.

**가드레일 개방** — `clusterResourceWhitelist` 는 canary 의 `status.resources` 에서
namespace 없는 항목만 추린 **실측 목록**이다.

| addon | cluster-scoped kind |
|---|---|
| ALBC | CRD · ClusterRole · ClusterRoleBinding · Validating/MutatingWebhookConfiguration (**5종**) |
| Karpenter 컨트롤러 | CRD · ClusterRole · ClusterRoleBinding — ⭐ **ALBC 와 완전 중복이라 추가 0** |
| Karpenter CR | `karpenter.sh/NodePool` · `karpenter.k8s.aws/EC2NodeClass` |

⛔ `karpenter.sh/NodeClaim` 은 **넣지 않았다** — Karpenter 컨트롤러가 만드는 중간 리소스이고
ArgoCD 가 배포하지 않는다. 틀렸다면 신호는 `resource not permitted in project` 로 명확하다.

`root-app.yaml` 이 저장소 루트를 훑으므로 **`addons/baseline/` 이 늘어도 그 파일은 바뀌지 않는다.**
이번에 `exclude` 만 한 줄 늘었다(위 로컬 차트 상자).

**실물 좌표** — 매니페스트에 박힌 환경 고유값의 출처(전부 2026-08-07 실측):

| 값 | 출처 |
|---|---|
| `eks-ref-dev-an2-main-01` | `aws eks describe-cluster` |
| `vpc-00e16675363a702a5` | 같은 명령 → `resourcesVpcConfig.vpcId` |
| `Karpenter-eks-ref-dev-an2-main-01-66112745ef9ad44d7260570055` | `aws iam list-roles` |

**아직 검증되지 않은 것** — 2건 중 **1건 해소**(2026-08-07 apply 판정)

1. ✅ **해소**(2026-08-10) — cluster Secret 이 내장 `in-cluster` 를 **대체한다. 중복이 아니다.**
   `argocd admin cluster stats -n argocd` 결과 **서버 항목이 하나뿐**이다:
   ```
   SERVER                          SHARD  CONNECTION  NAMESPACES  APPS  RESOURCES
   https://kubernetes.default.svc  0      Successful  1           1     536
   ```
   - ⚠️ **`argocd login` 없이 판정했다** — `argocd admin` 은 API 서버가 아니라 **k8s 를 직접 읽는다.**
     초기 비밀번호를 조회하지 않고도 닫을 수 있었던 이유다(아래 완료 조건은 여전히 미이행).
   - 🔴 **함정**: `-n argocd` 를 빠뜨리면 *"`argocd-cm` 을 찾을 수 없다"* 는 경고가 나온다.
     **설정 공백이 아니라 네임스페이스 누락**이다.
   - 도구는 `workbench-v0.3.0` 이 넣은 `argocd` CLI v3.5.0 이다(`40` 열린 항목 7).
2. ✅ **해소** — GitHub App 설치 범위. installation token 으로 `GET /installation/repositories` 를
   직접 조회해 **`total_count=1` · 이 저장소 하나**임을 확인했다(2026-08-07).
   ⛔ 이 범위를 넓히지 않는다 — 모듈 저장소를 넣으면 ArgoCD 가 모듈 소스까지 읽는다(`40 §2.5`).
