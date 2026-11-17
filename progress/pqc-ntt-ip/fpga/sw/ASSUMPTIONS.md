# PS 드라이버가 가정한 L4 동작 (l4_axi.md 초안 기준)

작성 2026-11-17 (P5 준비). `docs/spec/l4_axi.md` 는 초안이며, 아래는 그 문서가 정하지 않았거나 모호해서 **드라이버(`pqc_ntt.c`), 테스트 프로그램(`main.c`), 레지스터 모델(`test/reg_model.c`)이 임의로 가정한 동작**이다.
번호(An)는 소스 주석의 참조 번호와 같다. L4 RTL 스펙을 확정할 때 각 항목을 "채택 / 변경 / 기각"으로 정하고, 바뀐 항목은 드라이버와 레지스터 모델을 함께 고친다.

분류: **[결정 필요]** 스펙에 없고 RTL 설계가 정해야 하는 것. **[해석]** 스펙 문장의 한 가지 해석. **[제안]** 스펙에 추가를 권하는 것.

## 스트림 접근 (DIN / DOUT)

| 번호 | 분류 | 가정 | 근거 / 대안 |
|---|---|---|---|
| A1 | 결정 필요 | LOAD 는 **CTRL에 start(op=LOAD) 를 먼저 쓰고**, 그 뒤 DIN 을 256번 쓴다. start 전에 쓴 DIN 은 버퍼링되지 않고 버려지며 ERR.bit1 이 선다. | 스펙에 순서가 없다. 대안(DIN FIFO 선적재 후 start)은 RTL에 FIFO가 필요하다. |
| A2 | 해석 | `in_ready` 는 LOAD start 후 유한 cycle 안에 1이 되고, 256번째 단어를 받을 때까지 1을 유지한다(`ntt_ctrl` 의 `s_ready_o` 를 그대로 노출). 드라이버는 DIN 쓰기 전마다 STATUS 를 읽어 `in_ready` 를 확인한다. | 쓰기 1회당 STATUS 읽기 1회가 추가된다(성능 측정 대상이 아니므로 허용). |
| A3 | 결정 필요 | DIN 쓰기 한 번 = 핸드셰이크 한 번. 쓰기가 받아들여지는 cycle 에 `in_ready = 1` 이면 수락. AXI 쓰기 채널을 잡아 두지 않는다(스펙의 v1 기본값). WSTRB 는 항상 4'b1111 로 쓴다고 가정하고, 부분 strobe 의 동작은 정하지 않았다. | 부분 strobe 를 무시할지, 전체 쓰기로 볼지, SLVERR 로 할지 RTL이 정해야 한다. |
| A4 | 해석 | DOUT 읽기는 `out_valid = 1` 일 때 현재 계수를 돌려주고 다음 계수로 넘어간다(pop). `out_valid = 0` 일 때 읽으면 **값 0** 을 돌려주고 ERR.bit2 가 서며 pop 하지 않는다. pop 직후 다음 계수가 준비될 때까지 `out_valid` 가 잠시 0일 수 있다. | 반환값은 스펙에 없다(0으로 가정, 드라이버는 값에 의존하지 않음). |

## 제어와 상태

| 번호 | 분류 | 가정 | 근거 / 대안 |
|---|---|---|---|
| A5 | 해석 | `done_sticky` 는 `ntt_core.done_o` 에서 1이 되고, **CTRL 에 대한 모든 쓰기**(start = 0 포함)에서 0이 된다. 같은 cycle 에 done 과 CTRL 쓰기가 겹치는 경우는 드라이버가 만들지 않는다(busy 중 CTRL 을 쓰지 않음). | 스펙 문구 "CTRL 쓰기 때 clear" 를 문자 그대로 읽음. 대안: start 가 수락될 때만 clear. 그 경우 `main.c` 의 `done_sticky_clear_by_ctrl` 검사가 FAIL 하므로 함께 바꾼다. 겹침 시 우선순위(set 우선 / clear 우선)는 RTL이 정해 스펙에 적어야 한다. |
| A6 | 해석 | STATUS.busy 는 `ntt_core.busy_o` 이며 start 수락 다음 cycle 부터 1이다. 드라이버는 op 완료를 **busy 가 아니라 done_sticky** 로 판단한다(start 직후 busy 가 아직 0인 구간을 완료로 오인하지 않기 위해). busy 는 새 op 를 시작하기 전 "idle" 확인에만 쓴다. | |
| A7 | 해석 | LOAD, UNLOAD 도 op 이다. 진행 중 busy = 1, 끝나면 done_sticky = 1, CYCLES 갱신. 이 두 op 의 CYCLES 는 PS 의 AXI 접근 간격을 포함하므로 기대값과 비교하지 않는다. | `ntt_ctrl` 의 동작과 같다. |
| A8 | 해석 | busy 중 start = 1 쓰기는 무시되고 ERR.bit0 이 선다. 진행 중인 op(LOAD 대기 중 포함)는 영향 없이 계속된다. 드라이버는 start 전에 busy 를 확인해 이 경우를 만들지 않는다(`PQC_ERR_BUSY`). | `ntt_ctrl` 은 busy 중 start 를 무시한다. |
| A9 | 결정 필요 | 정의되지 않은 op 인코딩(5..7)으로 start 하면 **아무 일도 일어나지 않는다**(busy, done, ERR 모두 변화 없음). 드라이버는 이런 값을 쓰지 않는다. 쓰면 done 대기가 타임아웃 된다. | `ntt_ctrl` 은 assertion 만 있고 동작이 없다. **제안**: ERR.bit3 "illegal op" 추가. |
| A10 | 해석 | BASEMUL 의 CTRL.bank 는 무시된다(a = bank0, b = bank1, 결과 bank0). 드라이버는 0을 쓴다. | `ntt_l2_pkg::op_e` 주석. |
| A11 | 해석 | STATUS.result_bank 는 done 시점에 갱신되어 다음 done 까지 유지된다. 기대값: LOAD/UNLOAD = bank, NTT/INTT = bank ^ 1, BASEMUL = 0. 드라이버는 매 op 후 이를 확인하고 다르면 `PQC_ERR_STATE`. | `ntt_ctrl` 머리 주석. |
| A12 | 결정 필요 | CYCLES 는 done 시점에 latch 되는 값이며, **`ntt_core` 가 start_i 를 수락한 cycle 부터 done_o cycle 까지**의 수로 arch.md "L2 결과 반영" 의 실측식과 같다: NTT/INTT = 897 + 7(1 + L), BASEMUL = 128 n (L + 1) + 3 (L = BFU_LATENCY, n = 5 또는 7). op 진행 중 CYCLES 를 읽으면 이전 op 의 값이다. | CSR 이 start pulse 를 한 단 레지스터로 만들면 1 cycle 차이가 날 수 있다. 카운터의 시작/끝 시점을 L4 스펙에 cycle 단위로 적어야 한다. 드라이버의 기대식은 `pqc_ntt_expected_cycles()` 한 곳. |
| A13 | 결정 필요 | VERSION[31:16] 의 고정 ID 값은 스펙에 없어 **0x4E54** 로 가정했다(`PQC_NTT_VERSION_ID_VALUE`). BFU_LATENCY 필드 = bfu `LATENCY` = PRE_REG + MUL_REG + RED_PIPE + OUT_REG. | **제안**: 비교 빌드를 로그만으로 구별할 수 있게 VERSION 또는 별도 CONFIG 레지스터에 IMPL(RTL/HLS), SHARE_ADDSUB, ROM_OUT_REG, 파이프라인 단별 값, FCLK 정보(또는 빌드 ID)를 넣는다. 지금은 ALGO 와 L 만 보인다. |
| A14 | 해석 | ERR 은 sticky, W1C. 읽기에 부작용이 없다. ERR 비트가 서도 진행 중인 op 를 멈추지 않는다. 드라이버는 ERR 을 스스로 지우지 않고, op 끝에 0이 아니면 `PQC_ERR_HW` 를 돌려준다. | |
| A15 | 결정 필요 | DIN 의 [31:12] 는 무시된다. 값이 q 이상인지는 하드웨어가 검사하지 않는다(`ntt_core` 의 시뮬레이션 assertion 뿐). 드라이버가 LOAD 전에 256개를 모두 검사해 q 이상이 있으면 아무 레지스터도 건드리지 않고 `PQC_ERR_ARG`. DOUT 의 [31:12] 는 0으로 읽힌다. | **제안**: ERR 에 "범위 밖 계수" 비트를 둘지 검토. |
| A16 | 결정 필요 | **abort / soft reset 이 없다.** LOAD 를 256개 전에 멈추면 IP 는 계속 busy 다. 드라이버의 `pqc_ntt_recover()` 는 남은 DIN 을 0으로 채우거나 남은 DOUT 을 읽어 버려서 op 를 끝낸다. NTT/INTT/BASEMUL 이 끝나지 않는 고장은 PL reset(비트스트림 재적재 또는 FCLK_RESET0_N) 외에는 복구할 수 없다. | **제안**: CTRL 에 soft reset(또는 abort) 비트 추가. |

## 주소 맵과 버스

| 번호 | 분류 | 가정 | 근거 / 대안 |
|---|---|---|---|
| A17 | 결정 필요 | base 0x43C0_0000, 범위 4 KB(`PQC_NTT_DEFAULT_BASEADDR`, `PQC_NTT_ADDR_RANGE`, `create_project.tcl` 과 같은 값, `check_regs.py` 가 비교). 0x1C 이상의 정의되지 않은 offset 은 읽기 0, 쓰기 무시, 응답 OKAY. 정렬되지 않은 접근은 하지 않는다. | SLVERR 를 쓸지 RTL이 정한다. |
| A18 | 해석 | 부작용이 있는 읽기는 DOUT 뿐이다. PS 쪽은 GP0 영역을 device(또는 strongly-ordered) 메모리로 매핑해 읽기의 반복, 병합, 추측 실행이 없다고 가정한다(Xilinx standalone BSP 의 기본 translation table). 보드에서 확인하지 않았다. | |
| A19 | 해석 | NTT/INTT 는 두 bank 를 모두 쓰므로 끝난 뒤 입력 bank 의 내용은 정의되지 않는다. 그래서 다항식 곱은 NTT(f) 를 PS 로 한 번 꺼냈다가 다시 넣는다(`pqc_ntt_place_operands()`, 이 함수만 바꾸면 되게 모아 둠). | `ntt_core` 머리 주석. **제안**: NTT 결과 bank 선택 또는 bank copy op 가 생기면 왕복(UNLOAD 256 + LOAD 256)이 없어진다. |
| A20 | 해석 | 쓰기 전용 레지스터(CTRL, DIN)를 읽으면 0. 드라이버는 읽지 않는다. | |
| A21 | 해석 | reset 직후: busy = 0, done_sticky = 0, result_bank = 0, CYCLES = 0, ERR = 0. `main.c` 는 시작 시 ERR 을 출력하고 지운 뒤 진행한다(이전 실행의 잔여 ERR 대비). | |
| A22 | 결정 필요 | `pqc_ntt_axi_top`(rtl/l4)의 형태: parameter 는 **int**(`ALGO` 0..3, `PRE_REG`, `MUL_REG`, `RED_PIPE`, `OUT_REG`, `SHARE_ADDSUB`, `ROM_OUT_REG`, `C_S_AXI_ADDR_WIDTH`), 포트는 `clk`, `rst_n`, `s_axi_<ch>_i/_o`(AXI4-Lite 전체 신호, AWPROT/ARPROT 포함). block design 은 Verilog shell `fpga/vivado/src/pqc_ntt_axi_bd.v` 를 module reference 로 쓴다(SV top 과 enum parameter 를 module reference 가 받지 못한다고 알고 있으나 미검증). | L4 RTL 이 다른 이름을 쓰면 shell 의 인스턴스만 고친다. |
| A23 | 해석 | STATUS 에서 done_sticky = 1 이 보이는 읽기에서 result_bank 는 이미 그 op 의 값이고, 그 뒤 CYCLES 읽기는 그 op 의 값이다. | done 과 같은 cycle 에 세 값을 갱신하면 성립. |
| A24 | 해석 | 타임아웃은 시간 대신 STATUS 읽기 횟수(기본 100만 회, `PQC_NTT_POLL_LIMIT_DEFAULT`)로 센다. 가장 긴 op(BASEMUL, n = 7, L = 5)가 5,379 cycle 이고 AXI 읽기 한 번이 수십 cycle 이라 여유가 크다. | 타이머 의존을 없애 호스트 모델과 보드에서 같은 코드가 돈다. |
| A25 | 해석 | 같은 IP 에 대한 AXI 접근 순서는 PS 가 낸 순서대로 완료된다(device 메모리 순서 보장). 예: CTRL 쓰기 뒤의 STATUS 읽기는 CTRL 쓰기가 반영된 뒤 처리된다. | 보드에서 확인하지 않았다. |

## 스펙 문서에 대한 의견 (요약)
- 확정 시 cycle 단위 타이밍 표가 필요하다: start pulse 와 `ntt_core.start_i` 의 관계, busy/done_sticky/result_bank/CYCLES 갱신 cycle, done 과 CTRL 쓰기 충돌 시 우선순위(A5, A12, A23).
- 오류 처리의 빈칸: illegal op(A9), 범위 밖 계수(A15), 부분 WSTRB(A3), 정의되지 않은 주소의 응답(A17), abort 수단(A16).
- VERSION 이 비교 빌드를 구별하기에 부족하다(A13).
- arch.md 의 CSR 절은 "P5에서 확정"이라고 되어 있고 hierarchy.md 의 L4 행은 "AXI4-Lite(CSR) + AXI4-Stream(in/out)" 이라 v1(AXI4-Lite 만)과 다르다. 확정 때 두 문서를 맞춰야 한다.
