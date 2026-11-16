---
name: milestone-cycle
description: Use when starting a session, when asked to continue the research, or when starting a roadmap stage. Defines the plan, dispatch, review, record cycle and the todo/progress/done project board.
---

# 마일스톤 진행 절차

1. **파악**: 프로젝트의 `docs/plan.md`에서 현재 단계와 미완료 항목, 프로젝트의 `docs/log.md` 최근 항목을 읽는다.
2. **계획**: 이번에 끝낼 범위를 sub job으로 나눈다. 각 sub job에 입력, 산출물 경로, 통과 기준을 적어 프로젝트의 `docs/plan.md`에 반영한다. 아키텍처 결정(인터페이스, 비트폭, 파이프라인 단수, RTL/HLS 분담)은 오케스트레이터가 내리고 `docs/spec/`에 남긴다.
3. **분배**: 구현·검증·조사는 `hw-worker`(Opus), 문서는 `doc-writer`(Sonnet). 동시에 최대 2개. 서로 같은 파일을 건드리지 않게 나눈다. brief에는 스펙 파일 경로, 통과 기준, 제한 사항(병렬도, Vivado/DC 금지)을 넣는다.
4. **검수**: 보고를 받으면 로그의 `PASS`와 mismatch 수, 벡터 수를 직접 확인한다. 핵심 RTL은 직접 읽어 본다. 기준 미달이면 같은 agent에게 구체적 실패 내용과 함께 되돌린다.
5. **기록**: 스킬 `research-log`로 로컬 로그와 Notion을 갱신한다.
6. **다음 단계**: 사용자 승인이 필요한 일(DC 실행, GitHub push, 방향 전환)이 아니면 멈추지 않고 다음 sub job으로 넘어간다. 승인이 필요한 일은 요청해 두고 승인과 무관한 작업을 계속한다.

## 단계 완료 기준
- 산출물이 저장소에 있고, 재현 명령이 `scripts/` 또는 Makefile에 있다.
- self-checking 시뮬레이션이 mismatch 0으로 통과했고 그 로그를 오케스트레이터가 확인했다.
- 스펙 문서가 실제 구현과 일치한다.
- 로그에 수치와 조건이 남아 있다.
