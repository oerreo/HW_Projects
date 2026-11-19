# Research Workspace

글로벌 팹리스의 IP design / RTL·HLS / HW engineer로 성장하기 위한 개인 설계·논문 연구 공간.
사용자는 **검토만** 하고, 계획·구현·검증·문서화는 Claude가 직접 수행한다.

## 보드 구조 (Notion과 동일한 3단계)
```
todo/       후보 프로젝트. 프로젝트당 <name>.md 한 장짜리 brief (동기, 범위, 예상 산출물)
progress/   진행 중인 프로젝트. <name>/ 디렉토리 (동시에 1개가 원칙)
done/       완료된 프로젝트. progress/에서 디렉토리째 이동
scripts/    프로젝트 공용 스크립트 (env.sh)
```
- 시작: `todo/<name>.md`를 `progress/<name>/docs/brief.md`로 옮기고 프로젝트 디렉토리를 만든다.
- 완료: 완료 기준(스킬 `milestone-cycle`)을 만족하고 사용자가 확인하면 `progress/<name>/`을 `done/`으로 옮긴다.
- 상태가 바뀌면 Notion 보드의 상태도 같이 바꾼다.
- 새 아이디어가 생기면 진행 중인 프로젝트에 끼워 넣지 말고 `todo/`에 brief로 남긴다.

## 프로젝트 디렉토리 (`progress/<name>/`)
```
docs/     brief.md, plan.md(로드맵, 유일한 계획 원본), log.md(진행 로그), spec/, survey/, diagrams/, viewer/
model/    bit-accurate golden model (C++/Python)
data/     test data와 README(출처, 라이선스, 생성 명령)
rtl/      직접 작성 RTL (SystemVerilog)
hls/      Catapult HLS 소스와 Tcl
tb/       testbench
sim/      시뮬레이션 실행 디렉토리 (산출물은 커밋 제외)
syn/      DC 스크립트와 리포트
fpga/     Vivado Tcl, XDC, PS 소프트웨어 (사용자 실행용)
paper/    논문 원고
```
작업은 항상 해당 프로젝트의 `docs/plan.md`에서 현재 단계와 다음 작업을 확인하고 시작한다.

## 반드시 지킬 것 (상세는 `.claude/rules/`)
0. **표준 흐름** (`project-flow.md`): golden model(Python/C++) -> test data 확보 -> RTL -> RTL sim과 golden 비교 mismatch 0 -> FPGA 검증 환경(Zynq PS/ARM 호스트) -> 보드 검증. gate를 건너뛰지 않는다. 프로젝트는 분야를 바꿔가며 다양한 HW 가속기를 다룬다.
1. **계획 먼저**: 어떤 작업이든 계획을 세우고 `docs/plan.md`에 반영한 뒤 실행한다.
2. **역할 분담**: Fable = 플래너·오케스트레이터·수퍼바이저 / Opus = sub job 실행(`hw-worker`) / Sonnet = 문서 작업(`doc-writer`). 기본 effort는 medium.
3. **머신 부하**: 동시 실행은 최대 2(연구 쪽 작업만 셈), 프로세스당 core 1개. Vivado 합성/구현은 이 머신에서 금지. DC는 사용자가 허락한 시점에만.
3-1. **프로세스 노출 최소화** (`process-privacy.md`): 다른 사용자에게는 어떤 툴이 도는지만 보이게 한다. 작업 디렉토리는 700, 툴은 인자 파일로 실행, 명령행에 프로젝트/모듈/테스트 이름을 넣지 않는다.
4. **RTL vs HLS**: 컨트롤러, top wrapper, 버스 인터페이스 등 control 중심 모듈은 RTL 직접 작성. 알고리즘·데이터패스는 난이도에 따라 Catapult HLS 사용 가능.
5. **기록**: 마일스톤마다 Notion Research 페이지에 정리. GitHub는 사용자가 연결해준 뒤부터 기록.
6. **시각 자료** (`visual-docs.md`): 모듈이 검증을 통과하면 block diagram, data flow, control flow를 Mermaid(필요 시 draw.io)로 남기고, 프로젝트마다 실제 trace를 재생하는 interactive HTML viewer를 둔다.
7. **회사 자산 분리**: 회사 코드/IP(`~/work`의 다른 디렉토리)를 이 연구에 복사하거나 참조하지 않는다. 툴만 사용한다.

## 환경
- 툴 환경: `source /home/theo/work/research/scripts/env.sh <questa|hls|rise>` (스킬 `eda-tools`). 라이선스는 eval 환경, 서버 bm06만 사용(`machine-limits.md`). NC와 DC는 사용자 허락 없이는 쓰지 않는다.
- 보드: Digilent Zybo Z7-20 (XC7Z020-1CLG400C). 비트스트림 생성은 사용자가 Vivado로 직접 수행하므로, Claude는 Tcl 스크립트와 실행 안내까지만 준비한다.
- 응답과 문서는 한국어, 코드와 식별자(module/signal 이름)는 영어.
