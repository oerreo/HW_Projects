# 시각 자료 규칙

기록은 글과 표에 더해 그림과 interactive viewer를 갖춘다(2026-11-16 사용자 요청).

## 다이어그램
- 종류: block diagram(계층과 포트), data flow(데이터가 지나는 경로와 비트폭), control flow(FSM, 스케줄, 타이밍).
- 기본은 Mermaid: `.md` 안에 코드 블록으로 넣는다. GitHub와 Notion에서 그대로 렌더링되고 diff가 읽힌다.
- Mermaid로 표현이 안 되는 것(비트폭이 붙은 상세 데이터패스, 파이프라인 단 배치, 메모리 포트 배선)은 draw.io(`.drawio` 원본 + 내보낸 `.svg`를 함께 커밋, 스킬 `drawio:drawio`).
- 위치: 프로젝트의 `docs/diagrams/`. 스펙 문서(`docs/spec/*.md`)에서 참조하거나 직접 포함한다.
- 시점: 모듈 또는 계층이 G4(golden 대비 mismatch 0)를 통과하면 그 모듈의 다이어그램을 만든다. 구현 전에 그린 그림은 "계획"으로 표시하고 통과 후 실제 구현에 맞춰 갱신한다.
- 그림의 신호 이름, 비트폭, latency는 RTL과 일치해야 한다. RTL이 바뀌면 그림도 같은 커밋에서 고친다. 확인하지 않은 구조를 그리지 않는다.
- FSM과 타이밍은 가능하면 실제 trace나 RTL에서 뽑아 그린다(손으로 추정한 파형 금지, 추정이면 추정이라고 표시).

## Interactive viewer
- 프로젝트마다 `docs/viewer/`에 단일 HTML 파일(외부 의존성 없이 자체 포함, `file://`로 열림)로 만든다.
- player를 갖춘다: play/pause, step 앞뒤, 속도, 위치 이동(scrubber). 한 step = 하드웨어의 한 동작 단위(예: butterfly 하나, micro-op 하나, cycle 하나).
- 보여주는 데이터는 golden model 또는 RTL 시뮬레이션의 **실제 trace**다. viewer 안에서 알고리즘을 다시 구현해 값을 만들지 않는다(trace를 생성 스크립트로 JSON에 넣는다). 생성 명령을 `docs/viewer/README.md`에 적는다.
- 상위 계층이 추가되면 viewer도 확장한다(L0 연산 단위 -> butterfly -> 코어 스케줄 -> AXI 트랜잭션).
- 사용자가 볼 수 있게 Artifact로도 게시한다(게시 전 스킬 `artifact-design` 로드). 저장소의 HTML이 원본이다.

## 담당
- Mermaid/draw.io 다이어그램: `doc-writer`(Sonnet). 원자료는 RTL과 스펙.
- viewer(코드가 본체): `hw-worker`(Opus).
