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
