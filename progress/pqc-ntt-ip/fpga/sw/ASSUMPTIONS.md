# PS 드라이버가 가정한 L4 동작과 확정 상태

작성 2026-11-17 (P5 준비), 갱신 2026-11-17 (P5-1, L4 RTL `rtl/l4/` 작성 후).
`docs/spec/l4_axi.md` "확정한 동작" 절이 기준이다. 아래는 드라이버(`pqc_ntt.c`), 테스트 프로그램(`main.c`), 레지스터 모델(`test/reg_model.c`)이 처음에 가정한 동작과 그 확정 결과다.
번호(An)는 소스 주석의 참조 번호와 같다.

상태: **확정** 스펙(l4_axi.md)과 RTL(`rtl/l4/pqc_ntt_csr.sv`, `axil_slave.sv`)이 이 동작이고 L4 TB가 검사한다. **변경** 처음 가정과 다르게 확정되어 드라이버/모델을 고쳤다. **미확정** 스펙 밖이거나 보드에서만 확인할 수 있다.

## 스트림 접근 (DIN / DOUT)

| 번호 | 상태 | 동작 | 근거 / 비고 |
|---|---|---|---|
| A1 | 확정 | LOAD는 CTRL에 start(op=LOAD)를 먼저 쓰고 DIN을 256번 쓴다. `in_ready`가 아닐 때의 DIN 쓰기는 버리고 ERR.bit1(`din_notready`)을 세운다. | l4_axi.md. RTL: DIN 쓰기 cycle에 `s_ready`가 0이면 handshake 없음. |
| A2 | 확정 | `in_ready` = `ntt_core.s_ready_o`(LOAD 중 1). 드라이버는 DIN 쓰기 전마다 STATUS를 읽는다. | |
| A3 | 확정 | DIN 쓰기 한 번 = handshake 한 번. AXI 쓰기 채널을 잡아 두지 않는다. WSTRB는 무시하고 모든 쓰기를 32비트 전체로 본다. | l4_axi.md. L4 TB가 WSTRB를 random으로 넣어 검사. |
| A4 | 확정 | DOUT 읽기는 `out_valid = 1`이면 현재 계수를 돌려주고 pop, 아니면 0을 돌려주고 ERR.bit2(`dout_notvalid`), pop 없음. pop은 AR 요청 하나에 정확히 한 번(R 채널이 막혀도 반복되지 않음). | RTL `axil_slave`: 읽기는 R 슬롯이 비어 있을 때 한 번 수행하고 결과를 R 레지스터에 둔다. |

## 제어와 상태

| 번호 | 상태 | 동작 | 근거 / 비고 |
|---|---|---|---|
| A5 | 확정(보충) | `done_sticky`는 `done_o`에서 1, CTRL 쓰기마다 0. 같은 cycle에 겹치면 CTRL 쓰기(clear)가 우선한다. 예외: 정의되지 않은 op로 start를 쓰면 `done_sticky`는 변하지 않는다(A9). | l4_axi.md "확정한 동작". L4 TB가 done cycle에 CTRL 쓰기를 정확히 맞춰 검사. |
| A6 | 확정 | STATUS.busy = `ntt_core.busy_o`(start 수락 다음 cycle부터 1). 완료 판정은 `done_sticky`. | |
| A7 | 확정 | LOAD, UNLOAD도 op이다(busy, done_sticky, CYCLES 갱신). 두 op의 CYCLES는 비교하지 않는다. | l4_axi.md. L4 TB는 코어 포트에서 잰 값과 같은지만 본다. |
| A8 | 확정 | busy 중 start는 무시하고 ERR.bit0(`start_busy`). 진행 중인 op는 영향 없다. | L4 TB: LOAD 중, NTT 중 start 후 결과와 CYCLES 확인. |
| A9 | 변경 | 정의되지 않은 op(5..7)로 start: 아무 동작 없이 ERR.bit3(`bad_op`). busy, done_sticky 모두 변하지 않는다. busy 중이면 bit0과 bit3이 함께 선다. 드라이버는 이런 값을 쓰지 않는다(`PQC_ERR_ARG`). | 처음 가정은 "ERR 변화 없음". `reg_model.c`, `test_driver.c`, `main.c`(`err_bad_op`, `bad_op_keeps_status`) 수정. |
| A10 | 확정 | BASEMUL의 CTRL.bank는 무시된다(a = bank0, b = bank1, 결과 bank0). | L4 TB가 bank 비트를 random으로 쓴다. |
| A11 | 확정 | STATUS.result_bank는 done cycle에 갱신되어 다음 done까지 유지. LOAD/UNLOAD = bank, NTT/INTT = bank ^ 1, BASEMUL = 0. | |
| A12 | 확정 | CYCLES = `ntt_core`가 start_i를 수락한 cycle부터 `done_o` cycle까지의 수. NTT/INTT 897 + 7(1 + L), BASEMUL 128 n (L + 1) + 3. done cycle에 latch되고 그 다음 cycle부터 읽힌다(`done_sticky`와 같은 시점). op 진행 중 읽으면 이전 op 값. | CSR은 start를 레지스터 없이 같은 cycle에 코어로 보낸다. L4 TB가 모든 op에서 식과 코어 포트 실측값을 대조. |
| A13 | 확정 | VERSION[31:16] 고정 ID = 0x4E54. 빌드 구분용 CONFIG 레지스터(0x1C) 추가: impl, share_addsub, rom_out_reg, pre_reg, mul_reg, red_pipe, out_reg, fclk_mhz. | l4_axi.md 레지스터 맵. `main.c`가 CONFIG 줄을 출력하고 pipeline 합이 VERSION.BFU_LATENCY와 같은지 검사. |
| A14 | 확정(보충) | ERR은 sticky, W1C, 읽기 부작용 없음. 같은 cycle에 같은 비트의 set과 W1C가 겹치면 set이 우선(오류를 잃지 않음). ERR이 서도 op를 멈추지 않는다. | set 우선은 스펙에 없던 결정(RTL에서 정함). L4 TB가 겹침을 cycle 단위로 맞춰 검사. |
| A15 | 변경 | DIN의 [31:12]는 무시. 받아들여진 단어의 [11:0]이 q 이상이면 그대로 저장하고 ERR.bit4(`din_range`). 버려진 DIN 쓰기(A1)는 bit1만 세운다. 드라이버는 LOAD 전에 256개를 검사해 q 이상이면 `PQC_ERR_ARG`(유지). DOUT [31:12]는 0. | 처음 가정은 "하드웨어 검사 없음". 버려진 쓰기에 bit4를 세우지 않는 것은 RTL에서 정한 해석. |
| A16 | 확정 | abort / soft reset 없음(v1). 중단된 LOAD/UNLOAD는 `pqc_ntt_recover()`가 끝낸다. | l4_axi.md. |

## 주소 맵과 버스

| 번호 | 상태 | 동작 | 근거 / 비고 |
|---|---|---|---|
| A17 | 일부 확정 | 정의되지 않은 offset(0x20 이상, 4 KB 창 안): 읽기 0, 쓰기 무시, 응답 OKAY(확정). 주소 비트 [1:0]은 무시. base 0x43C0_0000, 범위 4 KB는 빌드 선택(`create_project.tcl`과 헤더가 같은 값, `check_regs.py` 비교)이며 스펙 항목이 아니다(미확정). | |
| A18 | 미확정 | GP0 영역은 device(또는 strongly-ordered) 메모리 매핑이라 읽기의 반복, 병합, 추측 실행이 없다고 가정. | 보드에서만 확인 가능. |
| A19 | 확정 | NTT/INTT는 두 bank를 모두 써서 입력 bank 내용이 사라진다. 계수 도메인 두 피연산자의 곱은 NTT 결과를 PS로 한 번 꺼냈다가 다시 넣는다. 한쪽이 이미 NTT 도메인이면 왕복이 없다. | arch.md "L3 결과 반영". L4 TB가 두 순서를 모두 검사. |
| A20 | 확정 | 쓰기 전용 레지스터(CTRL, DIN) 읽기는 0. | |
| A21 | 확정 | reset 직후 STATUS, CYCLES, ERR 모두 0(VERSION, CONFIG 제외). | L4 TB: 시작과 중간 reset 후 검사. |
| A22 | 확정 | `pqc_ntt_axi_top`: int parameter(`ALGO`, `PRE_REG`, `MUL_REG`, `RED_PIPE`, `OUT_REG`, `SHARE_ADDSUB`, `ROM_OUT_REG`, `IMPL`, `FCLK_MHZ`, `C_S_AXI_ADDR_WIDTH`), 포트 `clk`, `rst_n`, `s_axi_<ch>_i/_o`. block design은 Verilog shell `fpga/vivado/src/pqc_ntt_axi_bd.v`. | module reference가 SV top을 받지 못한다는 점은 미검증(Vivado 미실행). |
| A23 | 확정 | `done_sticky = 1`이 보이는 읽기에서 result_bank와 CYCLES는 이미 그 op의 값이다. | result_bank는 done cycle, done_sticky와 CYCLES는 그 다음 cycle부터. |
| A24 | 드라이버 결정 | 타임아웃은 STATUS 읽기 횟수(기본 100만 회)로 센다. | 스펙과 무관. |
| A25 | 미확정 | 같은 IP에 대한 접근이 PS가 낸 순서대로 완료된다고 가정. RTL은 읽기와 쓰기 채널을 독립으로 처리하므로, PS가 앞선 쓰기의 B 응답을 받기 전에 다음 읽기를 내면 읽기가 먼저 수행될 수 있다. 같은 cycle에 수행된 읽기는 그 cycle의 쓰기 전 상태를 본다. | 드라이버는 모든 쓰기 뒤에 B를 기다리는 PS 동작(device 메모리)에 의존. 보드에서만 확인 가능. |

## RTL과 레지스터 모델의 대조
- L4 TB(`+TRACE=<file>`)가 수행된 모든 AXI 접근(cycle, 주소, 값)을 파일로 남기고, `test/t_replay`가 같은 접근을 `reg_model.c`에 재생해 모든 읽기 값을 비교한다(`make test`의 7단계). STATUS의 `in_ready`/`out_valid`는 RTL read-ahead에 따른 cycle 차이가 있어 "RTL 1이면 모델도 1"만 요구한다.
- 이 대조를 위해 모델의 완료 시점을 RTL과 같게 맞췄다: busy와 result_bank는 done cycle부터, done_sticky와 CYCLES는 그 다음 cycle부터 보인다.
