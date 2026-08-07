# iac-platform-gitops

**플랫폼 GitOps monorepo (계층 2)** — ArgoCD 가 pull 로 reconcile 하는 플랫폼 소관 매니페스트 저장소.

⚠️ **설계 SSOT 는 이 저장소가 아니다.** 규약을 바꾸려면 아래 문서를 먼저 고친다.

| 문서 | 내용 |
|---|---|
| [`docs/design/30-gitops-repo.md`](https://github.com/skax-ca/iac-module-library/blob/main/docs/design/30-gitops-repo.md) | **이 저장소의 구조·규약** — 레이아웃·등록·팬아웃·테넌시·부트스트랩 |
| [`docs/design/23-argocd-self-managed.md`](https://github.com/skax-ca/iac-module-library/blob/main/docs/design/23-argocd-self-managed.md) | **현재 경로** — self-managed ArgoCD 설치·인증·도달성 |
| [`docs/design/21-gitops-bootstrap-seam.md`](https://github.com/skax-ca/iac-module-library/blob/main/docs/design/21-gitops-bootstrap-seam.md) | 경로 선택(D-GITOPS-SEAM)과 **갈림점 6개** |
| [`docs/design/40-workbench.md`](https://github.com/skax-ca/iac-module-library/blob/main/docs/design/40-workbench.md) | seed 수행 지점(workbench), ArgoCD 도달 절차 |

> ⚠️ **`30` 은 부분 개정 문서다** — §1.1·§4.1 만 확정이고 나머지는 PoC 전제가 남아 있다.
> **인용할 때 절 번호까지 확인**한다.

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
bootstrap/root-app.yaml   # App-of-Apps root — seed 대상. 이후 자기 자신을 흡수
clusters/<env>/<cluster>/ # cluster Secret + per-cluster values. 새 클러스터 = 디렉토리 1개 (O(1))
projects/                 # AppProject 가드레일 — platform.yaml + <team>.yaml
addons/                   # (예정) helm addon ApplicationSet — cluster generator 로 팬아웃
```

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

## 현재 상태 (2026-08-07)

**seed 3종 작성 완료 — 아직 클러스터에 적용되지 않았다.**

```
projects/platform.yaml                                  # seed 3단계
clusters/dev/eks-ref-dev-an2-main-01/cluster-secret.yaml # seed 4단계
bootstrap/root-app.yaml                                  # seed 5단계
```

`addons/` 는 아직 없다(다음 증분). `root-app.yaml` 이 저장소 루트를 훑으므로
디렉토리가 늘어도 그 파일은 바뀌지 않는다.

**실물 좌표** — 매니페스트에 박힌 환경 고유값의 출처(전부 2026-08-07 실측):

| 값 | 출처 |
|---|---|
| `eks-ref-dev-an2-main-01` | `aws eks describe-cluster` |
| `vpc-00e16675363a702a5` | 같은 명령 → `resourcesVpcConfig.vpcId` |
| `Karpenter-eks-ref-dev-an2-main-01-66112745ef9ad44d7260570055` | `aws iam list-roles` |

**아직 검증되지 않은 것** (apply 시 판정):
1. `server: https://kubernetes.default.svc` 인 cluster Secret 이 ArgoCD 내장 `in-cluster` 항목을
   **대체하는지 / 중복으로 뜨는지** — argo-cd v3.5.0 문서에 서술이 없다. `argocd cluster list` 로 본다.
2. GitHub App 설치 범위에 이 저장소가 포함되는지 — ArgoCD 가 실제 pull 할 때 드러난다.
