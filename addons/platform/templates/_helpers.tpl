{{/*
클러스터 이름. addon Application 이름의 접두사이자 ALBC·Karpenter 의 clusterName 이다.
⚠️ 실제 EKS 클러스터명이어야 한다. 별칭이면 ALBC 가 조용히 틀린다.
*/}}
{{- define "platform.name" -}}
{{- required "cluster.name 이 비었다(cluster Secret 이름)" .Values.cluster.name -}}
{{- end -}}

{{- define "platform.server" -}}
{{- required "cluster.server 가 비었다(cluster Secret server)" .Values.cluster.server -}}
{{- end -}}

{{/*
staged addon 의 버전. versions.<addon>.<tier> 를 읽는다.
tier 가 prd·nonprd 가 아니면 렌더를 실패시켜 그 클러스터의 부모가 ComparisonError 로 멈춘다.
어느 티어에도 속하지 않은 클러스터가 조용히 빠지는 것보다 낫다.
사용: {{ include "platform.staged" (list . "karpenter") }}
*/}}
{{- define "platform.staged" -}}
{{- $root := index . 0 -}}
{{- $addon := index . 1 -}}
{{- $row := required (printf "versions.%s 가 없다" $addon) (index $root.Values.versions $addon) -}}
{{- required (printf "tier 는 prd·nonprd 둘뿐이다(받은 값 %q)" $root.Values.cluster.tier) (index $row $root.Values.cluster.tier) -}}
{{- end -}}

{{/*
addon Application 의 식별 라벨과 sync-wave. 라벨 계약은 README 「부모 Application — 클러스터마다 하나」가 갖는다.
wave 는 이 헬퍼 하나가 어노테이션과 라벨에 같이 찍는다. 따로 적으면 wave 를 바꿀 때 한쪽만 고친다.
사용: {{- include "platform.meta" (list . "aws-lbc" "1") | nindent 2 }}
⚠️ 출력이 annotations 맵으로 끝난다. 템플릿에서 이 줄 바로 뒤에 들여쓰기 4칸으로 적은 어노테이션은
   그 맵에 이어진다(kyverno 계열의 compare-options).
*/}}
{{- define "platform.meta" -}}
{{- $root := index . 0 -}}
{{- $addon := index . 1 -}}
{{- $wave := index . 2 -}}
labels:
  platform.addon: {{ $addon }}
  platform.cluster: {{ include "platform.name" $root }}
  platform.wave: {{ $wave | quote }}
annotations:
  argocd.argoproj.io/sync-wave: {{ $wave | quote }}
{{- end -}}
