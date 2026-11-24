# System Op Player (`sys_player.html`)

llm-pim-soc 시스템(L4 top + 드라이버 + 실행기)이 token 하나를 만드는 동안 낸 IP op와 ARM kernel 호출을 순서대로 재생하는 단일 HTML viewer다(S4-8).

## 여는 방법
`docs/viewer/sys_player.html`을 브라우저에서 바로 연다(`file://`). 외부 파일, 폰트, CDN, 네트워크 요청이 없다. 크기 약 240 KB(내장 JSON 약 210 KB). 라이트/다크는 OS 설정을 따르고 "테마" 버튼으로 바꿀 수 있다.

## 보여 주는 것
- **step 하나 = 시스템의 동작 하나**: 드라이버가 낸 IP op 하나(gemv_acc GEMV, pim RUN과 그 명령 목록, attn ATTN / KVW, vec RMSNORM / SWIGLU / ACTQ / ARGMAX) 또는 ARM에서 실행된 kernel 호출 묶음(연속한 embed, rope, add 호출을 한 step으로 묶음).
- **장면 4개**(모두 run P, mask ff, 위치 1의 token):

| 장면 | sys_fwd run | 빌드 | 모델 | 메모리 모델 | step (IP op + ARM) | token CYCLES 합 |
|---|---|---|---|---|---|---|
| 1 | `p_full` | P (`sys_p_top`) | 260K | latency 1, stall 없음 | 164 (148 + 16) | 23,471 |
| 2 | `a_m1` | A (`sys_a_top`) | 260K | latency 1, stall 없음 | 158 (142 + 16) | 57,058 |
| 3 | `a_m2` | A | 15M | latency 1, stall 없음 | 201 (182 + 19) | 2,012,157 |
| 4 | `p_stall` | P | 260K | TB random 모델 PROF 2 (50 % stall, R latency 1..60, B 1..40), MAXD 1 | 164 (148 + 16) | 34,488 |

- 화면
  - **block diagram**: PS/ARM, GP0 -> `axil_xbar`, slot 0..3(빌드에 없는 slot은 점선), HP0..HP3(빌드 A의 HP2는 tie-off), DDR. 현재 IP와 이번 op에서 beat가 오간 HP 포트(R/W beat 수 표시), AXI-Lite 접근 수를 강조한다. 구조는 `docs/spec/system.md` 1.3절, `docs/diagrams/l4_sys_top.md` 1.2~1.4절과 같다.
  - **현재 step**: IP, op, kernel(KSPLIT 분류), layer, 크기(descriptor 레지스터에서 읽은 필드), CYCLES, RD_STALL, WR_STALL, 시작 tick(CTRL GO 쓰기), busy 해제 확인 tick, AXI-Lite rd/wr 수, HP 포트별 R/W beat, pim RUN이면 그 RUN 전에 push된 명령 목록(WRGB / MACAB, push 시점의 kernel).
  - **token 타임라인**: op별 CYCLES를 길이로 한 막대(kernel 종류별 색 + 글자 기호 + 범례). 가로축은 "CYCLES 누적"(op 사이 간격 없음)과 "시뮬레이션 tick"(시작 tick 위치, 드라이버의 AXI-Lite 시간이 간격으로 보임) 중 선택. 아래에 현재 step 앞뒤 3개를 이름과 cycle로 보여 준다.
  - **kernel 종류별 표**: op 수와 CYCLES의 현재 step까지 누적과 token 합, token 비율, RD_STALL / WR_STALL 합.
  - **player**: 장면 선택, 처음 / 한 step 뒤 / 재생·정지 / 한 step 앞 / 끝, 속도(1~30 step/s), scrubber. 키보드: space 재생/정지, 좌우 화살표 1 step, Home / End.
- 화면 위에 "RTL 시뮬레이션 값, latency 1 메모리 모델(stall 장면은 TB random 모델), ARM 시간 0, 보드 값 아님"을 표시한다.

## trace 출처
RTL 시스템 TB `tb/sys_top/tb_sys_fwd.sv`(Questa, 100 MHz TB clock, 1 tick = 1 cycle)에서 시스템 프로그램(`fpga/sys/sw`, 변경 없음)이 DPI-C로 RTL을 구동한 run의 trace만 쓴다. viewer 안에서는 값을 계산하지 않는다.

- `+VTRACE=<file>`(S4-8에서 TB에 추가, 형식은 `tb/sys_top/hal_dpi.c` 헤더): kernel 호출(`K`, 실행기의 `hal_ctx`), op 시작(`S`, CTRL GO 쓰기 직전의 HP beat 누적값과 descriptor 레지스터 16개), busy 해제(`E`), CYCLES / RD_STALL / WR_STALL / ERR 읽기(`R`), pim 명령 push(`P`), 프로그램 로그의 SYS / MODEL / KSPLIT / RUN / CHECK 줄(`L`).
  - kernel 이름: `tb/sys_top/hal_cache_dpi.c`가 `fpga/sys/test/hal_cache.c`를 이름만 바꿔 포함하고 `hal_ctx`를 trace로 먼저 보낸다(`sys_main_dpi.c`와 같은 방식, 원본 파일은 변경 없음).
  - HP beat: `tb_sys_fwd.sv`의 export 함수 `sv_mem_beats`(각 HP 메모리 모델의 `n_rd_beat` / `n_wr_beat`).
- run: `sim/tests/sys_fwd.cfg`의 `p_full`, `a_m1`, `a_m2`, `p_stall`(이 4개 run만 `+VTRACE`를 켠다). 산출물 `sim/sys_fwd/v_<label>.txt`, `c_<label>.txt`, `<label>.log`(커밋 제외).
- 생성 스크립트가 trace에서 하는 일: 이벤트를 op로 묶기, 누적 카운터의 차(beat, AXI-Lite 접근 수), token 시작 기준 tick, 레지스터 필드 해석(`fpga/sys/sw/ipregs.h`), 합계·누적·비율. layer는 kernel 호출 순서에서 위치마다 rmsnorm 호출 수로 정한다(2l, 2l+1번째 rmsnorm이 layer l, 2L번째 이후는 final). 빌드 P의 attention op에서는 이것이 AT_LAYER 레지스터와 같은지 확인한다.
- kernel 분류는 실행기의 KSPLIT 분류를 따른다: pim RUN은 그 RUN 전에 push된 첫 MACAB의 kernel, KVW는 attn, 빌드 A의 ARGMAX는 cls GEMV의 `argmax_en`에 융합되어 별도 op가 없다(그 GEMV step에 표시).

## 재생성
```
# 1. trace (Questa, 4 run, 약 30 s; T, ONLY는 환경변수로 넘긴다)
export T=sys_fwd ONLY='^(p_full|a_m1|a_m2|p_stall)$'
./sim/run.sh
# 2. HTML 생성 + 대조 검사 (Python 3 표준 라이브러리만)
cd docs/viewer/tools && python3 build_viewer.py      # sys_player.html, build/data.json, build/check.txt
# 3. 선택: 정적 검사 + headless Chrome 렌더 검사 (Node >= 22, Chrome 1개)
node check_render.mjs                                # 결과는 표준출력, 스크린샷은 build/shots/*.png
```
`tools/build/`는 생성물이다(커밋 제외). `a_m2`는 `data/third_party/models/stories15M.bin`, `tokenizer.bin`이 필요하다(`data/README.md`).

## 확인한 것 (2026-11-23)
| 검사 | 도구 | 결과 |
|---|---|---|
| run P의 KSPLIT 17개 분류마다 CYCLES, RD_STALL, WR_STALL, op 수 == trace op 합 (4 장면) | build_viewer.py | 차이 0 |
| run P의 KSPLIT cyc 합 == trace op CYCLES 합 == 위치별 token 합의 합: 94,004 / 228,792 / 8,050,140 / 68,618 | build_viewer.py | 일치 |
| 프로그램 전체: slot별 CYCLES / RD_STALL / WR_STALL / op 수 == `SYSTB STALL` 줄 (4 slot x 4 run) | build_viewer.py | 일치 |
| `+VTRACE`의 CYCLES 읽기 == `+CYCTRACE` 파일 (slot, ctrl, 값; 594 / 712 / 728 / 298 줄) | build_viewer.py | 일치 |
| HP beat: op 사이에 beat 없음, 포트별 op beat 합 == `AXI_MEM` 줄 (4 포트 x 4 run) | build_viewer.py | 일치 |
| 빌드 P attention op의 AT_LAYER == 호출 순서로 정한 layer | build_viewer.py | 차이 0 |
| 외부 참조(URL, link, src, @import, url(), fetch, XHR) 없음(SVG namespace 문자열 1개만), 내장 JSON == build/data.json, 페이지 script `node --check` | check_render.mjs | 통과 |
| headless Chrome: 4 장면의 모든 step(687개)에서 step 표시, CYCLES/stall 문구, 강조된 IP·HP·GP0 box, 표 강조 행이 데이터와 일치; 키보드(좌우, Home, End, space), 재생, tick 모드; 페이지 오류 없음; 400 px / 1300 px, 라이트 / 다크에서 가로 넘침 없음 | check_render.mjs | 2,784 검사, 불일치 0 |

## 한계
- 모든 수치는 RTL 시뮬레이션 값이다. 메모리는 HP 포트마다 TB의 AXI 메모리 모델(latency 1 또는 random stall)이고, 실제 HP 포트, interconnect, DDR 컨트롤러는 들어 있지 않다. 보드 측정값이 아니다.
- ARM 실행 시간은 TB가 모델링하지 않아 0이다(`tb/sys_top/plat_dpi.c`). ARM step은 순서만 의미가 있고, "시뮬레이션 tick" 축의 간격은 AXI-Lite 접근(레지스터 설정과 STATUS polling) 시간뿐이다.
- 시작 tick은 CTRL GO 쓰기 직전, busy 해제 tick은 드라이버가 polling으로 busy 0을 읽은 시점이라 IP 내부의 정확한 시작·끝과 수 cycle 차이가 날 수 있다. 길이는 IP의 CYCLES 레지스터 값이다.
- AXI-Lite 접근 수는 같은 slot의 이전 op 마지막 읽기 뒤부터 이 op의 마지막 읽기까지다(설정 쓰기, STATUS polling, CYCLES/stall 읽기 포함). pim RUN 뒤의 FIFO level 확인 읽기는 다음 RUN에 들어간다.
- 위치 1의 token 하나만 넣었다. 다른 위치나 mask는 생성 스크립트의 `SCENES`를 바꾸면 된다(해당 run에 `+VTRACE`가 있어야 함).
- 렌더링은 headless Chrome(Linux)에서만 확인했다. Firefox, Safari, 실제 휴대폰, 실제 키보드 포커스는 보지 않았다.
