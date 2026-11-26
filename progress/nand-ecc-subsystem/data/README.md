# data: nand-ecc-subsystem

외부 원본(행렬, 문서, 참조 구현 소스와 빌드)은 저장소에 넣지 않는다. `data/third_party/`(`.gitignore` 대상)에 받는 스크립트와 SHA-256 목록만 둔다. 논문에 인쇄된 수치만 출처와 함께 `data/params/`에 텍스트로 둔다(결정 H5).

## 받는 방법 (프로젝트 디렉토리에서)
```sh
sh data/scripts/fetch.sh               # 행렬, 참조 곡선, 문서. 끝에 checksums.sha256 검증
sh data/scripts/build_aff3ct.sh        # AFF3CT v4.7.4 clone + 패치 + 빌드 (-j1, 이 서버에서 약 20분)
cd model && make ext                   # C2 alist 생성(c2_alist.py), 자체 code의 alist 내보내기(qc2alist.py)
```
- 받은 날짜: 2026-11-26. 요청은 일반 curl/git만 쓰고 개인 정보를 넣지 않았다.
- `build_aff3ct.sh`는 공용 서버 규칙(`process-privacy.md`) 때문에 (1) 빌드를 비공개 runtime 디렉토리의 symlink 경로로 실행해 컴파일러 명령행에 프로젝트 경로가 나오지 않게 하고, (2) `aff3ct_argfile.patch`로 `main()`이 인자 없이 시작되면 환경변수 `A_ARGS`가 가리키는 파일에서 옵션을 읽게 한다(패치는 `src/main.cpp`의 `main` 한 곳, 22줄). 실행은 `model/tools/aff.sh`.

## 파일, 출처, 라이선스

| 파일 (`data/third_party/`) | 출처 | 라이선스/재배포 | 용도 |
|---|---|---|---|
| `alist/eth_1723_2048.alist` | github.com/aff3ct/configuration_files, commit 9d72575, `dec/LDPC/10GBPS-ETHERNET_1723_2048.alist` | 저장소에 license 파일 없음(GitHub API 404), **미확인**. 행렬 자체는 IEEE 802.3an 규격 | 외부 기준 code 1: (2048, 1723) RS-LDPC, 384 x 2048, (6, 32)-regular. GF(2) rank 325(`make test`) |
| `alist/eth_alt_1723_2048.alist` | 같은 저장소 `..._ALT_...` | 위와 같음 | 받기만 함(비교에는 쓰지 않음) |
| `refs/eth_flood_spa_i100.txt`, `refs/eth_hlay_spa_i100.txt`, `refs/eth_flood_nms_i30.txt` | github.com/aff3ct/error_rate_references, commit 51dff02 | license 파일 없음, **미확인** | 참조 구현(AFF3CT v1.3.2, 2018)의 BER/FER 곡선. 명령행이 파일 머리에 있다(AZCW, AWGN BPSK, Eb/N0, flooding SPA 100 it / horizontal layered SPA 100 it / flooding NMS 0.5 30 it, syndrome 정지, 오류 frame 100). flooding SPA 파일은 DOI 10.1109/GLOCOM.2009.5425510을 단다 |
| `docs/ccsds_131x1o2e2s.pdf` | ccsds.org/Pubs/131x1o2e2s.pdf (CCSDS 131.1-O-2, 2007, Historical) | CCSDS 문서는 무료 공개, 복제 조건 문구 **미확인** | C2 (8176, 7156) Table 2-1(circulant 위치), 그림 A-2(BLER) |
| `alist/ccsds_c2_7156_8176.alist` | 위 PDF에서 `c2_alist.py`가 생성(`make ext`) | 생성물, 커밋 안 함 | 외부 기준 code 2: 1022 x 8176, 행 weight 32, 열 weight 4, rank 1020 → k 7156(`make test`). sha256 44d08ecd... (재생성 시 같은 값) |
| `docs/cui_todaes2021.pdf` | xiaorz.github.io/paper/TODAES2021-Cui.pdf ([R5]) | 논문 PDF, 재배포 안 함 | TLC fit 표 A1~A3의 출처. 수치는 `params/`에 옮김 |
| `docs/pan_fast2011.pdf` | usenix.org/event/fast11/tech/full_papers/Pan.pdf ([R3]) | 재배포 안 함 | MLC 모델의 효과 순서 확인(2.4절, Fig. 1) |
| `aff3ct/` | github.com/aff3ct/aff3ct tag v4.7.4(f6aabe7) + submodule(MIPP, date, cli, streampu와 그 rang, cpptrace, json) | MIT (`aff3ct/LICENSE` 확인) | 참조 구현. 빌드 산출물 `aff3ct/build/bin/aff3ct-4.7.4` |

| 파일 (`data/`, 커밋) | 내용 |
|---|---|
| `params/tlc_cui2021.txt` | [R5] Table A1~A3의 인쇄 수치(정규화 평균과 표준편차, P/E 500~5000, 15/30/90일). PDF 텍스트층에서 옮김. A3 P/E 2000의 P0 σ = 18.1(비단조)은 인쇄된 그대로 |
| `scripts/fetch.sh`, `scripts/checksums.sha256` | 받기와 검증 |
| `scripts/build_aff3ct.sh`, `scripts/aff3ct_argfile.patch` | 참조 구현 빌드 |
| `scripts/c2_alist.py` | C2 alist 생성(Table 2-1의 상대 위치와 절대 위치를 서로 검사, 행/열 weight 검사) |

## Test data 세 종류 (N2 시점)
1. **공인/외부**: 802.3an 행렬 + AFF3CT 참조 곡선(수치 표), CCSDS C2 행렬 + 문서 그림 A-2(그림에서 읽은 값, 정밀도 약 ±0.1 decade), 같은 행렬로 직접 빌드한 AFF3CT v4.7.4 실행 결과(`model/results/aff/`). 채널은 [R5] 인쇄 수치, [R3] 상수.
2. **방향성**: `model/tests/t.c`(전부 0, 단위 메시지, 단일 비트 뒤집기, t8 단일/이중 오류 전수 4,656 패턴, erasure, 최대 LLR, BCH t와 t+1 오류, 단축 경계 위치, 감지 격자 경계), `model/tools/xcheck.sh`(포화가 일어나는 형식 8개).
3. **random**: 모든 실행이 seed와 frame 수를 결과 파일 머리와 설정 파일(`model/cfg/*.cfg`)에 남긴다. frame f는 `rng_seed(seed ^ (point << 48), f)`로 단독 재현 가능.
- 공개 raw NAND 측정 데이터셋은 찾지 못했다(서베이 1.5). 대체 근거: 문헌 fit 표([R5]) + 해석식 raw BER과 정수 샘플러 Monte Carlo의 일치(`make test`) + decoder의 외부 code 교차 검증.
