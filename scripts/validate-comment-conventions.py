#!/usr/bin/env python3
# iac-module-library 의 docs/conventions.md 「주석」과 docs/writing-style.md 2절에서 이식했다.
# 규칙 SSOT 는 그 두 문서다. 여기서 규칙 텍스트를 다시 쓰지 않는다. 기계로 판정 가능한 것만
# 잡는다:
#
#  1. 주석 줄의 좌표: 절 번호 인용 기호, 결정 식별자(D-XX·D25 등), 날짜(YYYY-MM-DD),
#     문서 절 번호("N절"), "실측"·"N차 세션" 같은 사건 서술. 언제 누가 왜 바꿨는지는
#     git blame 과 커밋 메시지가 답한다.
#
#  적용 범위: addons/** · projects/** · clusters/** · bootstrap/** 의 *.yaml, *.sh,
#  저장소 *.md, scripts/*.py, .githooks/*.
#
#  ⛔ 검사 대상은 주석뿐이다. YAML 블록 스칼라(description: | 등) 안의 산문까지 넓히는 안은
#     기각했다 — 그 자리에는 정책 메시지·차트 설명처럼 숫자와 날짜꼴 문자열이 정상적으로
#     들어가고, 넓히면 오탐이 사람을 훅 우회로 몰아간다. 블록 스칼라의 좌표는 리뷰가 잡는다.
#
#  ⚠️ 이 저장소에 .yaml 을 새로 만들 때는 root App 을 함께 생각한다. bootstrap/argocd-app.yaml
#     의 root App 이 `path: .` + `recurse: true` 라 저장소 어디에 두든 매니페스트로 흡수된다.
#     이 스크립트와 훅이 .py 와 확장자 없는 파일인 것은 그래서다.
#
#  실행 (repo 루트에서): python3 scripts/validate-comment-conventions.py [파일...]
#  인자를 안 주면 적용 범위 전체를 스캔한다.

import glob
import re
import sys

COORD_PATTERNS = [
    (re.compile("§"), "절 번호 인용"),
    (re.compile(r"\bD-[A-Z]|\bD\d{2}\b"), "결정 식별자"),
    (re.compile(r"\b20\d{2}-\d{2}-\d{2}\b"), "날짜"),
    (re.compile(r"[0-9]+절"), "문서 절 번호"),
    (re.compile(r"[0-9]+차 세션"), "세션 번호"),
    (re.compile("실측"), "사건 서술('실측')"),
]

# 이 스크립트는 규칙을 검출하느라 금지 문자를 리터럴로 담는다. 검사 대상에서 뺀다.
VALIDATORS = {"scripts/validate-comment-conventions.py"}


def default_targets() -> list[str]:
    targets = set()
    for pattern in (
        "addons/**/*.yaml",
        "projects/**/*.yaml",
        "clusters/**/*.yaml",
        "bootstrap/**/*.yaml",
        "bootstrap/**/*.sh",
        "*.md",
        "scripts/*.py",
        ".githooks/*",
    ):
        targets |= set(glob.glob(pattern, recursive=True))
    return sorted(t for t in targets if t not in VALIDATORS)


def comment_part(line: str) -> str | None:
    """주석 부분만 돌려준다. 주석이 없으면 None.

    .md 는 전체가 산문이라 줄 전체를 주석으로 본다.
    """
    stripped = line.lstrip()
    if stripped.startswith("#"):
        return stripped
    # 인라인 주석. 문자열 안의 #(색상 코드, 셸 $#)은 앞에 공백이 있어야 주석으로 본다.
    m = re.search(r"\s#(?![{!$])(.*)$", line)
    return m.group(0) if m else None


def check_file(path: str) -> list[str]:
    errors = []
    if path in VALIDATORS:
        return errors
    try:
        text = open(path, encoding="utf-8").read()
    except (FileNotFoundError, UnicodeDecodeError, IsADirectoryError):
        return errors
    lines = text.splitlines()

    is_prose = path.endswith(".md")
    for i, line in enumerate(lines, 1):
        c = line if is_prose else comment_part(line)
        if c is None:
            continue
        for pattern, label in COORD_PATTERNS:
            if pattern.search(c):
                errors.append(f"{path}:{i}: 좌표({label}). 지금 성립하는 이유만 남긴다")
    return errors


def main() -> int:
    targets = sys.argv[1:] or default_targets()
    all_errors = []
    for path in targets:
        all_errors.extend(check_file(path))
    if all_errors:
        for e in all_errors:
            print(f"[ERROR] {e}")
        print(f"\n주석 규칙 위반 {len(all_errors)}건")
        return 1
    print(f"주석 규칙 검사 통과: {len(targets)}개 파일")
    return 0


if __name__ == "__main__":
    sys.exit(main())
