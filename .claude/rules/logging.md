# 기록 규칙

## Notion
- 대상: Research 페이지 `https://app.notion.com/p/Research-41a85d190ab2805bbed5fe6d5972928b`
- 페이지의 default template을 쓰면 내부에 database가 포함되도록 되어 있다. 새 항목은 그 template/database 구조를 따른다. 구조를 임의로 바꾸지 않는다.
- 마일스톤 완료, 중요한 설계 결정, 측정 결과가 나올 때마다 정리한다. 절차는 스킬 `research-log`.
- Notion 연결이 안 되어 있으면 프로젝트의 `docs/log.md`에 먼저 쓰고, 연결되면 밀린 항목을 올린 뒤 `synced` 표시를 한다.

## 로컬
- 프로젝트의 `docs/plan.md`: 로드맵과 단계별 상태. 유일한 계획 원본.
- 프로젝트의 `docs/log.md`: 날짜별 진행 로그(한 일, 결과 수치, 결정과 근거, 다음 할 일). 날짜는 절대 날짜.

## GitHub
- 사용자가 remote를 연결해주기 전에는 commit/push를 하지 않는다.
- 연결 후에는 마일스톤 단위로 커밋하고, 커밋 메시지는 영어 conventional commit 형식.
- 라이선스 정보, 계정, 사내 경로(`/Tools/...`의 인증 정보 등)는 저장소에 넣지 않는다.
