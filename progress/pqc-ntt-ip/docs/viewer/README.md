# NTT Schedule Player (`ntt_player.html`)

pqc-ntt-ip v1 의 하드웨어 동작(bfu 1개, 2-bank ping-pong, basemul micro-op)을 golden model trace 로 재생하는 단일 HTML viewer.

## 여는 방법
`docs/viewer/ntt_player.html` 을 브라우저에서 바로 연다(`file://`). 외부 파일, CDN, 네트워크 요청이 없다. 크기 약 240 KB.

## 재생성
```
cd progress/pqc-ntt-ip/model && make vectors          # 필요할 때만 (기본 SEED=1)
cd ../docs/viewer/tools
python3 build_viewer.py                                # dump 프로그램 빌드(g++ 1회) + 실행 + HTML 생성
python3 check_viewer.py                                # 데이터 / 상태 재구성 / 외부 참조 검사 (node 있으면 engine 검사 포함)
node check_render.mjs ../ntt_player.html build/check_expected.json <OUTDIR>   # 선택: headless Chrome 렌더 검사 + 스크린샷
```
`tools/build/` 는 생성물이다(`.gitignore`). `check_render.mjs` 는 Chrome 1개를 띄우므로 다른 무거운 작업과 동시에 돌리지 않는다.

## 데이터 출처
| 입력 | NTT / INTT | BASEMUL | trace 출처 |
|---|---|---|---|
| random | `model/vectors` manifest 의 `trace_case` (case 6, random_0, seed 1) | 같은 case 의 `mul_a`, `mul_b` | `model/vectors/hw_{ntt,intt,basemul}_trace_<algo>.txt` 그대로 |
| simple | case 2 `impulse_1_at_0` (f[0] = 1) | a = b = case 5 `all_one` | `tools/dump_viewer_trace` 출력 |

- `tools/dump_viewer_trace.cpp` 는 `model/include` 의 공개 API(`hw_ntt_poly`, `hw_intt_poly`, `hw_basemul_poly`, `dump_bfu_trace`, `dump_basemul_trace`, `bfu_mul`, `mod_add_hw`, `mod_sub_hw`, ROM 함수)만 쓴다. `model/` 은 수정하지 않는다.
  - trace 는 model 의 dump 함수로 같은 형식으로 쓴다. random 입력의 dump 결과가 `model/vectors` 의 trace 12개 파일과 같은지 `build_viewer.py` 가 매번 확인한다.
  - `aux.json`: ROM(zeta, gamma, K2), S, S^-1, basemul program, bfu 내부값(CT 의 t = mul(b, z), GS 의 s, d, m = mul(d, z), 모두 `hw::bfu` 와 같은 함수 호출로 얻고 x, y 재현을 assert), 입력, 기준 출력(`ntt`, `intt`, `multiply_ntts`), layer 별 기대 상태(NTT 는 기준 NTT 의 layer 상태, INTT 는 기준 INTT layer L 상태 * 2^-(L+1)).
- viewer 의 JavaScript 는 NTT 나 모듈러 연산을 하지 않는다. hex 디코딩, 인덱싱, trace write 재적용만 한다.

### 내장 데이터 구성 (JSON 약 190 KB)
- `sched.ntt`, `sched.intt`: layer, len, rd/wr bank, addr0, addr1, zeta 주소, mode. 2 입력 x 4 ALGO 의 trace 에서 모두 같음을 확인하고 연산당 1벌만 저장.
- `pool`: 12-bit 값 배열을 3자리 hex 문자열로 저장하고 참조 번호로 공유(176 참조, 71 고유 배열).
  - NTT / INTT 의 a, b, x, y, t (GS 는 s, d, m) 는 4 ALGO 에서 같아 1벌. ALGO 별로 다른 것은 z(ROM 값)뿐.
  - BASEMUL 은 MONT12 / K2RED 가 서로 다르고, BARRETT 와 SHIFTADD 는 값이 같아 pool 에서 공유된다.
- basemul 의 출처/목적지 이름은 줄마다 저장하지 않고 ALGO 별 program(5 op 또는 7 op)으로 저장한다(모든 줄이 program 과 같은지 빌드 때 확인).
- 각 op 의 식 문구(`program_text`)는 `build_viewer.py` 에 있고 model 의 program 서명이 알려진 두 가지와 다르면 빌드가 실패한다.

## 화면
- **컨트롤 바**: 연산 / ALGO / 입력 선택, 처음, 한 step 뒤, 재생/정지, 한 step 앞, 끝, 속도(1 ~ 1000 step/s), scrubber, `step k / N`.
  키보드: space 재생/정지, 좌우 화살표 1 step, shift + 좌우 layer 경계(BASEMUL 은 계수 쌍 경계), Home / End.
  step k 는 k 번째 bfu 호출까지 실행한 상태다(step 0 = 초기 상태). ALGO 나 입력을 바꾸면 같은 step 을 유지하므로 변형끼리 같은 시점을 비교할 수 있다.
- **메모리**: bank0, bank1 각 16 x 16 (행 = 주소 상위 4비트, 열 = 하위 4비트), 값은 hex 3자리, 색은 값 크기(단일 색상 16단계).
  R(실선 테두리 + R 표지) = 이번 step read, W(점선 테두리 + W 표지) = 이번 step write, 흐림 = write bank 에서 이번 layer 에 아직 쓰지 않은 셀(BASEMUL 은 bank0 에서 아직 c 를 쓰지 않은 셀). 각 bank 머리에 READ / WRITE 표시. 셀 위에 마우스를 올리면 주소와 값.
- **bfu**: CT / GS 데이터 경로 SVG(mul, +, -, /2)와 현재 값. 식 줄: zeta 주소 i, zeta = 17^BitRev7(i), ROM 값, t = mul(b, z) = b*zeta, x, y, 쓰는 주소. S != 1 이면 S 와 ROM 보정(zeta*S^-1) 관계 한 줄. 같은 zeta 주소의 4 ALGO ROM 값 비교.
- **basemul micro-op** (BASEMUL 선택 시): operand 레지스터 A0 A1 B0 B1, 임시 R0 (R1), ROM gamma, ROM K2 의 현재 값, 쌍의 op 표(출처, 목적지, 값, 그 op 까지의 식).
- **스케줄**: layer 칩(진행 막대, 누르면 그 layer 첫 step), layer / len / group / j / j + len / zeta 주소, 256 계수 축 위에 현재 layer 의 butterfly 128개를 호로 그림(완료 / 남음 / 현재). BASEMUL 은 계수 쌍 128개 막대.
- **요약**: 현재 연산, ALGO, 입력, bfu 호출 진행 수, S, S^-1, K2, ALGO x 연산별 총 bfu 호출 수(trace 줄 수). cycle, 면적, 주파수는 측정 전이라 표시하지 않는다.

## 확인한 것 (2026-11-16)
| 검사 | 도구 | 수 | 불일치 |
|---|---|---|---|
| dump 프로그램 trace == `model/vectors` trace (random) | build_viewer.py | 12 파일 | 0 |
| 내장 JSON == 원본 trace (모든 step 의 모든 필드, ROM, 입력, 기대 출력) | check_viewer.py `json` | 20,846 | 0 |
| step 수: NTT 896, INTT 896, BASEMUL 640 (S = 1) / 896 (S != 1) | `count` | 24 | 0 |
| Python 독립 재생: read 값 == bank 상태, layer 마다 256 주소 write, layer 끝 상태 == model 기준 layer 상태, basemul operand == latch 값 | `replay` | 37,088 | 0 |
| 마지막 bank == golden (random: `ntt_out` / `intt_out` / `mul_out.hex`, simple: `ntt_out` / `intt_out.hex`, basemul 은 model `multiply_ntts`) | `final` | 24 | 0 |
| viewer engine(HTML 의 script 그대로, Node) `stateAt` / `writtenAt` 를 모든 위치에서 순차 + 섞은 순서(scrub)로 Python 재생 해시와 비교 | check_engine.mjs | 82,064 | 0 |
| 외부 URL, `<link>`, `src=`, `href`, `@import`, `fetch`, XHR | `external` | 8 | 0 |
| headless Chrome: 24 run 표본 위치의 렌더된 512 셀 값, R/W 강조 수, 화살표 20 step 연속, shift+화살표, space 재생, 페이지 오류 없음, 390 px 폭 가로 넘침 없음, 라이트/다크 | check_render.mjs | 8,573 | 0 |

engine 검사가 실제로 버그를 잡는지: snapshot 재적용 시작을 1 step 늦춘 변이(28,448 불일치), 빈 write mask 조건 변이(32 불일치)로 확인했다.

## 확인하지 못한 것과 한계
- 렌더링은 headless Chrome(Linux)에서만 확인했다. Firefox, Safari, 실제 휴대폰은 보지 않았다. 스크린샷은 사람이 눈으로 몇 장 봤을 뿐 픽셀 비교는 없다.
- 키보드는 합성 이벤트로 확인했다. 실제 사용자의 포커스 상태(예: select 에 포커스가 있으면 단축키를 넘긴다)는 직접 눌러 보지 않았다.
- 1000 step/s 에서의 프레임 유지 여부는 측정하지 않았다(렌더는 바뀐 셀만 DOM 갱신, 프레임당 1회).
- step 은 bfu 호출 단위다. cycle 단위(LATENCY, layer 사이 대기)는 RTL 시뮬레이션 trace 가 생기면 확장한다.
- simple 입력의 BASEMUL(a = b = all_one) 기대 출력은 `model/vectors` 에 파일이 없어 model 의 `multiply_ntts` 결과와 비교했다.
