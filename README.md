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
bootstrap/argocd-app.yaml    # ArgoCD 자기 관리 Application (증분 ②). ⬆ 위 values 를 $values 로 읽는다
bootstrap/argocd-seed.sh     # ⬅ VENDORED — seed 실행 스크립트. SSOT 는 모듈 repo (아래 절)
clusters/<env>/<cluster>/    # cluster Secret + per-cluster values. 새 클러스터 = 디렉토리 1개 (O(1))
projects/                    # AppProject 가드레일 — platform.yaml + <team>.yaml
addons/baseline/             # ①baseline helm addon ApplicationSet — 전 클러스터 팬아웃 (environment 라벨)
addons/catalog/              # ②opt-in 카탈로그 — **구독한 클러스터만** (addon-<name> 라벨)
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
> ### 🔴 **마커의 함정 — 마커를 *설명하는* 주석도 마커다** (2026-08-10, 실제로 밟았다)
>
> 판정은 **파일 전체 문자열 포함 검사**다(`bytes.Contains`). 주석이든 문서든 그 문자열이 **한 번이라도
> 나타나면** 그 파일은 통째로 스캔에서 빠진다.
>
> 실제로 `bootstrap/root-app.yaml` 의 주석에 마커를 그대로 적었다가 **root-app 이 자기 자신을
> 스캔에서 제외**했다. 결과는 조용하다 — 에러가 없고 이렇게만 나온다:
> ```
> RESULT PruneSkipped Application/root-app :: ignored (requires pruning)
> log: Skipping auto-sync: need to prune extra resources only but automated prune is disabled
> ```
> 저장소 렌더 결과에 root-app 이 없으니 **live 에만 있는 여분 리소스**가 되고, 영구 `OutOfSync` 다.
>
> > ## ⭐ **`prune: false` 가 재앙을 막았다**
> > root-app 이 "저장소에 없는 리소스"로 분류됐으므로, `prune: true` 였다면 **root App 이 스스로를
> > 삭제**하고 seed 를 처음부터 다시 밟아야 했다. `30 §4` 가 *"root 레벨에서 prune 을 켜면 저장소
> > 실수 하나가 seed 를 다시 밟게 한다"* 고 적은 시나리오가 **정확히 실현됐고 그 결정이 막았다.**
>
> ⇒ **규칙**: 마커 문자열은 **`.md` 문서**(스캔 대상 확장자가 아니다 — `^.*\.(yaml|yml|json|jsonnet)$`
> 만 스캔한다)나 **실제로 제외할 파일**에만 적는다. 다른 `.yaml` 에는 *"README 의 D-ROOTAPP-SKIP 참조"*
> 로만 가리킨다.
>
> **자기 점검 한 줄** — 의도 밖 파일이 마커를 물고 있지 않은지:
> ```bash
> grep -rl 'argocd:skip-file-rendering' --include='*.yaml' --include='*.yml' --include='*.json' . \
>   | grep -v 'addons/karpenter/nodepool/'
> ```
> 출력이 있으면 그 파일은 **조용히 스캔에서 빠지고 있다.**
>
> > 🔴 **2026-08-11 정정 — 필터에서 `^./` 앵커를 뺐다.** `grep -rl … .` 의 출력에 `./` 접두가
> > 붙는지는 **환경에 따라 다르다**(래퍼 함수·구현체마다 갈린다. 실측으로 확인했다).
> > 앵커가 있으면 그런 환경에서 **정상인데도 4줄이 출력된다.**
> > 🔑 **거짓 경보를 내는 점검은 곧 무시당한다** — 점검 장치의 결함은 점검 대상의 결함만큼 나쁘다.
> > 경로 조각 `addons/karpenter/nodepool/` 만으로도 충분히 특정된다.
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

### ✅ addon 증분 ① — ALBC + Karpenter (2026-08-10, **머지·배포 완료**)

> 🔴 **이 제목을 2026-08-11 에 고쳤다** — PR #1 머지(`10083ef`) + 복구 2회(`4dd4ace`·`28cefaf`)로
> **Application 3개 전부 `Synced Healthy`** 인데 *"미머지 브랜치"* 라고 적혀 있었다.
> 지난 세션이 *"문서 결함이 코드 결함보다 많았다"* 고 기록한 그 유형이다.
> 🔑 **상태를 제목에 쓰면 상태가 변할 때마다 제목이 낡는다.**

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

---

### ✅ 증분 ② — ArgoCD 자기 관리 (2026-08-11, **머지·배포 완료** — PR #2 `3cecd80`) · **1단계 = 비교만**

> ⚠️ **아래 본문은 착수 시점에 쓴 것이다.** 판정 결과는 모듈 repo **§2.10.5** 가 소유한다 —
> `Application/argocd` 생성 · **파드 재시작 0** · 그러나 **37개 리소스가 영구 `OutOfSync`** 였다.
> 그 고착은 **증분 ②-b·③-b**(이 문서 맨 아래)가 닫는다.

설계 SSOT: 모듈 repo `docs/design/30-gitops-repo.md` **§2.10.1 (D-ARGOCD-ADOPT)**.
`23 §2.1` 이 정한 *"seed 1회 + 자기 관리"* 3단계 중 **2단계(흡수)** 를 실물로 만든다.

| 파일 | 변경 |
|---|---|
| `bootstrap/argocd-app.yaml` | 🆕 Application(**ApplicationSet 아님**) · multi-source · `releaseName: argocd` · **`automated` 없음** |
| `projects/platform.yaml` | `sourceRepos` 에 `https://argoproj.github.io/argo-helm` 추가 |
| `clusterResourceWhitelist` | **변경 없음** — 렌더 실측상 CRD 3 · ClusterRole 2 · ClusterRoleBinding 2 뿐이고 전부 기존 |

> ## ⭐ **머지해도 아무것도 배포되지 않는다 — 이번 PR 의 핵심 성질이다**
>
> `syncPolicy.automated` 를 넣지 않았으므로 이 Application 은 **비교만 한다.**
> 증분 ① 의 *"머지 = 배포"* 와 **다르다.** 흡수 대상이 `application-controller` 자신이라,
> diff 를 사람이 읽기 전에 자동 적용시키지 않는다.
> ⇒ `automated` 는 **2단계 PR** 에서 붙인다.

**1단계에서 읽을 것 3건** (로컬 `helm template` 으로 미리 특정했다 — *"무엇이 나올지 알고 본다"*):

```bash
argocd app get argocd -n argocd        # Synced/OutOfSync · conditions
argocd app diff argocd                 # ⬅ 이것이 판정의 본체
```

| # | 지점 | 기대 | 위험 |
|---|---|---|---|
| **1** | 🔴 `Secret/argocd-secret` | 차트가 **`data` 없이** 렌더한다(메타데이터 + `type: Opaque`). argocd-server 가 런타임에 **admin 비밀번호 해시·`server.secretkey`·TLS** 를 채우는 자리 | 잘못 적용하면 **관리자 자격증명과 세션 키가 날아간다**. `ServerSideApply=true` 가 막는다 — SSA 는 선언한 필드만 소유한다 |
| **2** | helm hook 4개 `argocd-redis-secret-init` | ArgoCD 가 `PreSync` 훅으로 번역한다 ⇒ **sync 마다 Job 이 하나 뜬다** | 놀랄 일이지 사고가 아니다 — **정상** |
| **3** | 리소스 44개의 이름 | 전부 `argocd-*` — release 이름 `argocd` 에서 파생 | 아래 ⭐ |

> ### ⭐ **release 이름이 어긋나면 흡수가 아니라 병렬 설치다**
>
> `argocd-seed.sh` 의 `ARGOCD_RELEASE` 기본값이 **`argocd`** 이고(`:137`), ArgoCD 는 helm source 의
> release 이름을 **Application 이름에서** 가져온다. Application 을 `argocd-self` 로 지었다면
> `argocd-self-server` 같은 **새 리소스 44개**가 생긴다.
> ⇒ 이름을 `argocd` 로 하고 그 위에 **`helm.releaseName: argocd` 를 명시**했다.
> ⚠️ 중복처럼 보이나 죽은 설정이 아니다 — **이름을 바꾸는 순간 조용히 깨지는 결합**을 값으로 고정한다.

> ### 🔴 **`prune` 은 2단계에서도 켜지 않는다**
>
> root App 과 같은 이유에 더해, 이 Application 이 소유하지 않은 두 Secret 이 `argocd` ns 에 산다:
> - `sh.helm.release.v1.argocd.v1` — seed 의 helm 릴리스 기록. **지우지 않는다**(고치는 것도 위험이다)
> - `argocd-repo-gitops` — GitHub App private key. **자기소멸 원칙의 의도된 예외**(위 seed 절)

⛔ **`ignoreDifferences` 를 미리 넣지 않았다.** 필요한지는 **1단계 diff 가 답한다** —
필요 없는데 넣으면 죽은 설정이고, 필요하면 그때 `{kind: Secret, name: argocd-secret,
jsonPointers: ["/data"]}` 를 **근거와 함께** 넣는다.

⚠️ **차트는 `10.3.0` 그대로다.** 흡수와 업그레이드를 같은 커밋에 넣지 않는다 —
실패했을 때 *"흡수가 문제인가 새 차트가 문제인가"* 를 가를 수 없다.

---

### ✅ 증분 ③ — Kyverno + PSS 정책 (2026-08-11, **머지·배포 완료** — PR #5 `b13e9ea`) · **첫 전용 네임스페이스 addon**

> ⚠️ PR 번호가 **#3 → #5** 로 바뀌었다 — #2 를 `--delete-branch` 로 머지하자 자식 PR 이 닫혔다
> (절차 교훈은 모듈 repo §2.10.5). 판정: 4 컨트롤러 Running · ClusterPolicy 11개 `Ignore`/`Audit`
> · 그러나 **CRD 11개 + ClusterPolicy 11개가 영구 `OutOfSync`** → **증분 ③-b** 가 닫는다.

설계 SSOT: 모듈 repo **§2.10.2 (D-KYVERNO)**. 분류는 **①baseline**(사용자 결정) —
*정책 엔진은 가드레일이고, **옵트인 가드레일은 가드레일이 아니다.***

| 차트 | 핀 | appVersion | 근거 |
|---|---|---|---|
| `kyverno` | **3.8.2** | `v1.18.2` | `index.yaml` 전수 263개 중 stable 79개 semver 정렬 최신. `kubeVersion >=1.25.0-0` ✅ |
| `kyverno-policies` | **3.8.2** | `v1.18.2` | ⭐ **컨트롤러와 같은 번호로 함께 릴리스된다** ⇒ 스큐 판단 불필요. 올릴 땐 **둘 다** |

구조는 **Karpenter 와 같다** — 파일 1개 · ApplicationSet 2개 · CRD 순서 때문에 wave 분리
(컨트롤러 `0` → 정책 `5` + `SkipDryRunOnMissingResource`).

> ## 🔴 **이 증분이 D-ADDON-NS 의 미판정 2건을 처음 실물로 만난다**
>
> **판정 ① — 자동 생성 Namespace 는 `clusterResourceWhitelist` 검사를 받는다.**
> argo-cd `v3.5.0` 소스 판정: `CreateNamespace=true` 로 만들어지는 ns 가
> **같은 sync task 목록에 append** 되고(`gitops-engine sync_context.go:846`) 목록 전체가
> `permissionValidator` 를 거친다(`:904`). Namespace 는 `Namespaced=false` 라
> `clusterResourceWhitelist` 로 판정된다(`controller/sync.go:657`).
> ⚠️ **ns 가 이미 있으면 task 자체가 생기지 않아 검사도 없다**(`controller/sync_namespace.go`)
> ⇒ 손으로 먼저 만들면 통과하고 **두 번째 클러스터에서만** 깨진다. **그래서 지금 연다.**
>
> **판정 ② — `managedNamespaceMetadata` 를 쓰지 않는다.** 공식 문서가
> *"including the possibility to delete it, which Argo CD normally does not do"* 라고 못박는다.
> `prune: true` 와 겹치면 **addon 제거가 네임스페이스째 지운다.**
> ✅ 쓰지 않으므로 ns 는 추적 대상이 아니고 prune 대상도 아니다.

> ## ⭐ **`failurePolicy` 를 `Fail`(차트 기본) → `Ignore` 로 바꾼 것이 유일한 값 변경이다**
>
> | 값 | 묻는 것 | 차트 기본 | 우리 값 |
> |---|---|---|---|
> | `validationFailureAction` | **정책을 위반했을 때** | `Audit` | `Audit` — **적지 않는다**(기본값과 같다) |
> | `failurePolicy` | **웹훅에 닿지 못할 때** | `Fail` | 🔴 **`Ignore`** |
>
> **Audit + Fail 은 비정합이다.** 아무것도 막지 않기로 해 놓고 **Kyverno 가 죽으면 전부 막는다.**
> ⭐ `background: true`(기본)라 웹훅을 놓쳐도 **백그라운드 스캔이 PolicyReport 를 만든다** —
> 잃는 것은 *실시간성* 뿐이다.
> ⚠️ **Enforce 로 전환할 때 `Fail` 로 함께 올린다.** 두 값은 **짝으로 움직인다.**

> ### ⭐ **차트 기본 웹훅 제외가 ALBC·Karpenter 를 이미 지켜 준다**
>
> `ConfigMap/kyverno` 의 `webhooks.namespaceSelector` 가 **`kube-system`·`kyverno` 를 제외**한다
> (실측). apiserver 가 그 ns 에 대해서는 Kyverno 를 **호출조차 하지 않는다.**
> 🔑 D-ADDON-NS 의 예외 2개가 **무관한 방향에서** 값을 돌려줬다.
>
> 🔴 **그러나 `argocd` 는 제외 대상이 아니다.** 지금(Audit + `Ignore`)은 무해하지만
> **Enforce + `Fail` 로 가면 순환 의존**이다 — Kyverno 장애 → ArgoCD 막힘 → Kyverno 를 고칠 수단 상실.
> ⇒ Enforce 전환은 그 질문을 **먼저** 답한다. ⛔ 지금 미리 넣지 않는다(죽은 설정이 된다).

**가드레일 개방** — `sourceRepos` +1(`kyverno.github.io/kyverno/`) ·
`clusterResourceWhitelist` +2(`(core)/Namespace`, `kyverno.io/ClusterPolicy`).
⭐ 컨트롤러의 cluster-scoped **47종**(CRD 22 · ClusterRole 17 · CRB 8)은 **추가 0건** —
전부 ALBC 증분에서 이미 열렸다. 🔑 whitelist 는 **kind 단위**다.

⚠️ **웹훅 설정은 렌더 결과에 없다** — Kyverno 가 런타임에 동적 등록한다. ArgoCD 가 소유하지 않으므로
whitelist 대상이 아니고, 뒤집으면 **웹훅이 잘못돼도 Application 은 `Synced Healthy` 로 보인다.**

**apply 판정 항목** (머지 = 배포다 — 이 증분은 `automated` 를 켠다)

| # | 보는 것 |
|---|---|
| 1 | 🆕 **`ghcr.io` 이미지 pull** — 이미지가 `reg.kyverno.io`(= GHCR vanity 도메인, 401 realm 실측)에서 온다. 지금까지 addon 이미지는 **전부 `public.ecr.aws`** 였다. ⚠️ **canary 로 앞당길 수 없다**(canary 는 repo-server 의 차트 fetch 만 본다 — 이미지 pull 은 kubelet→NAT) |
| 2 | Namespace `kyverno` 가 생겼는가 · whitelist 오류 없이 sync 됐는가 (판정 ①의 실증) |
| 3 | ClusterPolicy 11개가 `Ready` 이고 `failurePolicy: Ignore` · `validate.failureAction: Audit` 인가 |
| 4 | PolicyReport 가 생기는가 — 정책이 **실제로 무언가를 보고 있는지**의 증거 |
| 5 | ⚠️ 기존 워크로드(ALBC·Karpenter·ArgoCD)가 **영향받지 않았는지** |

✅ arm64 확인 완료(manifest index 에 `linux/arm64`) — 이 클러스터는 Graviton 이다.

---

### ✅ 증분 ④ — KEDA (2026-08-11, **머지·배포 완료** — PR #4 `1bb27e9`) · **`addons/catalog/` 를 처음 켠다**

> ⭐ 판정: 파드 3개 Running · `APIService` **Available** · **혼자 `Synced Healthy`**.
> 🔑 **그 "혼자"가 자산이 됐다** — 같은 옵션(`ServerSideApply=true`)인데 ②③만 `OutOfSync` 라
> *"ArgoCD 설정이 잘못됐다"* 가설이 배제됐다. **증분을 나눈 덕에 대조군이 생겼다**(모듈 repo §2.10.5).

설계 SSOT: 모듈 repo **§2.10.3 (D-KEDA-CATALOG)**. 분류는 **②opt-in 카탈로그** —
`30 §2.4` 가 2026-07-20 에 이미 그렇게 분류해 두었고(*"Kafka/Redis operator·**KEDA**·service mesh"*),
그 절이 *"경로만 명문화, 구현은 미룸"* 이라고 적은 것을 **이 증분이 실물로 만든다.**

| 차트 | 핀 | appVersion | 근거 |
|---|---|---|---|
| `keda` | **2.20.2** | `2.20.2` | `index.yaml` 전수 78개 중 stable 72개 semver 정렬 최신. `kubeVersion >=v1.23.0-0` ✅ |

> ## 🔀 **①baseline 과 갈리는 지점은 generator 의 `matchLabels` 하나뿐이다**
>
> | | matchLabels | 대상 |
> |---|---|---|
> | ① baseline | `{environment: dev}` | 전 클러스터 자동 |
> | **② catalog** | **`{addon-keda: enabled}`** | **구독한 클러스터만** |
>
> 구독 = cluster Secret 에 라벨을 다는 것이다
> (`clusters/dev/eks-ref-dev-an2-main-01/cluster-secret.yaml`).
> 🔑 `30 §2.4` 의 *"플랫폼이 무엇을·어떤 버전으로 승인하고, 팀은 쓸지를 라벨로 옵트인"*
> (**paved road**)이 실물에서 뜻하는 바가 이것이다.
>
> 🔴 **`30 §2.9` 의 *"cluster Secret 은 손대지 않는다"* 는 baseline 전제였다** — §2.10.3 이 정정했다.
> **O(1) 은 유지된다**: 새 클러스터도 여전히 Secret 1개이고, 라벨이 하나 늘 뿐이다.
> ⚠️ 라벨 값은 **문자열**이어야 한다 — k8s 라벨에 boolean 은 없다. `true` 가 아니라 `"enabled"`.

> ### 🔴 **`APIService` — 이번 세 증분에서 유일하게 성격이 다른 리소스**
>
> KEDA 가 **`v1beta1.external.metrics.k8s.io`** 를 등록한다. 이것이 깨지면 **그 API 그룹 전체가 죽는다.**
> - ⚠️ 계층 1 의 `metrics-server` 는 `v1beta1.metrics.k8s.io` 라 **그룹이 달라 충돌하지 않는다.**
> - ⚠️ 지금은 `external.metrics` 를 소비하는 것이 없어 무해하지만, **HPA 가 쓰기 시작하면
>   KEDA 장애 = HPA 장애**다 ⇒ 그때 가용성 요구를 다시 본다(현재 `replicas: 1`).

**AWS 스케일러는 넣지 않았다**(사용자 결정) — in-cluster 트리거(cron·prometheus·kafka)만 쓴다.
⇒ Pod Identity·IAM **0건** ⇒ ⭐ **이 증분이 계층 2 안에서 닫힌다**(모듈 repo `.tf` 도, 소비 repo apply 도 없다).
⚠️ SQS·CloudWatch 요구가 생기면 `modules/eks-cluster/iam.tf` 에 `keda/keda-operator` association 을
연다 — ALBC·external-dns 와 **같은 패턴**이라 새로 발명할 것이 없다. **가역적이다.**

**가드레일 개방** — `sourceRepos` +1(`kedacore.github.io/charts`) ·
`clusterResourceWhitelist` +1(`apiregistration.k8s.io/APIService`).
나머지(CRD 6 · ClusterRole 4 · CRB 5 · ValidatingWebhookConfiguration 1)는 **전부 기존**이다.

**apply 판정 항목**

| # | 보는 것 |
|---|---|
| 1 | ⭐ **라벨 옵트인이 실제로 작동하는가** — 라벨이 있는 클러스터에만 Application 이 생겼는가. ②경로의 첫 실증이다 |
| 2 | Namespace `keda` 생성 + whitelist 오류 없음 |
| 3 | `APIService v1beta1.external.metrics.k8s.io` 가 `Available=True` 인가. ⚠️ `metrics-server` 가 **영향받지 않았는지** 함께 본다 |
| 4 | 파드 3개 Running (`ghcr.io` 이미지 pull — 증분 ③과 같은 새 축) |

✅ arm64 확인 완료 — 3개 이미지 전부 manifest index 에 `linux/arm64`.

---

### 🔶 증분 ②-b·③-b — `OutOfSync` 고착 해소 (2026-08-11, **머지 완료** — PR #6 `3a66228`) · **③만 해소, ②는 원인이 달랐다**

> ## 🔴 **판정: 2/3 성공. 반증 조건이 실제로 발동했다**
>
> | 대상 | 결과 |
> |---|---|
> | `kyverno` · `kyverno-policies` | ✅ **`Synced Healthy`** — CRD 11 + ClusterPolicy 11 해소 |
> | `argocd` | 🔴 **`OutOfSync` 그대로(37개 전부)** — **원인이 diff 전략이 아니었다** |
> | 파드 재시작 | ✅ **0회** (`startTime` 2026-08-07 그대로) |
> | 다른 앱 + root-app | ✅ 무영향 |
>
> ### 🔴 세 번째 정정 — ②의 원인은 **ArgoCD 자신의 `tracking-id`** 다
>
> `argocd app diff argocd --core` 로 **실제 diff 를 처음 열었다.** 37개의 차이는 **전부 한 줄**:
> `> argocd.argoproj.io/tracking-id: argocd:/ConfigMap:argocd/argocd-cm`.
> **`meta.helm.sh` 는 0회 등장한다.**
> ⭐ 대조군이 증명한다 — kyverno 의 `ClusterPolicy` live 에는 tracking-id 가 **있고**(ArgoCD 가 apply 했다),
> `argocd-cm` 에는 **없다**(한 번도 sync 된 적이 없다).
> ⇒ **sync 를 한 번 해야만 사라진다** = **PR-②b** 가 소유한다. `bootstrap/argocd-app.yaml` 의
> 애노테이션은 **철회했다**(PR #7).
>
> ### ⭐ 그런데 이것이 이 증분이 얻은 가장 값진 결과다
>
> 37개에서 **유일한 차이가 ArgoCD 자신의 추적 애노테이션**이라는 것은 **흡수해도 실질 변경이 0**
> 이라는 뜻이다. *"37개 전부 OutOfSync"* 를 위험으로 읽었지만 실제로는 **흡수가 안전하다는 증거**였다.
> 🔑 **숫자를 읽고 내용을 안 읽으면 정반대로 해석된다.**
> ⇒ PR-②b 가 할 일이 특정됐다: **애노테이션 37개 추가, 그 외 0.** pod template 을 건드리지 않으므로
> **재시작이 없어야 한다.**
>
> ### ⚠️ 운영 사실 — 애노테이션만으로는 재계산되지 않는다
>
> 애노테이션이 도착한 뒤에도 셋 다 `OutOfSync` 였고, `argocd.argoproj.io/refresh=hard` 를 넣자
> kyverno 둘이 `Synced` 가 됐다. ⇒ **diff 전략을 바꾸는 증분에는 hard refresh 를 판정 절차에 넣는다.**

---

#### (착수 시점 기록 — 아래는 판정 전에 쓴 것이다)

설계 SSOT: 모듈 repo **§2.10.6 (D-SSDIFF)**. 증분 ②③ 이 배포는 성공했는데
**59개 리소스가 영구 `OutOfSync`** 로 남은 것을 닫는다(② 37 · ③ CRD 11 · ③ ClusterPolicy 11).

> ## 🔴 **고치는 대상은 클러스터가 아니라 신호다**
>
> 세 Application 모두 `phase=Succeeded` 이고 리소스는 정상 동작한다. **기능적으로는 문제가 없다.**
> 그런데 **항상 `OutOfSync` 이면 "`OutOfSync` = 문제"라는 신호가 죽는다** — 진짜 drift 가 들어와도
> 구분할 수 없다. 🔑 이 저장소에서 **같은 범주가 이미 세 번째**다
> (`^./` 앵커가 낸 거짓 경보 · CI 캐시 판정 기준 · 이것).
> ⛔ **거짓 신호를 내는 장치는 곧 무시당한다 — 점검 장치의 결함은 점검 대상의 결함만큼 나쁘다.**

#### 변경 — 애노테이션 3줄이 전부다

| 파일 | 대상 |
|---|---|
| `bootstrap/argocd-app.yaml` | `Application/argocd` |
| `addons/baseline/kyverno.yaml` | ApplicationSet `kyverno` (template) |
| `addons/baseline/kyverno.yaml` | ApplicationSet `kyverno-policies` (template) |

전부 `argocd.argoproj.io/compare-options: ServerSideDiff=true`.
**차트 버전·values·syncOptions·AppProject 델타 0.** 새로 만들어지는 리소스도 없다.

#### 🔴 이 증분이 앞 증분의 **원인 진단 2건을 정정한다**

§2.10.5 는 세 고착을 *"셋 다 다른 매니저가 소유"* 로 묶었는데, `--show-managed-fields` 로 열어 보니
뒤 둘은 **소유자가 아예 없는 필드**였다.

| 대상 | 앞 증분의 진단 | 실측 |
|---|---|---|
| ② `argocd-cm` 등 37개 | `helm` 소유 애노테이션 | ✅ 맞다 (매니저가 `helm` **하나뿐**) |
| ③ CRD 11개 | *"`kube-apiserver` 가 채운다"* | 🔴 그 매니저는 **`status` 서브리소스만** 소유. 실제 차이는 **`spec.conversion`**(무소유) |
| ③ ClusterPolicy 11개 | *"kyverno 자기 웹훅이 주입"* | 🔴 `kyverno` 도 **`status` 만** 소유. 실제 차이는 **`spec.admission`·`emitWarning`** = CRD 스키마 `default:` |

⇒ 원인은 셋이 아니라 **둘**이고, **mutation webhook 은 관여하지 않는다.**
⛔ 그래서 `IncludeMutationWebhook=true` 를 **넣지 않는다** — 넣으면 웹훅 변형까지 diff 에 들어와
새 고착을 만든다. 🔑 **원인을 틀리게 알아도 옵션은 맞을 수 있다. 그러면 다음번에 같은 오진을 반복한다.**

#### ✅ 배포 전에 이미 확인한 것 — SSA dry-run 은 비파괴다

`kubectl apply --server-side --dry-run=server --field-manager=argocd-controller` 로
**ServerSideDiff 가 하는 계산을 그대로** 돌렸다(클러스터를 바꾸지 않는다).

| 대상 | desired 에서 뺀 것 | predicted vs live |
|---|---|---|
| `ClusterPolicy/disallow-host-path` | `spec.admission`·`emitWarning` | **IDENTICAL** |
| `CRD/mutatingpolicies.policies.kyverno.io` | `spec.conversion` | **IDENTICAL** |
| `ConfigMap/argocd-cm` | 애노테이션 전부 | `meta.helm.sh/*` **보존** |
| 🔴 `Secret/argocd-secret` | `data` 전체 | 5키 **전부 보존** |

⭐ 마지막 줄이 §2.10.1 **위험 1**(자격증명 소실)을 diff 축에서도 닫는다.

#### ⚠️ 대가 — 감지 범위가 좁아진다

ServerSideDiff 는 *우리가 선언하지 않은* 필드의 변경을 **더 이상 drift 로 보고하지 않는다.**
바꾸는 것은 표시 방식이 아니라 **"무엇을 drift 로 볼 것인가"의 정의**다.
그래도 택한다 — **좁지만 살아 있는 신호가, 넓지만 아무도 안 보는 신호보다 낫다.**

#### apply 판정 항목 (머지 = 배포)

| # | 보는 것 | 기대 |
|---|---|---|
| 1 | 세 Application | `Synced Healthy` |
| 2 | **파드 재시작 0** | diff 전략은 apply 를 하지 않는다. `argocd` 앱은 `automated` 도 꺼져 있다 |
| 3 | `Secret/argocd-secret` data 5키 | 유지 |
| 4 | ALBC·Karpenter·NodePool·KEDA·root-app | **무영향** (애노테이션을 안 건드렸다) |
| 5 | ⚠️ 반증 조건 | 하나라도 `OutOfSync` 로 남으면 **그 대상만** `ignoreDifferences` 로 보완하고 근거를 §2.10.6 에 적는다 |

⛔ **`automated: {selfHeal: true}`(PR-②b 본편)는 이 증분에 넣지 않는다** — 켜면 37개 리소스에
sync 가 걸리고(`Deployment` 4 · `StatefulSet` 1) **ArgoCD 가 자기 자신을 재시작**한다.
diff 를 먼저 정상화해야 그 sync 가 무엇을 하려는지 읽을 수 있다.
> ⚠️ **위 문장의 재시작 우려는 완화됐다** — 아래 PR-②b 절이 소유한다. 실측상 sync 는
> 애노테이션만 붙이고 **pod template 을 건드리지 않는다.**

---

### 🚧 PR-②b — ArgoCD 자기 관리 **2단계: `automated` 를 켠다** (2026-08-11)

설계 SSOT: 모듈 repo **§2.10.8**. `23 §2.1` 의 *"seed 1회 + 자기 관리"* 3단계 중 **마지막 칸**이다.
이 PR 이 머지되면 ArgoCD 의 SSOT 는 helm 릴리스가 아니라 **완전히 이 저장소**가 된다.

#### 변경 — `bootstrap/argocd-app.yaml` 한 곳

```yaml
  syncPolicy:
    automated:
      selfHeal: true
      prune: false      # ⛔ 결정 5·§4 대로. helm 잔존물이 "저장소에 없는 리소스"가 된다
```

#### ✅ 배포 전에 답한 것 — 실측 3건

| # | 질문 | 답 |
|---|---|---|
| 1 | sync 가 **무엇을** 바꾸나 | `argocd app diff --core`: 37개의 차이는 **전부 `tracking-id` 한 줄** ⇒ **실질 변경 0** |
| 2 | SSA 가 `helm` 과 **충돌하나** | 🔴 **한다** — 실제 렌더본으로 2건(`env[NAMESPACE].valueFrom.fieldRef` · `NetworkPolicy.spec.ingress`). 둘 다 **atomic 구조체 + apiserver 기본값** |
| 3 | 충돌이 sync 를 **막나** | ✅ **아니다** — 공식 문서상 `ServerSideApply=true` 는 `kubectl apply --server-side --force-conflicts` 로 실행된다 |

> ## ⭐ **`argocd app diff` 는 깨끗한데 SSA 는 충돌한다**
>
> ArgoCD 의 diff 가 **기본값을 정규화해 지우기** 때문이다.
> 🔑 **diff 가 깨끗한 것은 apply 가 충돌하지 않는다는 뜻이 아니다.** 둘은 다른 질문이다.

✅ **`--force-conflicts` 예측**: pod template **5개 전부 IDENTICAL** · `NetworkPolicy.spec` **4개 전부
IDENTICAL** · `argocd-secret` data **5키 보존** ⇒ 충돌 해소는 소유권이 `helm` → `argocd-controller` 로
옮겨가는 것일 뿐 **값은 안 바뀐다.** ⭐ **그것이 흡수(adopt)의 정의 그 자체다.**

#### ⛔ 넣지 않는 것 — 이름만 비슷한 세 축

| 옵션 | 무엇인가 | 판단 |
|---|---|---|
| `ServerSideApply=true` | **apply 방식** (`--force-conflicts` 포함) | ✅ 1단계부터 있다 |
| `Force=true` | **`kubectl delete/create`** | ⛔ 적용 대상이 ArgoCD 자신 — 이 증분이 피하려는 사고 그 자체 |
| `Replace=true` | 객체 통째 교체 | ⛔ 문서 명시 *"`ServerSideApply` 보다 **우선**"* ⇒ Secret 보호가 조용히 무력화 |
| `ServerSideDiff=true` | **비교 방식** | ⛔ 이 앱에는 불필요(PR #7 에서 철회) |

#### 📋 apply 판정 항목 (머지 = 배포)

| # | 보는 것 | 기대 |
|---|---|---|
| 1 | `Application/argocd` | **`Synced Healthy`** |
| 2 | 🔴 **파드 재시작** | **0회** (`startTime` 2026-08-07 유지) |
| 3 | `Secret/argocd-secret` | data 5키 유지 |
| 4 | `Job/argocd-redis-secret-init` | 생성 + `Succeeded` (§2.10.1 **위험 2** — 정상) |
| 5 | field manager | 충돌 2건의 소유자가 `argocd-controller` 로 이동 |
| 6 | 다른 앱 + root-app | 무영향 |
| 7 | ⚠️ 반증 조건 | 파드가 하나라도 재시작하면 **예측이 틀린 것이다** — 원인을 규명해 §2.10.8 에 적는다 |
