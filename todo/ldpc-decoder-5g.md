# Brief: ldpc-decoder-5g

- **내용**: 5G NR QC-LDPC layered min-sum 디코더. base graph와 lifting size를 파라미터로 받는 부분 병렬 구조.
- **연구 가치**: 부호 이론, 고정소수점 양자화와 BER 성능의 trade-off, 스케줄링(layer 순서, 파이프라인 충돌 회피).
- **실무 가치**: 모뎀 팹리스(통신 SoC)의 대표 IP. HLS 적용 사례가 많아 비교 기준이 풍부하다.
- **RTL/HLS**: check/variable node 데이터패스는 HLS, layer 스케줄러와 barrel shifter 네트워크, 메모리 control은 RTL.
- **주의**: BER 곡선을 얻으려면 시뮬레이션 양이 많다(공용 서버 병렬 2 제한에서 시간이 걸림). 큰 lifting size는 Zybo Z7-20 자원에 빠듯할 수 있다.
- **Test data 후보**: 3GPP TS 38.212 base graph 정의, 공개 5G 툴박스(Sionna, MATLAB 5G Toolbox 예제, AFF3CT)의 부호화 벡터와 BER 기준 곡선, AWGN 채널 LLR은 시드 고정 생성.
