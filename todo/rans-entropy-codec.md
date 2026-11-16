# Brief: rans-entropy-codec

- **내용**: rANS(Asymmetric Numeral Systems) 기반 고처리량 엔트로피 인코더/디코더 IP. interleaved multi-stream으로 디코더의 직렬 의존성을 끊는 구조 탐색.
- **연구 가치**: 정보이론(코드 길이와 정밀도 손실의 정량 분석), 디코더 feedback loop의 타이밍 한계와 병렬화.
- **실무 가치**: 데이터센터 압축(zstd 계열), 차세대 이미지/비디오 코덱, learned compression의 엔트로피 단. 사용자의 코덱 경험과 연결된다.
- **RTL/HLS**: renormalization과 스트림 패킹 control은 RTL, 확률 테이블 생성은 HLS.
- **주의**: 본업(코덱)과 가까워 회사 IP와의 분리를 더 엄격히 해야 한다.
- **보드 적합성**: Zybo Z7-20에 충분.
- **Test data 후보**: Silesia/Canterbury corpus, enwik8, zstd 참조 구현(FSE/rANS 계열) 출력과의 교차 확인.
