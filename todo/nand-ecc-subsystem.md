# nand-ecc-subsystem: NAND/SSD ECC 서브시스템

상태: **다음 순서로 확정** (2026-11-18 사용자 결정. `llm-pim-soc` 다음에 진행).

## 분야
메모리(NAND/SSD) 신뢰성. 시스템 프로젝트 방식: 전체를 C로 구현, Zybo Z7-20에 들어가는 크기로 모듈을 IP화, 모듈별 오프로드 측정, 전체 가속 추정.

## 범위 (초안, 시작 시 서베이로 확정)
- C 전체: NAND 채널 모델(P/E cycle, retention에 따른 threshold 분포), LDPC encoder/decoder(hard와 soft decision), BCH(비교용), read retry 정책.
- IP 후보: LDPC decoder(check/variable node, 스케줄러), encoder, syndrome 계산, LLR 생성.
- 측정: decoder throughput, 정정 성능(FER 대 raw BER), ARM 단독 대비 가속, 추정과 end-to-end 실측의 차이.

## 가치
- 실무: SSD 컨트롤러에서 면적과 전력 비중이 큰 블록. 메모리 회사의 대표적인 디지털 설계 영역.
- 연구: decoder 스케줄(flooding 대 layered), 양자화 비트폭과 정정 성능의 trade-off.

## RTL / HLS 분담
- RTL: decoder 스케줄러와 메모리 구조, 버스 인터페이스, top.
- HLS 가능: check/variable node 연산 datapath.

## Test data 후보
- 공개 LDPC 코드 행렬(표준 문서), 문헌의 NAND 오류 모델 parameter(출처 확인 필요), random.

## 관련
- 기존 `ldpc-decoder-5g.md`와 decoder 구조를 공유한다(이 프로젝트가 진행되면 그 brief는 흡수 여부를 결정).
- 메모리 설계 영역 전체 표는 `memory-design-areas.md`.

## 사전 조사 (2026-11-24)
서베이: `nand-ecc-subsystem.survey.md`(출처 R1~R49). 아래는 오케스트레이터의 잠정 결정이며 프로젝트 시작(G0) 때 확정한다.
- Code: 하드웨어 주 code는 자체 구성 QC-LDPC(weight-1 circulant, Z = 128, n = 9216, k = 8192, rate 0.889, 열 weight 4, dual-diagonal parity). 구성과 girth 검증 스크립트를 G0~G1에 포함. golden 검증의 외부 기준은 CCSDS C2 (8176,7156)와 IEEE 802.3an (2048,1723), 오픈소스 참조 구현과 교차 검증.
- 채널 모델: MLC 해석 모델과 TLC fit 표를 둘 다 C에 구현하고 기본은 TLC fit 표. 공개 raw NAND 측정 데이터셋은 찾지 못했음(대체 근거를 `data/README.md`에 적는다).
- Soft 정보: LLR 6 bit를 기준으로 4, 5 bit를 비교. 감지 레벨 수는 hard, +2, +4, +6을 C에서 비교한 뒤 IP 기본값을 정한다.
- 범위: BCH는 C 비교용만(IP로 만들지 않음). PL 채널 에뮬레이터는 보드 FER 깊이를 좌우하므로 포함 후보로 두고 G0에서 자원 계산 후 결정.
- 외부 행렬과 데이터는 저장소에 넣지 않고 받는 스크립트와 checksum만 둔다(재배포 조건 미확인).
- `ldpc-decoder-5g.md`는 이 프로젝트에 흡수(5G 전용 부분은 확장 메모로만 남김). brief 파일 정리는 시작 시점에 한다.
