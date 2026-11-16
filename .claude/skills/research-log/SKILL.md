---
name: research-log
description: Use when a milestone finishes, a design decision is made, or a measurement result comes out and progress must be recorded to the project log and the Notion Research page.
---

# 진행 기록

## 1. 로컬 로그 (항상 먼저)
프로젝트의 `docs/log.md` 맨 위에 항목을 추가한다.

```markdown
## YYYY-MM-DD: <한 줄 제목>  [notion: pending]
- 단계: <plan.md의 단계 ID, 예: P2>
- 한 일: ...
- 결과: <수치와 조건. 예: mod_red exhaustive 2^24 벡터, mismatch 0, Questa 2024.2>
- 결정: <무엇을 왜>
- 다음: ...
```

같이 프로젝트의 `docs/plan.md`의 단계 상태를 갱신한다.

## 2. Notion
대상: Research 페이지 `https://app.notion.com/p/Research-41a85d190ab2805bbed5fe6d5972928b`

1. Notion MCP 툴이 연결돼 있는지 확인한다. 안 돼 있으면 로컬 로그만 남기고, 턴 마지막에 사용자에게 `/mcp`에서 "claude.ai Notion" 인증이 필요하다고 한 번 알린다.
2. 처음 접근할 때 Research 페이지와 default template, 내부 database의 속성(schema)을 읽는다. 읽은 구조는 이 파일 아래 "확인된 구조"에 적어 다음부터 재사용한다.
3. 프로젝트 페이지가 없으면 default template으로 하나 만든다(프로젝트당 1개). 진행 항목은 그 안의 database에 행으로 추가한다.
4. 행 하나 = 로그 항목 하나. 제목, 날짜, 단계, 상태, 요약을 database 속성에 맞춰 넣고, 본문에 결과 수치와 결정 근거를 적는다.
5. 올린 뒤 프로젝트의 `docs/log.md`의 해당 항목 표시를 `[notion: synced]`로 바꾼다. `pending`이 밀려 있으면 오래된 것부터 올린다.

문서 작성 자체는 `doc-writer`(Sonnet)에 맡기고, 넘겨줄 사실과 수치는 오케스트레이터가 로그에서 확인한 것만 준다.

## 올리지 않는 것
- 라이선스·계정 정보, 사내 경로의 인증 내용, 회사 프로젝트 관련 내용.
- 측정하지 않은 수치.

## 확인된 구조 (2026-11-16)
- Research 페이지 안에 inline database `Projects` (data source `collection://33085d19-0ab2-8277-b388-87c4aac09b46`).
  - 속성: `이름`(title), `태그`(select: To Do / Progressed / Done / Architecture Rationale), `작성일`(date), `숫자`(number). `생성일`, `수정일`은 자동.
  - 로컬 보드와 대응: `todo/` = To Do, `progress/` = Progressed, `done/` = Done. 디렉토리를 옮기면 `태그`도 바꾼다.
  - 새 프로젝트 행은 default template(`b9185d190ab2837e852f01435e105067`)을 `template_id`로 지정해 만든다. template이 페이지 안에 inline database `Process`를 만든다(비동기, 생성 후 fetch로 data source URL 확인).
  - 이름이 비었거나 "프로젝트 명"인 행은 사용자의 예시이므로 건드리지 않는다.
- 프로젝트 페이지 안의 `Process` database: 진행 기록을 행으로 추가한다.
  - 속성: `이름`, `태그`, `작성일`, `숫자`(기록 순번으로 사용).
  - `태그` 선택지와 용도: `사전 지식 및 계획`(개요, 계획, 배경 지식), `논문 및 알고리즘 정리`(서베이, 알고리즘 설명), `Architecture Rationale`(블록별 구조 결정과 근거, 전용 template `5d785d190ab2825c971b8167547d919f` 사용), `진행 예정`, `진행 중`(작업 로그), `검증 및 평가`(시뮬레이션, FPGA, 합성 결과), `완료`, `잘한 점/유지할 점`(회고).
  - 진행 중이던 항목이 끝나면 `태그`를 `완료`로 바꾼다.
- 프로젝트별 URL
  - pqc-ntt-ip: 페이지 `https://app.notion.com/p/41a85d190ab2818a8a1cc62e7fc35f66`, Process data source `collection://b1b85d19-0ab2-8273-a78d-878cb7ae11d3`
- 페이지 본문은 Notion-flavored Markdown. 처음 쓰기 전에 `notion://docs/notion-flavored-markdown-spec`을 notion fetch로 읽는다.
