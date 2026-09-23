// include-check: root App 의 directory.include 가 실제 파일을 잡는지 오프라인으로 판정한다.
//
// ArgoCD repo-server 와 같은 매처를 같은 방식으로 부른다: gobwas/glob 을 구분자 없이
// Compile 하고, 저장소 루트 기준 상대 경로에 Match 한다. 그래서 `*` 도 `/` 를 넘는다.
// ⛔ 매칭을 정규식이나 fnmatch 로 다시 쓰지 않는다. gobwas 는 `x/**/y` 에서 앞뒤 리터럴이
// `/` 를 공유해도 매치하는 등 셸 glob 과 다르게 굴고, 재구현은 그 차이를 놓친다.
// ⚠️ gobwas/glob 버전은 ArgoCD go.mod 의 것과 같아야 한다(go.mod 에 핀).
//
// 판정 두 가지. 하나라도 걸리면 exit 1 이다.
//  1. include 의 최상위 `{a,b,...}` 대안 하나하나가 파일을 1개 이상 잡는다.
//     0건이면 그 대안이 가리키려던 매니페스트가 root App 에서 조용히 빠진다.
//  2. 대안이 가리키는 최상위 디렉토리 안에서 매니페스트로 보이는 파일은 include 전체에 걸린다.
//     "매니페스트로 보인다"는 ArgoCD 와 같은 기준이다: 이름이 manifestFile 정규식에 맞고
//     내용에 apiVersion:·kind:·metadata: 가 모두 있다. skip 마커가 있거나 exclude 에 걸리면 뺀다.
//
// 파일 목록은 git ls-files 다. ArgoCD 가 보는 것은 커밋된 파일이라 미추적 파일은 판정에서 뺀다.
// 경로는 어디서 부르든 저장소 루트 기준이다(시작할 때 git 최상위로 이동한다).
//
// 실행 (repo 루트에서): go run -C scripts/include-check . [root-app.yaml 경로]
// 별도 모듈이라 `go run ./scripts/include-check` 는 저장소 루트에 go.mod 가 없어 실패한다.
package main

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"

	"github.com/gobwas/glob"
	"gopkg.in/yaml.v3"
)

// ArgoCD reposerver 의 manifestFile·skipFileRenderingMarker 와 같은 값이다.
var manifestFile = regexp.MustCompile(`^.*\.(yaml|yml|json|jsonnet)$`)

const skipFileRenderingMarker = "+argocd:skip-file-rendering"

type rootApp struct {
	Spec struct {
		Source struct {
			Path      string `yaml:"path"`
			Directory struct {
				Recurse bool   `yaml:"recurse"`
				Include string `yaml:"include"`
				Exclude string `yaml:"exclude"`
			} `yaml:"directory"`
		} `yaml:"source"`
	} `yaml:"spec"`
}

func main() {
	appFile := "bootstrap/root-app.yaml"
	if len(os.Args) > 1 {
		appFile = os.Args[1]
	}
	if err := run(appFile); err != nil {
		fmt.Fprintln(os.Stderr, "include-check:", err)
		os.Exit(1)
	}
}

func run(appFile string) error {
	top, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return fmt.Errorf("git 저장소 안에서 실행한다: %w", err)
	}
	if err := os.Chdir(strings.TrimSpace(string(top))); err != nil {
		return err
	}
	raw, err := os.ReadFile(appFile)
	if err != nil {
		return err
	}
	var app rootApp
	if err := yaml.Unmarshal(raw, &app); err != nil {
		return fmt.Errorf("%s 파싱 실패: %w", appFile, err)
	}
	dir := app.Spec.Source.Directory
	// 이 검사는 source.path 가 저장소 루트일 때만 ArgoCD 의 상대 경로와 같다.
	if p := strings.TrimSuffix(app.Spec.Source.Path, "/"); p != "." && p != "" {
		return fmt.Errorf("source.path 가 %q 다. 저장소 루트(.)일 때만 판정한다", p)
	}
	if dir.Include == "" {
		return fmt.Errorf("%s 에 directory.include 가 없다", appFile)
	}

	include, err := glob.Compile(dir.Include)
	if err != nil {
		return fmt.Errorf("include 컴파일 실패(ArgoCD 도 이 패턴을 쓰지 못한다): %w", err)
	}
	var exclude glob.Glob
	if dir.Exclude != "" {
		if exclude, err = glob.Compile(dir.Exclude); err != nil {
			return fmt.Errorf("exclude 컴파일 실패: %w", err)
		}
	}

	files, err := trackedFiles()
	if err != nil {
		return err
	}
	// ArgoCD 가 include 를 대 보기 전에 거르는 조건(확장자·recurse·exclude)을 먼저 적용한다.
	var candidates []string
	for _, f := range files {
		base := f[strings.LastIndex(f, "/")+1:]
		if !manifestFile.MatchString(base) {
			continue
		}
		if !dir.Recurse && strings.Contains(f, "/") {
			continue
		}
		if exclude != nil && exclude.Match(f) {
			continue
		}
		candidates = append(candidates, f)
	}

	failed := false
	scopes := map[string]bool{}
	for _, alt := range alternatives(dir.Include) {
		g, err := glob.Compile(alt)
		if err != nil {
			return fmt.Errorf("대안 %q 컴파일 실패: %w", alt, err)
		}
		n := 0
		for _, f := range candidates {
			if g.Match(f) {
				n++
			}
		}
		fmt.Printf("%3d  %s\n", n, alt)
		if n == 0 {
			fmt.Printf("::error::include 대안 %q 이 파일을 하나도 잡지 않는다. 그 경로의 매니페스트는 root App 에서 빠진다\n", alt)
			failed = true
		}
		if s := literalTopDir(alt); s != "" {
			scopes[s] = true
		}
	}

	for _, f := range candidates {
		top := f
		if i := strings.Index(f, "/"); i >= 0 {
			top = f[:i]
		}
		if !scopes[top] || include.Match(f) {
			continue
		}
		body, err := os.ReadFile(f)
		if err != nil {
			return err
		}
		if bytes.Contains(body, []byte(skipFileRenderingMarker)) {
			continue
		}
		if bytes.Contains(body, []byte("apiVersion:")) &&
			bytes.Contains(body, []byte("kind:")) &&
			bytes.Contains(body, []byte("metadata:")) {
			fmt.Printf("::error::%s 는 매니페스트로 보이는데 include 에 걸리지 않는다. root App 이 적용하지 않는다\n", f)
			failed = true
		}
	}

	if failed {
		return fmt.Errorf("판정 실패")
	}
	fmt.Println("include 판정 통과")
	return nil
}

func trackedFiles() ([]string, error) {
	out, err := exec.Command("git", "ls-files", "-z").Output()
	if err != nil {
		return nil, fmt.Errorf("git ls-files 실패: %w", err)
	}
	var files []string
	for _, f := range strings.Split(string(out), "\x00") {
		if f != "" {
			files = append(files, f)
		}
	}
	sort.Strings(files)
	return files, nil
}

// alternatives 는 패턴 전체가 `{...}` 하나일 때 최상위 쉼표로 나눈다. 아니면 패턴 하나로 본다.
// 안쪽의 `{}`·`[]` 는 깊이로 건너뛰어 대안 내부의 쉼표를 자르지 않는다.
func alternatives(p string) []string {
	if !strings.HasPrefix(p, "{") || !strings.HasSuffix(p, "}") {
		return []string{p}
	}
	inner := p[1 : len(p)-1]
	var out []string
	depth, start := 0, 0
	for i, r := range inner {
		switch r {
		case '{', '[':
			depth++
		case '}', ']':
			depth--
			if depth < 0 {
				// `{a}{b}` 처럼 바깥 괄호가 전체를 감싸지 않는 모양이다.
				return []string{p}
			}
		case ',':
			if depth == 0 {
				out = append(out, inner[start:i])
				start = i + 1
			}
		}
	}
	out = append(out, inner[start:])
	return out
}

// literalTopDir 는 대안의 첫 경로 조각이 와일드카드 없는 디렉토리 이름이면 그것을 돌려준다.
func literalTopDir(alt string) string {
	i := strings.Index(alt, "/")
	if i <= 0 {
		return ""
	}
	seg := alt[:i]
	if strings.ContainsAny(seg, "*?[]{}\\!") {
		return ""
	}
	return seg
}
