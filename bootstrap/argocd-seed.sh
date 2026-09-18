#!/usr/bin/env bash
# argocd-seed.sh: self-managed ArgoCD 부트스트랩 seed(workbench에서 사람이 실행).
#
# 자기소멸(self-superseding) 원칙이 이 스크립트의 설계 제약이다. 매니페스트를 생성하지 않고 GitOps
# 저장소에 커밋된 파일을 그대로 apply한다. 생성하면 커밋본과 바이트가 달라지고 그 차이가 영구
# 드리프트로 남는다. 그래서 --set도 인라인 heredoc 매니페스트도 쓰지 않는다. 예외는 없다.
# 저장소가 public이라 ArgoCD는 repository Secret 없이 익명으로 읽는다.
# ⚠️ bash 3.2 호환으로 쓴다. macOS 기본 bash가 3.2이고 이 스크립트는 workbench(bash 5)뿐 아니라
#    팀원 노트북에서 --dry-run으로도 돌린다. 연상배열·mapfile·${var^^}를 쓰지 않는다.
#
# 절차: eks-reference-infra 의 docs/hub-lifecycle.md.
# self-managed ArgoCD 선택 근거: iac-module-library 의
# docs/architectures/gitops-hub-spoke/aws/README.md 「어느 ArgoCD인가」
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
사용법: argocd-seed.sh [--dry-run] [--from STEP] [--to STEP]

GitOps 저장소를 pull 하는 self-managed ArgoCD 를 부트스트랩한다.
단계는 순서대로 실행되며 각 단계가 다음 단계의 전제다.

  1  helm install argo-cd            (저장소의 values 파일 그대로)
  2  platform AppProject
  3  cluster Secret                  (라벨·이름 공급. "등록"이 아니다)
  4  root Application                (자기 자신을 흡수)

  Access Entry 단계는 self-managed 에 없다. ArgoCD 가 클러스터 안에 있다.
     spoke 클러스터를 붙일 때만 필요하며 그것은 Terraform 소관이다.
  repository Secret 단계도 없다. 저장소가 public 이라 ArgoCD 가 익명으로 읽는다.

필수 환경변수
  GITOPS_REPO_DIR       체크아웃된 GitOps 저장소 경로 (매니페스트의 출처)
  CLUSTER_DIR           seed 할 클러스터 디렉토리 (GITOPS_REPO_DIR 기준 상대경로)
                        예: clusters/dev/eks-ref-dev-an2-main-01

선택 환경변수
  ARGOCD_NAMESPACE      기본 argocd
  ARGOCD_CHART_VERSION  기본 10.9.1        (정확 핀. 올릴 땐 argocd CLI 도 같이)
  ARGOCD_VALUES         기본 bootstrap/argocd-values.yaml   (GITOPS_REPO_DIR 기준 상대경로)
  ARGOCD_RELEASE        기본 argocd

예시
  export GITOPS_REPO_DIR=~/eks-platform-gitops
  export CLUSTER_DIR=clusters/dev/eks-ref-dev-an2-main-01
  ./argocd-seed.sh --dry-run     # 먼저 이것부터 돌린다
  ./argocd-seed.sh
USAGE
}

DRY_RUN=0
FROM_STEP=1
TO_STEP=4

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --from)    FROM_STEP="${2:?--from 에 단계 번호가 필요하다}"; shift 2 ;;
    --to)      TO_STEP="${2:?--to 에 단계 번호가 필요하다}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "알 수 없는 인자: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# 출력
if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_HEAD=$'\033[1;36m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_WARN=''; C_ERR=''; C_HEAD=''; C_OFF=''
fi
step() { printf '\n%s━━ 단계 %s · %s%s\n' "$C_HEAD" "$1" "$2" "$C_OFF"; }
ok()   { printf '%s  ✅ %s%s\n' "$C_OK"   "$1" "$C_OFF"; }
warn() { printf '%s  ⚠️  %s%s\n' "$C_WARN" "$1" "$C_OFF"; }
die()  { printf '%s  ❌ %s%s\n' "$C_ERR"  "$1" "$C_OFF" >&2; exit 1; }
run()  {
  if (( DRY_RUN )); then printf '     [dry-run] %s\n' "$*"; else "$@"; fi
}

# 실행할 단계인지
want() { local s=$1; (( s >= FROM_STEP && s <= TO_STEP )); }

# 사전 점검. 여기서 막는 것이 클러스터에서 반쯤 진행된 상태보다 싸다.
step "preflight" "전제 확인"

for v in GITOPS_REPO_DIR CLUSTER_DIR; do
  [[ -n "${!v:-}" ]] || die "필수 환경변수 $v 가 비어 있다. --help 참조"
done

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-10.9.1}"
ARGOCD_VALUES="${ARGOCD_VALUES:-bootstrap/argocd-values.yaml}"
ARGOCD_RELEASE="${ARGOCD_RELEASE:-argocd}"

# 경로 정규화 (~ 확장은 호출자 셸이 한다. 여기서는 존재만 본다)
[[ -d "$GITOPS_REPO_DIR" ]]        || die "GITOPS_REPO_DIR 이 디렉토리가 아니다: $GITOPS_REPO_DIR"

for c in kubectl helm git; do
  command -v "$c" >/dev/null || die "$c 가 PATH 에 없다"
done
ok "kubectl · helm · git 존재"

# 자기소멸 원칙의 집행. 저장소가 커밋 상태여야 한다.
# ⚠️ dirty인 채로 seed하면 apply된 내용이 저장소 어디에도 없고, root App이 흡수한 순간 selfHeal이
#    그것을 되돌린다. 증상은 "방금 넣은 설정이 사라진다"이고 원인을 가리키지 않는다.
if git -C "$GITOPS_REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  if [[ -n "$(git -C "$GITOPS_REPO_DIR" status --porcelain)" ]]; then
    git -C "$GITOPS_REPO_DIR" status --short | sed 's/^/       /'
    die "GitOps 저장소에 커밋되지 않은 변경이 있다(자기소멸 원칙이 깨진다). 커밋·push 후 다시 실행하라"
  fi
  local_head=$(git -C "$GITOPS_REPO_DIR" rev-parse --short HEAD)
  ok "저장소 clean · HEAD=$local_head"
  if ! git -C "$GITOPS_REPO_DIR" diff --quiet HEAD "@{upstream}" 2>/dev/null; then
    warn "로컬 HEAD 가 upstream 과 다르다. ArgoCD 는 원격을 읽는다. push 했는지 확인하라"
  fi
else
  warn "GITOPS_REPO_DIR 이 git 저장소가 아니다. 자기소멸 원칙을 기계로 확인할 수 없다"
fi

# 매니페스트 3종 존재 확인
PROJECT_FILE="$GITOPS_REPO_DIR/projects/platform.yaml"
CLUSTER_FILE="$GITOPS_REPO_DIR/$CLUSTER_DIR/cluster-secret.yaml"
ROOTAPP_FILE="$GITOPS_REPO_DIR/bootstrap/root-app.yaml"
VALUES_FILE="$GITOPS_REPO_DIR/$ARGOCD_VALUES"
for f in "$PROJECT_FILE" "$CLUSTER_FILE" "$ROOTAPP_FILE" "$VALUES_FILE"; do
  [[ -f "$f" ]] || die "필요한 파일이 없다: $f"
done
ok "매니페스트 3종 + values 존재"

# 저장소가 익명으로 읽히는지. ArgoCD 는 repository Secret 없이 root App 의 repoURL 을 읽으므로
# 저장소가 private 으로 돌아가면 sync 가 조용히 멈춘다(root App 이 Unknown 에 머문다). 그 실패를
# apply 전에 드러낸다. credential.helper 를 비워 이 머신에 캐시된 자격증명이 검사를 통과시키지
# 못하게 한다.
GITOPS_REPO_URL=$(awk '/^ *repoURL:/{print $2; exit}' "$ROOTAPP_FILE")
[[ -n "$GITOPS_REPO_URL" ]] || die "root-app.yaml 에서 repoURL 을 읽지 못했다"
GIT_TERMINAL_PROMPT=0 git -c credential.helper= ls-remote --exit-code --heads "$GITOPS_REPO_URL" >/dev/null 2>&1 \
  || die "저장소를 익명으로 읽지 못한다(private 으로 돌아갔는가): $GITOPS_REPO_URL. ArgoCD 도 못 읽는다"
ok "저장소 익명 읽기 · $GITOPS_REPO_URL"

# 클러스터 도달성. private endpoint라 workbench 밖에서는 여기서 막힌다.
if (( ! DRY_RUN )); then
  kubectl cluster-info >/dev/null 2>&1 \
    || die "클러스터에 닿지 않는다. workbench 에서 실행 중인지, kubeconfig 가 맞는지 확인하라"
  ok "클러스터 도달 · context=$(kubectl config current-context)"
fi

if (( DRY_RUN )); then
  warn "dry-run 모드. 아무것도 바꾸지 않는다"
  warn "검증하지 않는다. ArgoCD CR 은 CRD 라 클라이언트 dry-run 이 discovery API 를 요구한다(오프라인 불가)"
  warn "검증은 실제 실행 때 서버 dry-run 이 한다. 여기서는 '무엇을 어디서 적용하는지'만 본다"
fi

# 1단계: ArgoCD 설치(저장소의 values 그대로)
if want 1; then
  step 1 "helm install argo-cd $ARGOCD_CHART_VERSION"
  run helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
  run helm repo update argo >/dev/null
  # ⛔ --set 을 쓰지 않는다. values 는 저장소 커밋본 하나뿐이어야 한다(자기소멸 원칙).
  run helm upgrade --install "$ARGOCD_RELEASE" argo/argo-cd \
    --namespace "$ARGOCD_NAMESPACE" --create-namespace \
    --version "$ARGOCD_CHART_VERSION" \
    --values "$VALUES_FILE" \
    --wait --timeout 10m
  ok "helm release '$ARGOCD_RELEASE' 적용됨"
fi

# 2·3·4단계: 커밋본을 그대로 apply. 각 단계가 다음의 전제다. 서버 dry-run을 먼저 돌려
# 스키마·권한 문제를 apply 전에 드러낸다.
apply_manifest() {
  local n=$1 label=$2 file=$3
  step "$n" "$label"
  printf '     출처: %s\n' "${file#"$GITOPS_REPO_DIR"/}"
  if (( DRY_RUN )); then
    # ⚠️ dry-run에서는 kubectl을 아예 부르지 않는다. AppProject·Application은 CRD라 kubectl이
    #    RESTMapping을 풀려면 discovery API(/api)를 쳐야 하고, --validate=false로 검증을 꺼도 그
    #    호출은 남는다. 클러스터는 private이므로 VPC 밖(팀원 노트북)에서는 i/o timeout으로 늘
    #    막힌다. dry-run의 역할을 "검증"이 아니라 "무엇을 어디서 적용하는지 보여주기"로 좁히고,
    #    검증은 실제 실행 경로의 --dry-run=server가 한다.
    printf '     %-14s %s\n' "kind/name:" \
      "$(awk '/^kind:/{k=$2} /^metadata:/{m=1} m&&/^  name:/{print k"/"$2; exit}' "$file")"
  else
    # 서버 dry-run. 스키마·admission·권한을 실제로 통과하는지 apply 전에 본다.
    kubectl apply --dry-run=server -f "$file" >/dev/null \
      || die "서버 dry-run 실패. apply 하지 않았다: $file"
    kubectl apply -f "$file" | sed 's/^/     /'
  fi
  ok "$label 적용됨"
}

# ⛔ want 3 && apply_manifest ... 로 쓰지 않는다. set -e는 && 리스트의 앞 명령 실패를 면제하므로
#    조기 종료는 없지만, 그런 줄이 마지막 문장이면 스크립트 종료 코드가 1이 된다. --to 3으로 정상
#    실행한 seed가 호출자(CI·wrapper)에게 실패로 보인다. if 블록은 건너뛰어도 0이다.
if want 2; then apply_manifest 2 "platform AppProject" "$PROJECT_FILE"; fi
if want 3; then apply_manifest 3 "cluster Secret"      "$CLUSTER_FILE"; fi
if want 4; then apply_manifest 4 "root Application"    "$ROOTAPP_FILE"; fi

# 검증. apply 가 성공해도 root App 이 저장소를 읽었는지는 따로 본다.
if (( ! DRY_RUN )) && want 4; then
  step "verify" "흡수 확인"
  cat <<VERIFY
     아래를 사람이 확인한다(자동 판정하지 않는다. 실패 모드가 여러 겹이다):

     1) root App 이 저장소를 실제로 읽었는가
        kubectl -n $ARGOCD_NAMESPACE get application root-app \\
          -o jsonpath='{.status.sync.revision}{"\n"}'
        ⚠️ 값이 'main' 이면 아직 **설정값**이다. 실제 커밋 SHA 여야 pull 성공이다.
           (이 값만 보고 성급히 성공으로 판단하지 않는다)

     2) Synced / Healthy 인가
        kubectl -n $ARGOCD_NAMESPACE get application root-app \\
          -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'

     3) cluster Secret 이 내장 in-cluster 를 대체했는가 (서버 항목이 하나여야 한다)
        argocd cluster list        # 또는 UI 의 Settings → Clusters

     4) UI 접근
        kubectl -n $ARGOCD_NAMESPACE port-forward svc/argocd-server 8080:443
        → https://localhost:8080  (자체 서명 인증서 경고는 정상이다)
        초기 비밀번호:
        kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret \\
          -o jsonpath='{.data.password}' | base64 -d

     ⛔ 마지막으로 **비밀번호를 바꾸고 초기 Secret 을 지운다**(선택이 아니라 완료 조건):

        export ARGOCD_OPTS='--port-forward --port-forward-namespace $ARGOCD_NAMESPACE --insecure'
        argocd login --username admin                        # 프롬프트, 에코 없음
        argocd account update-password 2>/tmp/argocd-pw.err   # 현재 → 신규 → 확인
        kubectl -n $ARGOCD_NAMESPACE delete secret argocd-initial-admin-secret

        ⛔ ARGOCD_OPTS='--core' 로는 update-password 가 실패한다:
             "failed to get issue time: unable to extract token claims"
           --core 는 argocd-server 를 **우회**해 kube-apiserver 로 직접 가므로 세션 토큰이 없다.
           신원이 필요한 작업(비밀번호·계정·토큰)은 --core 로 하지 않는다.
        ⚠️ --insecure 는 **클라이언트** 검증 생략이다(서버 TLS 를 끄는 server.insecure 와 다르다).
           port-forward 주소가 localhost:<random> 이라 인증서 CN 이 맞지 않기 때문이다.
        ⚠️ --port-forward 는 포워더를 CLI 프로세스 안에서 돌려 teardown 마다 broken pipe 가
           stderr 로 나온다. 실패가 아니다. 위처럼 2> 로 프롬프트(stdout)와 분리한다.
        ⚠️ 새 비밀번호는 ^.{8,32}$ 를 만족해야 한다(argocd-cm.passwordPattern 미설정 시 기본값).

     5) 교체 판정 (자동으로 성공을 선언하지 않는다):
        kubectl -n $ARGOCD_NAMESPACE get secret argocd-secret \\
          -o jsonpath='{.data.admin\\.passwordMtime}' | base64 -d; echo   # 시각이 갱신됐는가
        kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret   # NotFound 여야 한다
        교체 후에도 argocd Application 이 Synced 로 남는다. 차트가 argocd-secret 을
           data 없이 렌더하므로 admin.password 는 ArgoCD 소유 필드가 아니다.
VERIFY
fi

printf '\n%s완료.%s\n' "$C_OK" "$C_OFF"
