# Brief: transformer-attention-accel

- **내용**: 양자화된 transformer의 attention 블록 가속기(정수 matmul, softmax 근사, layernorm). 소형 모델을 Zybo에서 구동.
- **연구 가치**: 비선형 함수(softmax, GELU, 역제곱근)의 하드웨어 근사와 오차 해석, 양자화 오차 전파.
- **실무 가치**: edge AI SoC, NPU IP 수요. HLS가 가장 활발히 쓰이는 영역.
- **RTL/HLS**: 연산 커널은 HLS, 시퀀서와 메모리 계층, AXI는 RTL.
- **주의**: 경쟁 연구가 매우 많아 차별점을 만들기 어렵다. 정확도 평가에 SW 프레임워크 환경이 필요하다. Zybo Z7-20 자원(220 DSP)이 모델 크기를 강하게 제한한다.
- **Test data 후보**: 공개 소형 모델 가중치(예: TinyStories 계열, ViT-tiny)와 공개 데이터셋 입력, 프레임워크(PyTorch) 정수 추론 결과를 기준값으로.
