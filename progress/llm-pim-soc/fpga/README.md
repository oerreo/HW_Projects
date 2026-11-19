# fpga/: Zybo Z7-20 ARM baseline (S3)

Zynq PS(ARM Cortex-A9, bare-metal)에서 C golden model(`model/src`)을 그대로 돌려 판(F, Q, H)별 token당 시간과 kernel별 시간을 UART로 출력하는 프로그램이다. 이 수치가 kernel 우선순위와 Amdahl 추정(`docs/spec/measure.md`)의 기준이 된다.
이 디렉토리는 **사용자가 자기 환경에서 실행**하는 스크립트와 PS 소프트웨어다. 준비한 서버에는 ARM cross compiler, Vivado, Vitis, XSCT, 보드가 없어 실행하지 않았다.

## 현재 상태 (2026-11-18)
- 확인한 것: 같은 소스를 호스트 플랫폼 계층(`plat_host.c`)으로 PC(gcc 8.5, x86-64와 `-m32`)에서 빌드해 두 모델, 세 판, 세 실행(E, T, P)이 PC 기대값과 일치(호스트 테스트 23항목 fail=0, `HOSTTEST RESULT: PASS`, 오케스트레이터 재실행 [측정, PC x86-64, 2026-11-18], 비교 12,304개씩 mismatch 0 [기존 기재, 이번 로그에서 개수 재확인 안 함]). H판 형식은 K12V8(S2b 결정)이며 기대값 헤더를 이 형식으로 다시 생성했다. H판은 float를 쓰지 않는다. Q판의 보드 bit 일치는 newlib libm이 glibc와 같은 결과를 내야 성립하며 미확인이다. 결함 주입, 로그 파서, 배열 변환 왕복, XSCT 스크립트 스텁 검사.
- 확인하지 않은 것: ARM에서의 컴파일과 실행, 모든 Xilinx API와 CP15 접근, Vitis 동작. 목록은 맨 아래 "미검증 항목".
- ARM 측정값은 아직 없다. 아래 출력 예시는 전부 호스트(x86)에서 만든 것이다.

## 디렉토리
| 경로 | 내용 |
|---|---|
| `sw/src/main.c` | 진입점. BEGIN/END, 빌드 정보, 모델 두 개 실행 |
| `sw/src/bench.c`, `bench.h` | 모델 하나의 측정: 데이터 검사, 판 생성, 실행 E/T/P, 정합성 비교 |
| `sw/src/prof.c`, `prof.h` | lap probe, H용 kernel hook(행렬 구분) |
| `sw/src/fq_prof.c` | F, Q forward를 단계 사이 probe와 함께 옮겨 적은 것(`model/src`와 bit 일치를 매 실행 확인) |
| `sw/src/plat.h` | 플랫폼 계층: 시간, UART, 캐시, DDR 이미지, 모델 메모리 |
| `sw/src/plat_xil.c` | Xilinx standalone 구현(Xilinx 헤더는 이 파일에만) |
| `sw/src/plat_host.c` | 호스트 테스트 구현(보드 빌드에 넣지 않음) |
| `sw/src/out.c`, `out.h` | 로그 한 줄 출력(printf 없음, 64비트 정수와 소수 3자리) |
| `sw/src/lmhash.c`, `lmhash.h` | FNV-1a hash(logits, 양자화 가중치). PC 생성기와 공유 |
| `sw/src/expect.h`, `exp.c` | 기대값 구조체와 포함 |
| `sw/src/bcfg.h` | 빌드 옵션(주소, 실행 선택) |
| `sw/expect/exp_m1.h`, `exp_m2.h` | PC 기대값(생성물, 커밋 대상: token id, hash, RoPE 표. 가중치나 tokenizer 내용은 없음) |
| `sw/gen/m1_data.c` | stories260K checkpoint와 tokenizer의 C 배열(생성물, **커밋 제외**) |
| `sw/tools/gen_expect.c`, `m1.cfg`, `m2.cfg` | 기대값 생성기와 설정(판 목록, prompt, 위치 수) |
| `sw/tools/bin2c.py` | 바이너리를 C 배열로 |
| `sw/tools/parse_log.py` | UART 로그를 표와 CSV로 |
| `sw/xsct_build.tcl` | Vitis classic XSCT: platform, app 생성(-O2, -O3), 다운로드와 실행 |
| `sw/test/` | 호스트 테스트(`Makefile`, `run.sh`, `stub_check.tcl`, `rt.c`, `xilstub/`) |
| `results/` | 사용자가 돌려준 UART 로그를 두는 곳 |

`model/src`는 수정하지 않고 그대로 컴파일한다(XSCT 스크립트가 app의 `src/`로 복사, 호스트 테스트는 직접 컴파일).

## 준비물
- Vitis classic 2019.2 ~ 2023.2(XSCT). 2024.1 이후는 아래 "Vitis Unified" 절차.
- XSA: PL을 쓰지 않으므로 **PS7에 DDR과 UART1이 켜진 Zynq-7000 설계라면 어떤 XSA든 된다**. CPU 클럭은 XSA의 PS7 설정을 따른다(Zybo board preset이면 667 MHz, 로그의 `CLK`로 확인).
  - 재사용: `progress/pqc-ntt-ip` 빌드의 XSA(`progress/pqc-ntt-ip/fpga/vivado/build/<NAME>/reports/pqc_bd_wrapper.xsa`, 그 프로젝트 README의 "2. 빌드와 리포트"로 생성). 그 설계의 PL(NTT IP)은 프로그래밍하지 않으며(`BIT` 인자를 주지 않음), `ps7_post_config`가 PS-PL level shifter를 켜도 이 프로그램은 PL에 접근하지 않는다.
  - 새로 만들 경우: Vivado에서 Zybo Z7-20 board part로 프로젝트를 만들고 block design에 ZYNQ7 Processing System 하나만 넣어 board preset 적용(Run Block Automation), M_AXI_GP0와 FCLK를 꺼도 된다. wrapper 생성 후 bitstream 없이 `write_hw_platform -fixed -file ps_only.xsa`(2019.2 이상). 이 절차는 실행해 보지 않았다.
- 데이터: `sh data/scripts/fetch.sh`(프로젝트 최상위에서). 15M의 `tokenizer.bin`은 라이선스 미확인이라 저장소와 ELF에 넣지 않고, 사용자가 받은 파일을 JTAG로 DDR에만 올린다.
- 호스트 도구: `python3`(배열 변환), `gcc`와 `make`(기대값 재생성이나 호스트 테스트를 할 때만).
- 보드: Zybo Z7-20, micro USB 1개(PROG/UART), 부팅 모드 점퍼 **JTAG**. 시리얼 115200 8N1, flow control 없음.

## 실행 순서
아래 `<repo>`는 프로젝트 최상위(`progress/llm-pim-soc`)이다.

### 1. 데이터와 생성물
```
cd <repo>
sh data/scripts/fetch.sh               # 처음 한 번, 체크섬 검증 포함
make -C fpga/sw/test data              # fpga/sw/gen/m1_data.c (260K 배열, 약 3.8 MB 텍스트)
```
- 기대값 헤더(`fpga/sw/expect/`)는 저장소에 있다. 다시 만들지 않는다. `make -C fpga/sw/test gen`은 `model/src`가 바뀌었을 때 연구 서버에서만 실행한다(PC libm이 다르면 Q판 기대값이 달라질 수 있다).

### 2. 소프트웨어 빌드 (Vitis classic, XSCT)
```
xsct <repo>/fpga/sw/xsct_build.tcl XSA=<file.xsa>
```
| 인자 | 값 | 기본 |
|---|---|---|
| `XSA` | 하드웨어 플랫폼 | 필수 |
| `WS` | workspace | XSA 옆 `vitis_ws_lmb/` |
| `BUILDS` | 최적화 수준 목록. 수준마다 app 하나(`lmbase_o2`, `lmbase_o3`) | `"O2 O3"` |
| `FPU` | `-mfpu` 값 `neon` 또는 `vfpv3` | `neon` |
| `STACK`, `HEAP` | 스택, 힙 크기(아래 "메모리") | `0x10000`, `0x10000` |
| `DDRLEN` | linker에 주는 DDR 영역 길이(0x0010_0000부터) | `0x0FF00000` |
| `RUN` | 1이면 JTAG 다운로드와 실행 | 0 |
| `RUNOPT` | 실행할 빌드 | `O2` |
| `M2` | 1이면 RUN 때 15M 이미지도 DDR에 적재 | 1 |
| `CK`, `TK` | 15M checkpoint, tokenizer 파일 | `<repo>/data/third_party/models/stories15M.bin`, `tokenizer.bin` |
| `BIT` | 먼저 프로그래밍할 bitstream(필요 없음) | 없음 |

- 컴파일 옵션: Release, `-O2` 또는 `-O3`, `-mfpu=neon -mfloat-abi=hard -ffp-contract=off`, 심볼 `BUILD_OPT=2|3`, `-lm`. `-ffast-math`는 넣지 않는다(F판이 PC와 같은 float 연산을 하도록). GCC는 `-ffast-math` 없이 float 축약(reduction)을 NEON으로 벡터화하지 않으므로 NEON은 정수 루프(Q, H의 int8 MAC)에만 쓰일 수 있다.
- 다른 옵션은 `define-compiler-symbols`로: `VAR_MASK`(판 선택 비트), `RUN_MASK`(1 E, 2 T, 4 P), `RUN_M1`, `RUN_M2`, `POS_STRIDE`(위치별 출력 간격), 주소(`src/bcfg.h`).
- linker script: 스크립트가 app의 `lscript.ld`에서 `_STACK_SIZE`, `_HEAP_SIZE`, `ps7_ddr_0`의 LENGTH를 고치고 같은 크기를 `--defsym`으로도 준다. 패턴을 못 찾으면 WARNING을 출력하니 그때는 손으로 고친다.

### 3. 다운로드와 실행
1. 부팅 모드 JTAG, USB 연결, 전원.
2. 시리얼 터미널을 열고 출력 전체를 파일로 저장(예: `picocom -b 115200 --logfile uart.log /dev/ttyUSB1`).
3. 실행:
   ```
   xsct <repo>/fpga/sw/xsct_build.tcl XSA=<file.xsa> RUN=1               # -O2 빌드, 260K + 15M
   xsct <repo>/fpga/sw/xsct_build.tcl XSA=<file.xsa> RUN=1 RUNOPT=O3     # -O3 빌드
   ```
   순서: `rst -system`, `ps7_init`, `ps7_post_config`, ELF 다운로드, `dow -data`로 15M 이미지 두 개(아래 주소), `con`. 다운로드 전에 빌드를 다시 하므로 빌드만 따로 했다면 같은 인자로 그대로 실행해도 된다.
4. 로그가 `LMBASE END`로 끝나면 완료다. 15M 이미지를 올리지 않으면(`M2=0`) 15M은 `DATA ... status=absent`로 건너뛴다.

수동으로 할 때(XSCT 콘솔, 빌드 후):
```
connect
targets -set -nocase -filter {name =~ "APU*"}
rst -system
loadhw -hw <file.xsa> -mem-ranges [list {0x40000000 0xbfffffff}] -regs
configparams force-mem-access 1
source <ws>/lmb_plat/export/lmb_plat/hw/ps7_init.tcl
ps7_init
ps7_post_config
targets -set -nocase -filter {name =~ "*A9*#0"}
dow <ws>/lmbase_o2/Release/lmbase_o2.elf
dow -data <repo>/data/third_party/models/stories15M.bin 0x10000000
dow -data <repo>/data/third_party/models/tokenizer.bin 0x14000000
configparams force-mem-access 0
con
```
- `ps7_init.tcl`의 위치는 Vitis 버전마다 다르다(`<ws>/lmb_plat/` 아래에서 찾는다).
- 이미지는 ELF 다운로드 뒤, `con` 전에 올린다. 프로그램 시작 전에 메모리에 쓰이므로 cache와의 일관성 문제가 없다(boot 코드가 cache를 invalidate한 뒤 켠다) [추정, 미확인]. 리셋하면 다시 올린다.
- 프로그램이 주소, 크기, hash로 이미지를 검사한다: 첫 28 B(모델 구성)가 기대값과 다르면 `status=absent`(건너뜀), 구성은 맞는데 hash가 다르면 `status=corrupt`(FAIL).

### 4. 실행 시간
보드 실행 시간은 재지 않았다. 호스트(x86, gcc 8.5 `-O2`)에서 프로그램 전체가 20.0초(x86-64와 `-m32` 모두, 15M이 대부분)였다 [이전 기재, 이번 K12V8 재실행 로그(`logs/`)에는 전체 시간이 없어 재확인 안 함]. Cortex-A9 667 MHz에서는 이보다 수십 배 느릴 것으로 본다 [추정, 근거: 15M F판은 token마다 가중치 60.8 MB를 읽으므로 DDR 읽기 대역폭에 묶임]. 15M에서 판 3개 x 실행 3번 x 256 위치를 모두 하면 수십 분이 걸릴 수 있다 [추정]. 줄이려면 `RUN_MASK=1`(E만), `VAR_MASK`(판 일부)로 빌드한다. JTAG `dow -data` 61 MB 적재 시간도 재지 않았다.

## UART 출력 형식
한 줄에 한 항목, `KEY name=value ...`. 값에 공백 없음(문자열의 공백은 `_`). 줄 끝 `\r\n`. `LMBASE BEGIN fmt=1`과 `LMBASE END` 사이만 해석한다. 시간은 global timer tick(`CLK tps`가 초당 tick), `ms`, `us`는 소수 3자리.

| KEY | 필드 | 의미 |
|---|---|---|
| `BUILD` | plat opt optimize neon arm_fp hardfloat ptr_bits var_mask run_mask cc | 빌드 정보 |
| `PLAT` | cpu_hz tps sctlr actlr l2c_ctrl l2c_aux fpscr_boot fpscr sp ddr_ck ddr_tk arena layout | 보드 상태. `layout=overlap`이면 스택이 첫 DDR 이미지 주소를 넘음(오류) |
| `CLK` | tps cyc_per_100ms ticks | global timer 0.1초 동안의 PMU cycle 수(실제 CPU 클럭 확인) |
| `OVH` | kind(timer_pair, lap, hook_pair) n min_ticks avg_ticks avg_cyc | probe 오버헤드 |
| `MODEL` | m dim hidden layers heads kv_heads vocab seq_len steps pidx nptok corrupt | 모델과 실행 길이 |
| `DATA` | m src ck_len ck_hash ck_exp tk_len tk_hash tk_exp hash_ticks status(ok, absent, corrupt) | 이미지 검사 |
| `ARENA`, `TOKMEM` | need cap status / bytes | 모델 메모리 요구량 |
| `VAR` | m v kind init_ticks init_ms bytes whash whash_exp wmis | 판 준비 시간, 메모리, 양자화 가중치 hash |
| `ROPE` | hash hash_exp diff replaced | H RoPE 표가 PC 표와 다른 원소 수 |
| `PROMPT` | n n_exp mis | prompt 인코딩 비교 |
| `RUN` | m v run(E, T, P) steps ticks ms ms_tok tok_s [probes] | 실행 합계 |
| `POS` | m v pos ticks | 위치별 시간(run T) |
| `TOKPOS` | first first8 mid mid8 last last8 mid_pos first_us mid_us last_us | 위치 요약 |
| `KERN` | m v k calls ticks us_tok pct | kernel 범주별(run P). 범주 정의는 measure.md 4절 |
| `CHECK` | m v run n tok_mis hash_mis hash_req self_mis result | 정합성 |
| `TXT` | m v s | 생성 문장 앞부분(run E, 사람이 보는 용도) |
| `MSUM` | m variants mismatches errors result | 모델 합계 |
| `LAYOUT` | status | DDR 이미지 주소가 겹침(빌드 옵션 오류) |
| `RESULT` | models_run models_skipped mismatches errors result | 최종 판정 |

- PASS 조건: 필수 비교(measure.md 5절) mismatch 0, 오류 0, 실행한 모델 1개 이상. F판의 logits hash는 참고값이다(`hash_req=0`).

### 기대 출력 예시
**호스트(PC x86, gcc 8.5, `-m32`) 실행 로그(`sw/test/build/logs/t32.log`, 2026-11-18, H판 형식 K12V8)에서 발췌. 보드 출력이 아니며 시간 값은 ARM과 무관하다.**
```
LMBASE BEGIN fmt=1
BUILD plat=host opt=-1 optimize=1 neon=0 ptr_bits=32 var_mask=15 run_mask=7 cc=8.5.0_20210514_(Red_Hat_8.5.0-30)
PLAT name=host timer=clock_monotonic_ns ddr_images=2
CLK tps=1000000000 cyc_per_100ms=100000113 ticks=100000005
OVH kind=timer_pair n=2000 min_ticks=14 avg_ticks=14.774
OVH kind=lap n=2000 avg_ticks=18.752 avg_cyc=18.736
OVH kind=hook_pair n=2000 avg_ticks=38.481 avg_cyc=38.465
...
MODEL m=15M dim=288 hidden=768 layers=6 heads=6 kv_heads=6 vocab=32000 seq_len=256 steps=256 pidx=1 nptok=5 corrupt=0
DATA m=15M src=ddr ck_len=60816028 ck_hash=0xe721b1c6 ck_exp=0xe721b1c6 tk_len=433869 tk_hash=0x98910b13 tk_exp=0x98910b13 hash_ticks=53306576 status=ok
ARENA m=15M need=78198848 cap=78198848 status=ok
TOKMEM m=15M bytes=593929
VAR m=15M v=F kind=F init_ticks=1210780 init_ms=1.211 bytes=3683895 whash=0x00000000 whash_exp=0x00000000 wmis=0
VAR m=15M v=Qg kind=Q init_ticks=73131451 init_ms=73.131 bytes=56978560 whash=0x8ccfd481 whash_exp=0x8ccfd481 wmis=0
VAR m=15M v=K12V8 kind=H init_ticks=82298668 init_ms=82.299 bytes=16942400 whash=0x34d287af whash_exp=0x34d287af wmis=0
ROPE m=15M v=K12V8 hash=0x9d9d79c9 hash_exp=0x9d9d79c9 diff=0 replaced=0
PROMPT m=15M n=5 n_exp=5 mis=0
...
RUN m=15M v=K12V8 run=E steps=256 ticks=1702293720 ms=1702.294 ms_tok=6.650 tok_s=150.385
CHECK m=15M v=K12V8 run=E n=256 tok_mis=0 hash_mis=0 hash_req=0 self_mis=- result=PASS
RUN m=15M v=K12V8 run=T steps=256 ticks=1696709427 ms=1696.709 ms_tok=6.628 tok_s=150.880
POS m=15M v=K12V8 pos=0 ticks=5998096
POS m=15M v=K12V8 pos=1 ticks=6010764
...
TOKPOS m=15M v=K12V8 first=5998096 first8=6027087 mid=6642943 mid8=6642775 last=7191317 last8=7195318 mid_pos=128 first_us=5998.096 mid_us=6642.943 last_us=7191.317
CHECK m=15M v=K12V8 run=T n=256 tok_mis=0 hash_mis=0 hash_req=1 self_mis=- result=PASS
KERN m=15M v=K12V8 k=embed calls=256 ticks=341840 us_tok=1.335 pct=0.020
KERN m=15M v=K12V8 k=rmsnorm calls=3328 ticks=23193910 us_tok=90.601 pct=1.363
KERN m=15M v=K12V8 k=gemv_q calls=1536 ticks=48131003 us_tok=188.012 pct=2.828
...
KERN m=15M v=K12V8 k=gemv_cls calls=256 ticks=884653363 us_tok=3455.677 pct=51.987
KERN m=15M v=K12V8 k=attn calls=9216 ticks=165872525 us_tok=647.940 pct=9.748
...
KERN m=15M v=K12V8 k=other calls=61184 ticks=3506418 us_tok=13.697 pct=0.206
RUN m=15M v=K12V8 run=P steps=256 ticks=1701678322 ms=1701.678 ms_tok=6.647 tok_s=150.440 probes=122112
CHECK m=15M v=K12V8 run=P n=256 tok_mis=0 hash_mis=0 hash_req=1 self_mis=0 result=PASS
MSUM m=15M variants=3 mismatches=0 errors=0 result=PASS
RESULT models_run=2 models_skipped=0 mismatches=0 errors=0 result=PASS
LMBASE END
```
기대값을 일부러 틀리게 만든 실행(호스트 테스트의 결함 주입)에서:
```
CHECK m=15M v=F run=E n=256 tok_mis=1 hash_mis=0 hash_req=0 self_mis=- result=FAIL
CHECK m=15M v=K12V8 run=T n=256 tok_mis=0 hash_mis=1 hash_req=1 self_mis=- result=FAIL
```
tokenizer 이미지가 1 byte 틀린 경우:
```
DATA m=15M src=ddr ck_len=60816028 ck_hash=0xe721b1c6 ck_exp=0xe721b1c6 tk_len=433869 tk_hash=0x999eab40 tk_exp=0x98910b13 hash_ticks=49784116 status=corrupt
RESULT models_run=1 models_skipped=0 mismatches=1 errors=0 result=FAIL
```

### 로그 해석
```
python3 <repo>/fpga/sw/tools/parse_log.py uart.log                         # Markdown 표
python3 <repo>/fpga/sw/tools/parse_log.py --csv k.csv o2/uart.log o3/uart.log  # 여러 빌드를 CSV로
python3 <repo>/fpga/sw/tools/parse_log.py --pos-csv pos.csv uart.log       # 위치별 시간
```
- 표: 판별 token당 시간(E, T, P, 위치 요약, init), 계측 오버헤드(`P vs E %`, `probe est %`), kernel 범주별 호출 수/token, us/token, 비중(행렬별 gemv와 합계 `gemv_all`), 정합성.
- 파서는 CHECK, VAR, PROMPT, DATA, ROPE에서 mismatch 합을 다시 계산해 MSUM, RESULT와 맞추고, KERN 합이 RUN P와 같은지 확인한다. 종료 코드 0 PASS, 1 FAIL, 2 INCOMPLETE(END나 RESULT 없음, 합 불일치). 파일에 실행이 여러 번 있으면 마지막 실행을 쓴다.

## 돌려받을 것과 놓을 위치
빌드 하나(최적화 수준과 FPU 옵션 조합)마다 `fpga/results/<YYYY-MM-DD>_<o2|o3>[_vfpv3]/`:
| 파일 | 내용 | 필수 |
|---|---|---|
| `uart.log` | 시리얼 터미널 저장 파일, 가공하지 않은 원본(BEGIN부터 END까지 포함) | 필수 |
| `notes.txt` | Vitis 버전, 쓴 XSA(어느 설계인지, PS7 CPU 클럭 설정), 바꾼 빌드 옵션, XSCT 경고(lscript 패치 실패 등), 실행 중 이상 | 필수 |
| `xsct.log` | `xsct_build.tcl` 콘솔 출력 | 있으면 |

1차 요청: `-O2`와 `-O3` 두 빌드의 `uart.log`. 그 결과로 kernel 우선순위를 정한다.

## 메모리 요구량
### DDR 배치 (`sw/src/bcfg.h`)
| 영역 | 주소 | 크기 | 근거 |
|---|---|---|---|
| 프로그램(코드, 데이터, bss, 힙, 스택) | 0x0010_0000 ~ 0x0FFF_FFFF | 상한 255 MiB(`DDRLEN`) | linker script `ps7_ddr_0` LENGTH를 줄여 넘으면 링크 오류 |
| 15M checkpoint | 0x1000_0000 | 60,816,028 B(끝 0x13A0_019C) | 파일 크기 |
| 15M tokenizer | 0x1400_0000 | 433,869 B(끝 0x1406_9ECD) | 파일 크기 |
| 모델 메모리(arena) | 0x1800_0000 | 상한 0x27F0_0000(639 MiB, 0x3FF0_0000까지) | 아래 |

- 프로그램이 시작할 때 주소가 겹치지 않는지(이미지 크기 포함, `LAYOUT`)와 스택 위치(`PLAT sp`, `layout`)를 검사한다.

### 모델 메모리 (arena)
판을 모두 한 블록에 만들고(크기 계산 pass 뒤 채우기 pass) 실행한다. 아래 값은 호스트 `-m32` 빌드의 실측(`t32.log`의 `ARENA`, `TOKMEM`, `VAR bytes`, H판 형식 K12V8)이다. 64비트 호스트(`t.log`)는 포인터 폭 때문에 값이 다르다(예: 260K `ARENA need` 2,469,568 B, Qg 1,086,896 B). ARM도 ILP32이고 arena에 잡는 구조체에 64비트 멤버가 없어 `-m32`와 같은 값일 것으로 본다 [추정].
| 모델 | tokenizer | F | Qg | K12V8 | 합계(`ARENA need`) |
|---|---|---|---|---|---|
| 260K | 8,847 | 676,273 | 1,086,448 | 694,864 | 2,466,496 B (2.35 MiB) |
| 15M | 593,929 | 3,683,895 | 56,978,560 | 16,942,400 | 78,198,848 B (74.6 MiB) |

15M 내역 [계산]:
- 공통 int8 가중치 15,187,968 B = 6 layer x (288 x 288 x 4 + 288 x 768 x 3) + 32000 x 288(분류기, 임베딩 공용).
- F: KV cache float 6 x 256 x 288 x 4 B x 2 = 3,538,944 B + 버퍼. 가중치는 DDR의 checkpoint를 그대로 읽는다(arena에 복사하지 않음).
- Qg: int8 + 그룹 scale(float) 1,238,016 B + 역양자화한 임베딩 float 표 32000 x 288 x 4 = 36,864,000 B(model/src `lm_q_build`의 구조) + F와 같은 상태.
- K12V8: int8 + 행별 가수(u16) 99,712 B + RoPE 표 24,576 B + KV cache(K는 12비트를 담는 int16 container, V는 int8) + scale 147,456 B + 버퍼. KV cache는 K 6 x 6 x 256 x 48 x 2 B = 884,736 B와 V 6 x 6 x 256 x 48 x 1 B = 442,368 B로 합 1,327,104 B [계산]. 이전 HD(K, V 모두 int16, KV 1,769,472 B)의 `VAR bytes` 17,384,768 B와의 차이 442,368 B가 V의 int16에서 int8로 줄어든 크기와 일치한다. 나머지 항목이 HD와 같다는 것은 이 일치에 근거한 추정이다. 12비트 packing은 하지 않았다(container만 int16).

### 스택과 힙
- 스택: 호스트 `-m32 -fstack-usage`(`sw/test/build/logs/stack.txt`) 기준 가장 깊은 경로는 `main`(112) -> `bench_model`(256, 실행 함수 inline 포함) -> `lm_h_forward`(384) -> descriptor helper(224) -> `k_exec`(112) -> `k_attn`(12) -> `attn_core`(1,136) = 2,236 B, hook과 timer 호출을 더해 약 2.3 KB. 다음은 `bench_overhead`(1,680) 경로 약 1.8 KB. ARM 코드의 frame 크기는 다르므로 여유를 크게 둬 **64 KB(0x10000)**로 정했다(약 28배) [x86 -m32 측정 기반 추정]. 큰 배열은 전부 static(`.bss` 약 20 KB) 또는 arena에 있다.
- 힙: 프로그램과 `model/src`는 `malloc`을 쓰지 않는다. 쓰는 C 라이브러리 함수(`memcpy`, `memset`, `strlen`, `strcmp`, `isprint`, `expf` 등)도 할당하지 않는다. 기본값 64 KB를 그대로 둔다(필요량 0).
- 프로그램 크기: 호스트 `-m32`의 text 약 1.19 MB 중 260K 배열이 1,062,808 B, 기대값 헤더가 약 52 KB. ARM ELF도 1~2 MB 수준으로 본다 [추정]. 255 MiB 한도에 비해 작다.

## 15M을 DDR에, 260K를 배열로 두는 이유
- 260K: checkpoint 1,056,540 B, tokenizer 6,227 B(MIT). ELF에 넣어도 작고 JTAG 단계가 줄어든다. `make -C fpga/sw/test data`가 `sw/gen/m1_data.c`를 만든다(커밋 제외).
- 15M: 60.8 MB라 ELF에 넣으면 다운로드가 매번 길어지고, tokenizer는 라이선스 미확인이라 저장소나 배포물에 넣지 않는다. 사용자가 받은 원본 파일을 그대로 DDR에 올린다.
- 정수판(H) 가중치(약 15.3 MB)만 미리 만들어 올리는 방식은 `model/src`에 이미지 직렬화가 없어 쓰지 않았다. 보드에서 float checkpoint로부터 양자화한다(`VAR init_ms`로 시간 기록). 결과가 PC와 같은지 `VAR whash`로 확인한다.

## Vitis Unified (2024.1 이후)
XSCT의 platform/app 명령이 없으므로 GUI(또는 Python API)로 같은 것을 만든다. 이 절차는 확인하지 않았다.
1. Platform component 생성: XSA 선택, OS standalone, processor ps7_cortexa9_0. BSP 설정에서 stdin/stdout을 ps7_uart_1로.
2. Application component 생성(빈 C 템플릿), 위 platform 선택.
3. `src/`에 추가: `fpga/sw/src/`의 `.c`, `.h` 전부(`plat_host.c` 제외), `fpga/sw/expect/*.h`, `fpga/sw/gen/m1_data.c`, `model/src/`의 `.c`, `.h` 전부.
4. 빌드 설정: 최적화 `-O2`(두 번째 component는 `-O3`), 추가 컴파일 옵션 `-mfpu=neon -mfloat-abi=hard -ffp-contract=off`, 심볼 `BUILD_OPT=2`(또는 3), 라이브러리 `m`.
5. linker script(`lscript.ld`): `_STACK_SIZE` 0x10000, `_HEAP_SIZE` 0x10000, `ps7_ddr_0`의 LENGTH 0x0FF00000.
6. 실행: 하드웨어 실행 설정에서 FPGA 프로그래밍을 끄고 ps7_init을 켠 뒤 실행하거나, XSCT/XSDB 콘솔에서 위 "수동으로 할 때" 명령을 쓴다(2024.1 이후에도 XSDB는 있다 [추정]).

## 호스트 테스트 (이 서버에서 가능)
```
make -C fpga/sw/test test      # 마지막 줄 HOSTTEST RESULT: PASS
make -C fpga/sw/test gen       # 기대값 헤더와 260K 배열 재생성 (model/src가 바뀐 뒤)
```
`run.sh`가 순서대로 하는 것(결과는 `sw/test/build/logs/`):
1. 저장소의 기대값 헤더가 PC golden(`model/tools/io.c`의 driver와 `model/src`)으로 새로 만든 것과 같은지. `model/src`가 바뀌어 기대값이 낡으면 여기서 FAIL.
2. `t`(x86-64): 두 모델, 세 판, 실행 E/T/P. 모든 비교 mismatch 0, F/Q의 probe 사본이 `model/src`와 bit 일치(`self_mis=0`).
3. `t32`(`-m32 -msse2 -mfpmath=sse`): 32비트 `size_t`, `long`, 포인터에서 같은 결과.
4. `tc`: 기대값을 일부러 틀리게 만든 헤더(F의 token 1개, K12V8의 hash 1개). 모델마다 정확히 5개(E/T/P의 token, T/P의 hash) 잡히고 FAIL.
5. `td`(15M만, run E만): 이미지 없음(건너뜀), tokenizer 1 byte 변조(`corrupt`, FAIL), 정상(PASS).
6. 파서: 잘린 로그 INCOMPLETE, 부팅 메시지와 앞선 미완 실행이 섞인 로그 PASS, KERN 값 변조 INCOMPLETE, CSV 행 수.
7. `bin2c` 왕복(Python 역변환, C 프로그램이 배열을 파일로 다시 써서 비교).
8. `plat_xil.c`를 stub BSP 헤더(`test/xilstub/`)로 `-fsyntax-only -Werror` 검사(ARM inline asm은 조립하지 않음).
9. `xsct_build.tcl` 스텁 검사(`tclsh stub_check.tcl`, 14개 시나리오).
10. 스택 사용량 보고(`stack.txt`, 참고용).

호스트 결과의 의미: 프로그램 로직, 정합성 비교, 로그 형식, 메모리 배치 계산이 PC golden과 맞는다는 것만 보증한다. ARM 컴파일러, newlib, Xilinx BSP에서의 동작은 보드 실행으로 확인한다.

## 미검증 항목
보드와 Xilinx 도구에서 한 번도 실행하지 않았다.
1. ARM GCC(arm-none-eabi)로 컴파일: `-std` 기본값, `-Werror` 없이 경고 여부, `__ARM_NEON` 등 매크로.
2. `plat_xil.c`: `XTime_GetTime`과 `COUNTS_PER_SECOND`(global timer가 boot 코드에서 켜지는지, 안 켜졌으면 제어 레지스터를 직접 켬), CP15 PMU 접근(PMCR, PMCNTENSET, PMCCNTR), FPSCR 읽기/쓰기, `Xil_DCacheFlush`, L2C 레지스터 주소, `outbyte` 선언 위치, `XPAR_CPU_CORTEXA9_0_CPU_CLK_FREQ_HZ` 이름.
3. XSCT: 기본 domain 이름, 템플릿 이름, `bsp config stdout ps7_uart_1`, `app config`의 `compiler-misc`/`define-compiler-symbols`/`libraries`/`linker-misc` 키, 기본 `-mfpu=vfpv3` 뒤에 붙인 `-mfpu=neon`이 이기는지, `lscript.ld` 패턴, JTAG target 필터, `ps7_init.tcl` 위치, `dow -data`의 속도와 동작.
4. Q판의 bit 일치: newlib의 `expf`, `powf`, `cosf`, `sinf`가 PC glibc와 같은 결과를 내는지. 다르면 Q의 hash가 FAIL한다(measure.md 5절).
5. H판 준비(`hq.c`)의 double 연산과 RoPE 표가 ARM에서 PC와 같은지(`VAR whash`, `ROPE diff`로 확인되도록 만들어 둠).
6. FPSCR flush-to-zero를 끈 상태가 PC float 결과와 같은지(Cortex-A9 VFPv3의 subnormal 처리).
7. JTAG로 올린 이미지와 cache 일관성(boot 코드의 invalidate 순서).
8. 실행 시간(수십 분 가능성 [추정]), UART 출력량(`POS` 줄만 두 모델 합 2,304줄, 115200 baud에서 출력 시간은 재지 않음).
9. 스택 64 KB가 ARM에서 충분한지(호스트 측정 약 2.3 KB 기준).
10. Vitis Unified 절차.
