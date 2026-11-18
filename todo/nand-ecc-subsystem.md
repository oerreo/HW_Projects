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
