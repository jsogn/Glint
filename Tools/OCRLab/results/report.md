# OCR benchmark

Environment: Apple M4 Pro, 48GB RAM, macOS 26.5.

Scope: recognition-only. Text detection and blue-capsule detection are excluded because Glint already provides the candidate crop. The set contains one real candidate screenshot, four variants of that screenshot, and 400 controlled synthetic candidates.

| Backend | Scope | Exact match | CER | p50 | p95 |
| --- | --- | ---: | ---: | ---: | ---: |
| Apple Vision | all | 93.58% (379/405) | 4.94% | 16.01ms | 20.05ms |
| Apple Vision | real screenshot | 0.00% (0/1) | 100.00% | 17.44ms | 17.92ms |
| Apple Vision | real screenshot variants | 50.00% (2/4) | 50.00% | 16.81ms | 32.06ms |
| Apple Vision | synthetic variants | 94.25% (377/400) | 4.25% | 16.00ms | 19.91ms |
| PP-OCRv6 tiny | all | 90.86% (368/405) | 4.81% | 1.31ms | 1.74ms |
| PP-OCRv6 tiny | real screenshot | 100.00% (1/1) | 0.00% | 1.48ms | 2.09ms |
| PP-OCRv6 tiny | real screenshot variants | 100.00% (4/4) | 0.00% | 1.64ms | 2.23ms |
| PP-OCRv6 tiny | synthetic variants | 90.75% (363/400) | 4.88% | 1.31ms | 1.73ms |
| PP-OCRv6 small | all | 99.51% (403/405) | 0.25% | 3.97ms | 4.45ms |
| PP-OCRv6 small | real screenshot | 100.00% (1/1) | 0.00% | 3.97ms | 4.72ms |
| PP-OCRv6 small | real screenshot variants | 100.00% (4/4) | 0.00% | 4.15ms | 4.43ms |
| PP-OCRv6 small | synthetic variants | 99.50% (398/400) | 0.25% | 3.96ms | 4.45ms |

## Failures

- Apple Vision `real_original` expected `你好` raw `1` cleaned `` score=1.0000
- Apple Vision `real_blur` expected `你好` raw `1` cleaned `` score=1.0000
- Apple Vision `real_jpeg75` expected `你好` raw `1` cleaned `` score=1.0000
- Apple Vision `synthetic_005_3` expected `学习` raw `1` cleaned `` score=1.0000
- Apple Vision `synthetic_009_3` expected `今天` raw `1` cleaned `` score=1.0000
- Apple Vision `synthetic_016_3` expected `结果` raw `1` cleaned `` score=1.0000
- Apple Vision `synthetic_019_2` expected `继续` raw `丨继续` cleaned `丨继续` score=0.5000
- Apple Vision `synthetic_021_0` expected `重要` raw `益車（` cleaned `益車` score=0.3000
- Apple Vision `synthetic_026_2` expected `错误` raw `丨错误` cleaned `丨错误` score=0.3000
- Apple Vision `synthetic_027_3` expected `快速` raw `1` cleaned `` score=1.0000
- Apple Vision `synthetic_029_2` expected `翻译` raw `丨翻译` cleaned `丨翻译` score=0.3000
- Apple Vision `synthetic_039_2` expected `软件` raw `丨软件` cleaned `丨软件` score=0.3000
- Apple Vision `synthetic_040_2` expected `系统` raw `丨系统` cleaned `丨系统` score=0.3000
- Apple Vision `synthetic_040_3` expected `系统` raw `1` cleaned `` score=1.0000
- Apple Vision `synthetic_042_2` expected `数据` raw `丨数据` cleaned `丨数据` score=0.3000
- Apple Vision `synthetic_045_3` expected `产品` raw `产` cleaned `产` score=1.0000
- Apple Vision `synthetic_049_3` expected `用户` raw `1` cleaned `` score=1.0000
- Apple Vision `synthetic_057_3` expected `候选` raw `1` cleaned `` score=1.0000
- Apple Vision `synthetic_059_0` expected `句子` raw `旬子` cleaned `旬子` score=0.5000
- Apple Vision `synthetic_061_3` expected `目标` raw `1` cleaned `` score=1.0000
- Apple Vision `synthetic_085_3` expected `风格` raw `凤格` cleaned `凤格` score=0.3000
- Apple Vision `synthetic_088_2` expected `经验` raw `丨经验` cleaned `丨经验` score=0.3000
- Apple Vision `synthetic_089_2` expected `建议` raw `丨建议` cleaned `丨建议` score=0.3000
- Apple Vision `synthetic_091_2` expected `选择` raw `丨选择` cleaned `丨选择` score=0.3000
- Apple Vision `synthetic_094_2` expected `导出` raw `一泉出` cleaned `一泉出` score=0.3000
- Apple Vision `synthetic_096_3` expected `失败` raw `1` cleaned `` score=1.0000
- PP-OCRv6 tiny `synthetic_008_2` expected `朋友` raw `明友` cleaned `明友` score=0.7993
- PP-OCRv6 tiny `synthetic_009_2` expected `今天` raw `(天` cleaned `天` score=0.7737
- PP-OCRv6 tiny `synthetic_013_0` expected `以后` raw `以同` cleaned `以同` score=0.9028
- PP-OCRv6 tiny `synthetic_013_1` expected `以后` raw `后` cleaned `后` score=0.5522
- PP-OCRv6 tiny `synthetic_015_2` expected `方法` raw `(万方法` cleaned `万方法` score=0.7107
- PP-OCRv6 tiny `synthetic_024_0` expected `清楚` raw `(活楚` cleaned `活楚` score=0.5905
- PP-OCRv6 tiny `synthetic_024_2` expected `清楚` raw `(消楚` cleaned `消楚` score=0.6439
- PP-OCRv6 tiny `synthetic_025_0` expected `正确` raw `正硝` cleaned `正硝` score=0.9046
- PP-OCRv6 tiny `synthetic_027_2` expected `快速` raw `(快递` cleaned `快递` score=0.5028
- PP-OCRv6 tiny `synthetic_029_2` expected `翻译` raw `甜祥` cleaned `甜祥` score=0.4774
- PP-OCRv6 tiny `synthetic_033_0` expected `文字` raw `(文学` cleaned `文学` score=0.6886
- PP-OCRv6 tiny `synthetic_033_2` expected `文字` raw `(x字` cleaned `x字` score=0.6767
- PP-OCRv6 tiny `synthetic_034_2` expected `语言` raw `(声` cleaned `声` score=0.3369
- PP-OCRv6 tiny `synthetic_035_2` expected `英语` raw `(英话` cleaned `英话` score=0.7114
- PP-OCRv6 tiny `synthetic_036_2` expected `中文` raw `中蚊` cleaned `中蚊` score=0.5849
- PP-OCRv6 tiny `synthetic_042_2` expected `数据` raw `故据` cleaned `故据` score=0.5782
- PP-OCRv6 tiny `synthetic_044_2` expected `项目` raw `(项姐` cleaned `项姐` score=0.7472
- PP-OCRv6 tiny `synthetic_051_2` expected `设置` raw `设理` cleaned `设理` score=0.5724
- PP-OCRv6 tiny `synthetic_053_2` expected `位置` raw `(位理` cleaned `位理` score=0.5108
- PP-OCRv6 tiny `synthetic_055_0` expected `背景` raw `(背录` cleaned `背录` score=0.6241
- PP-OCRv6 tiny `synthetic_055_2` expected `背景` raw `背宗` cleaned `背宗` score=0.4590
- PP-OCRv6 tiny `synthetic_056_2` expected `透明` raw `(遗明` cleaned `遗明` score=0.6393
- PP-OCRv6 tiny `synthetic_057_0` expected `候选` raw `(侯选` cleaned `侯选` score=0.7024
- PP-OCRv6 tiny `synthetic_059_2` expected `句子` raw `(子` cleaned `子` score=0.4744
- PP-OCRv6 tiny `synthetic_060_1` expected `记忆` raw `(记亿` cleaned `记亿` score=0.6971
- PP-OCRv6 tiny `synthetic_060_2` expected `记忆` raw `(记亿` cleaned `记亿` score=0.7823
- PP-OCRv6 tiny `synthetic_061_2` expected `目标` raw `(日标` cleaned `日标` score=0.7343
- PP-OCRv6 tiny `synthetic_069_2` expected `平台` raw `(平白` cleaned `平白` score=0.4636
- PP-OCRv6 tiny `synthetic_071_2` expected `离线` raw `(商线` cleaned `商线` score=0.6265
- PP-OCRv6 tiny `synthetic_077_2` expected `版本` raw `版水` cleaned `版水` score=0.7533
- PP-OCRv6 tiny `synthetic_081_0` expected `速度` raw `（速皮` cleaned `速皮` score=0.6542
- PP-OCRv6 tiny `synthetic_082_0` expected `质量` raw `质星` cleaned `质星` score=0.8974
- PP-OCRv6 tiny `synthetic_084_0` expected `准确` raw `(准硝` cleaned `准硝` score=0.6437
- PP-OCRv6 tiny `synthetic_084_2` expected `准确` raw `(准碗` cleaned `准碗` score=0.6547
- PP-OCRv6 tiny `synthetic_093_0` expected `导入` raw `导人` cleaned `导人` score=0.5991
- PP-OCRv6 tiny `synthetic_093_2` expected `导入` raw `(导人` cleaned `导人` score=0.4852
- PP-OCRv6 tiny `synthetic_094_1` expected `导出` raw `导融出` cleaned `导融出` score=0.6561
- PP-OCRv6 small `synthetic_044_2` expected `项目` raw `项日` cleaned `项日` score=0.7867
- PP-OCRv6 small `synthetic_073_0` expected `接口` raw `按口` cleaned `按口` score=0.8135

## Notes

- The current full OCRService pipeline correctly read the original real screenshot as `你好`; the isolated re-encoded crop returned only `1` to Vision, so Vision is sensitive to crop and encoding context.
- Synthetic results validate model behavior and relative latency, but they are not a substitute for a larger real-screen corpus.
- Latency covers image decode, model preprocessing, and recognition. It excludes screenshot capture, blue-capsule detection, and a future Swift-to-ONNX Runtime bridge.
