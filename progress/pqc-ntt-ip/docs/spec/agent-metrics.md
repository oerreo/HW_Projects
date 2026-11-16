# Agent 설계 흐름 지표

확정일 2026-11-16. P2 시작 전에 고정하며, 이후 정의를 바꾸지 않는다(바꾸면 그 시점과 이유를 여기에 남기고 이전 데이터와 구분한다).
논문의 결합 방향(agent 보조 설계 흐름의 정량 기록)에 쓰는 원자료다. 1인 사례 연구이므로 일반화하지 않고 사례 기록으로 보고한다.

## 기록 단위
sub job 하나 = agent 호출 하나(같은 agent에 되돌려 보낸 재작업은 같은 sub job의 추가 라운드).
원자료는 `docs/agent-log.csv`에 한 줄씩 추가한다.

## 필드
| 필드 | 정의 |
|---|---|
| `id` | plan.md의 sub job ID (예: P2-1) |
| `date` | 절대 날짜 |
| `type` | survey / model / data / rtl / hls / tb / integ / doc |
| `module` | 대상 모듈 또는 산출물 |
| `level` | 계층 (L0~L4, 해당 없으면 빈칸) |
| `model` | 실행 모델 (opus / sonnet / fable) |
| `rounds` | 통과까지의 라운드 수. 1 = 첫 보고가 검수를 그대로 통과 |
| `tokens` | 전 라운드 합계 subagent 토큰 (harness 보고값) |
| `tool_uses` | 전 라운드 합계 |
| `duration_s` | 전 라운드 합계 wall time |
| `accept` | pass / fail / partial. 통과 기준은 plan.md에 사전에 적힌 것만 인정 |
| `sup_defects` | 수퍼바이저(Fable) 검수에서 발견한 결함 수 (agent는 통과라고 보고했으나 실제로는 기준 미달이거나 스펙 위반) |
| `human_interv` | 사용자가 개입한 횟수 (방향 수정, 오류 지적) |
| `spec_issue` | 스펙 자체의 결함이나 모호함 때문에 생긴 라운드 수 (agent 탓이 아닌 것) |
| `note` | 결함의 내용, 실패 원인 한 줄 |

## 규칙
- 통과 기준은 실행 전에 plan.md에 적는다. 사후에 기준을 낮춰 pass로 바꾸지 않는다.
- 수퍼바이저는 최소한 self-checking 시뮬레이션 또는 테스트를 직접 재실행해 `accept`를 판정한다.
- 실패와 재작업도 그대로 기록한다. 지우거나 합치지 않는다.
- 수작업 기준선(같은 일을 사람이 했을 때의 시간)은 측정하지 않으므로 주장하지 않는다. 비교가 필요하면 문헌의 보고값을 출처와 함께 인용한다.

## 파생 지표 (논문 집계용)
- type별, level별 첫 라운드 통과율 = (`rounds` = 1 이고 `accept` = pass) / 전체
- sub job당 평균 라운드, 토큰, 시간
- 수퍼바이저 검출 결함 수와 유형 분포
- RTL 대 HLS: 같은 모듈에 대한 라운드, 토큰, 시간 비교
